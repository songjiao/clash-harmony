//go:build with_gvisor && !no_tailscale

package outbound

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/iface/anet"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing-tun/ping"

	ts "github.com/metacubex/tailscale"
	"github.com/metacubex/tailscale/client/local"
	"github.com/metacubex/tailscale/envknob"
	"github.com/metacubex/tailscale/hostinfo"
	"github.com/metacubex/tailscale/ipn"
	"github.com/metacubex/tailscale/net/netmon"
	"github.com/metacubex/tailscale/net/tsaddr"
	"github.com/metacubex/tailscale/tailcfg"
	"github.com/metacubex/tailscale/tsnet"
	"github.com/metacubex/tailscale/types/nettype"
	D "github.com/miekg/dns"
	"github.com/samber/lo"
)

// TailscaleStatus captures the serialized runtime state of a Tailscale outbound for diagnostics UI.
type TailscaleStatus struct {
	Name         string   `json:"name"`
	Hostname     string   `json:"hostname"`
	BackendState string   `json:"backendState"`
	AuthURL      string   `json:"authUrl"`
	TailscaleIPs []string `json:"tailscaleIPs"`
	Health       []string `json:"health"`
	LastError    string   `json:"lastError"`
	RecentLogs   []string `json:"recentLogs"`
	UpdatedAt    string   `json:"updatedAt"`
}

func cloneNonNilStrings(src []string) []string {
	if len(src) == 0 {
		return []string{}
	}
	return slices.Clone(src)
}

func (s TailscaleStatus) clone() TailscaleStatus {
	s.TailscaleIPs = cloneNonNilStrings(s.TailscaleIPs)
	s.Health = cloneNonNilStrings(s.Health)
	s.RecentLogs = cloneNonNilStrings(s.RecentLogs)
	return s
}

func isDiagnosticTailscaleLog(msg string) bool {
	lower := strings.ToLower(msg)
	for _, token := range []string{
		"auth",
		"login",
		"needslogin",
		"control",
		"error",
		"fail",
		"timeout",
		"x509",
		"tls",
		"dns",
		"derp",
		"netcheck",
		"state",
		"switching",
		"to start this tsnet server",
		"logged in",
		"netstack:",
		"exec ping",
	} {
		if strings.Contains(lower, token) {
			return true
		}
	}
	return false
}

type Tailscale struct {
	*Base
	server      *tsnet.Server
	dnsResolver *dns.Resolver
	option      TailscaleOption
	ctx         context.Context
	cancel      context.CancelFunc
	startOnce   sync.Once
	startErr    error

	backendInitOnce sync.Once
	backendInitCh   chan struct{}
	backendInitErr  error

	serverStarted     atomic.Bool
	advertisePrefixes []netip.Prefix

	statusMu       sync.Mutex
	writeMu        sync.Mutex
	status         TailscaleStatus
	statusFilePath string
	lastFlushAt    time.Time

	unregisterDNSResolver func()
}

type TailscaleOption struct {
	BasicOption
	Name       string `proxy:"name"`
	Hostname   string `proxy:"hostname,omitempty"`
	AuthKey    string `proxy:"auth-key,omitempty"`
	ControlURL string `proxy:"control-url,omitempty"`
	StateDir   string `proxy:"state-dir,omitempty"`
	Ephemeral  bool   `proxy:"ephemeral,omitempty"`
	UDP        bool   `proxy:"udp,omitempty"`

	AcceptRoutes           *bool    `proxy:"accept-routes,omitempty"`
	AdvertiseRoutes        []string `proxy:"advertise-routes,omitempty"`
	ExitNode               string   `proxy:"exit-node,omitempty"`
	ExitNodeAllowLANAccess *bool    `proxy:"exit-node-allow-lan-access,omitempty"`
}

func init() {
	hostinfo.RegisterHostinfoNewHook(func(hi *tailcfg.Hostinfo) {
		versionDotTxt := strings.TrimSpace(ts.VersionDotTxt)
		hi.IPNVersion = fmt.Sprintf("%s-%s-%s", versionDotTxt, C.MihomoName, C.Version)
	})
	envknob.SetNoLogsNoSupport()
	if runtime.GOOS == "android" { // Android SDK 30 no longer permits Go's net.Interfaces to work (Issue 2293)
		netmon.RegisterInterfaceGetter(func() (nif []netmon.Interface, err error) {
			log.Debugln("[Tailscale] InterfaceGetter: start, IsForceAnet: %v", anet.IsForceAnet())
			ifaces, err := anet.Interfaces()
			if err != nil {
				log.Warnln("[Tailscale] anet.Interfaces failed: %v", err)
				return nil, err
			}
			for _, iff := range ifaces {
				addrs, err := anet.InterfaceAddrsByInterface(&iff)
				if err != nil {
					log.Warnln("[Tailscale] anet.InterfaceAddrsByInterface(%v) failed: %v", iff.Name, err)
					continue
				}
				nif = append(nif, netmon.Interface{
					Interface: &net.Interface{
						Index:        iff.Index,
						MTU:          iff.MTU,
						Name:         iff.Name,
						HardwareAddr: iff.HardwareAddr,
						Flags:        iff.Flags,
					},
					AltAddrs: addrs,
				})
			}

			log.Debugln("[Tailscale] InterfaceGetter: %v", lo.Map(nif, func(item netmon.Interface, index int) string {
				var addrs any
				addrs, err := item.Addrs()
				if err != nil {
					addrs = err
				}
				return fmt.Sprintf("{Name: %s, Addrs: %v, IsUp: %v, IsLoopback: %v}", item.Name, addrs, item.IsUp(), item.IsLoopback())
			}))
			return
		})
	}
}

func NewTailscale(option TailscaleOption) (*Tailscale, error) {
	if _, err := buildTailscaleMaskedPrefs(option); err != nil {
		return nil, err
	}
	if option.StateDir == "" {
		option.StateDir = "tailscale"
	}
	option.StateDir = C.Path.Resolve(option.StateDir)
	if !C.Path.IsSafePath(option.StateDir) {
		return nil, C.Path.ErrNotSafePath(option.StateDir)
	}

	addr := option.ControlURL
	if addr == "" {
		addr = "tailscale"
	}
	advertisePrefixes, err := parseTailscaleAdvertiseRoutes(option.AdvertiseRoutes)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	outbound := &Tailscale{
		Base: NewBase(BaseOption{
			Name:         option.Name,
			Addr:         addr,
			Type:         C.Tailscale,
			ProviderName: option.ProviderName,
			UDP:          option.UDP,
			Interface:    option.Interface,
			RoutingMark:  option.RoutingMark,
			Prefer:       option.IPVersion,
		}),
		option:            option,
		ctx:               ctx,
		cancel:            cancel,
		backendInitCh:     make(chan struct{}),
		advertisePrefixes: advertisePrefixes,
		status: TailscaleStatus{
			Name:         option.Name,
			Hostname:     option.Hostname,
			BackendState: "Idle",
			TailscaleIPs: []string{},
			Health:       []string{},
			RecentLogs:   []string{},
		},
		statusFilePath: C.Path.Resolve("tailscale-status.json"),
	}
	outbound.dialer = option.NewDialer(outbound.DialOptions())
	outbound.server = &tsnet.Server{
		Dir:        option.StateDir,
		Hostname:   option.Hostname,
		AuthKey:    option.AuthKey,
		ControlURL: option.ControlURL,
		Ephemeral:  option.Ephemeral,
		SystemDialer: func(ctx context.Context, network, address string) (net.Conn, error) {
			log.Debugln("[Tailscale](%s) SystemDialer: start dial %s %s", option.Name, network, address)
			conn, err := outbound.dialer.DialContext(ctx, network, address)
			log.Debugln("[Tailscale](%s) SystemDialer: finish dial %s %s, err: %v", option.Name, network, address, err)
			if err != nil {
				outbound.recordLog(fmt.Sprintf("SystemDialer failed (%s %s): %v", network, address, err), false)
			}
			return conn, err
		},
		SystemPacketListener: func(ctx context.Context, network, address string) (net.PacketConn, error) {
			log.Debugln("[Tailscale](%s) SystemPacketListener: start listen %s %s", option.Name, network, address)
			pc, err := outbound.dialer.ListenPacket(ctx, network, address, netip.AddrPort{})
			log.Debugln("[Tailscale](%s) SystemPacketListener: finish listen %s %s, err: %v", option.Name, network, address, err)
			return pc, err
		},
		ExtraRootCAs: ca.GetCertPool(),
		LookupHook: func(ctx context.Context, host string) ([]netip.Addr, error) {
			log.Debugln("[Tailscale](%s) LookupHook: start lookup %s", option.Name, host)
			filterRealIPs := func(in []netip.Addr) []netip.Addr {
				fakeV4 := netip.MustParsePrefix("198.18.0.0/15")
				out := make([]netip.Addr, 0, len(in))
				for _, ip := range in {
					u := ip.Unmap()
					if u.Is4() && fakeV4.Contains(u) {
						continue
					}
					out = append(out, u)
				}
				return out
			}
			ips, err := resolver.LookupIPWithResolver(ctx, host, resolver.ProxyServerHostResolver)
			if err == nil {
				ips = filterRealIPs(ips)
			}
			if (err != nil || len(ips) == 0) && resolver.DefaultResolver != nil && resolver.DefaultResolver != resolver.ProxyServerHostResolver {
				if fb, fbErr := resolver.LookupIPWithResolver(ctx, host, resolver.DefaultResolver); fbErr == nil {
					if realFB := filterRealIPs(fb); len(realFB) > 0 {
						ips, err = realFB, nil
					}
				}
			}
			if (err != nil || len(ips) == 0) && resolver.SystemResolver != nil {
				if sysIPs, sysErr := resolver.LookupIPWithResolver(ctx, host, resolver.SystemResolver); sysErr == nil {
					if realSys := filterRealIPs(sysIPs); len(realSys) > 0 {
						ips, err = realSys, nil
					}
				}
			}
			log.Debugln("[Tailscale](%s) LookupHook: finish lookup %s, ips: %v, err: %v", option.Name, host, ips, err)
			if err != nil || len(ips) == 0 {
				if err == nil {
					err = fmt.Errorf("resolved only fake-ip for %s", host)
				}
				outbound.recordLog(fmt.Sprintf("LookupHook failed (%s): %v", host, err), false)
			}
			return ips, err
		},
		UserLogf: func(format string, args ...any) {
			msg := fmt.Sprintf(format, args...)
			log.Infoln("[Tailscale](%s) %s", option.Name, msg)
			outbound.recordLog(msg, true)
		},
		Logf: func(format string, args ...any) {
			msg := fmt.Sprintf(format, args...)
			log.Debugln("[Tailscale](%s) %s", option.Name, msg)
			if isDiagnosticTailscaleLog(msg) {
				outbound.recordLog(msg, false)
			}
		},
	}
	dnsTransport := tailscaleDNSTransport{tailscale: outbound}
	outbound.dnsResolver = dns.NewResolverFromClient(dnsTransport)
	outbound.unregisterDNSResolver = dns.RegisterTailscaleDnsClient(option.Name, dnsTransport)
	return outbound, nil
}

// StatusSnapshot returns a thread-safe copy of the outbound's current runtime status.
func (t *Tailscale) StatusSnapshot() TailscaleStatus {
	t.statusMu.Lock()
	defer t.statusMu.Unlock()
	return t.status.clone()
}

func (t *Tailscale) persistStatus(snapshot TailscaleStatus) {
	if t.statusFilePath == "" {
		return
	}
	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return
	}
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(t.statusFilePath), 0o755); err != nil {
		return
	}
	tmpPath := t.statusFilePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0o644); err != nil {
		return
	}
	_ = os.Rename(tmpPath, t.statusFilePath)
}

func (t *Tailscale) updateStatus(fn func(*TailscaleStatus)) {
	t.statusMu.Lock()
	fn(&t.status)
	t.status.UpdatedAt = time.Now().Format(time.RFC3339)
	t.lastFlushAt = time.Now()
	snap := t.status.clone()
	t.statusMu.Unlock()
	t.persistStatus(snap)
}

func (t *Tailscale) recordLog(msg string, flush bool) {
	trimmed := strings.TrimSpace(msg)
	if trimmed == "" {
		return
	}
	lower := strings.ToLower(trimmed)
	isImportant := flush ||
		strings.Contains(lower, "error") ||
		strings.Contains(lower, "fail") ||
		strings.Contains(lower, "auth") ||
		strings.Contains(lower, "login") ||
		strings.Contains(lower, "to start this tsnet server")

	entry := fmt.Sprintf("%s %s", time.Now().Format("15:04:05"), trimmed)
	var snap *TailscaleStatus

	t.statusMu.Lock()
	n := len(t.status.RecentLogs)
	if n == 0 || !strings.HasSuffix(t.status.RecentLogs[n-1], " "+trimmed) {
		t.status.RecentLogs = append(t.status.RecentLogs, entry)
		if len(t.status.RecentLogs) > 25 {
			t.status.RecentLogs = append([]string(nil), t.status.RecentLogs[len(t.status.RecentLogs)-25:]...)
		}
		t.status.UpdatedAt = time.Now().Format(time.RFC3339)
		if isImportant || time.Since(t.lastFlushAt) >= time.Second {
			t.lastFlushAt = time.Now()
			copied := t.status.clone()
			snap = &copied
		}
	}
	t.statusMu.Unlock()

	if snap != nil {
		t.persistStatus(*snap)
	}
}

func (t *Tailscale) start() error {
	t.startOnce.Do(func() {
		t.updateStatus(func(st *TailscaleStatus) {
			st.BackendState = "Starting"
			st.LastError = ""
		})
		if err := t.server.Start(); err != nil {
			log.Errorln("[Tailscale](%s) tsnet start failed: %v", t.Name(), err)
			t.startErr = err
			t.updateStatus(func(st *TailscaleStatus) {
				st.BackendState = "Error"
				st.LastError = err.Error()
			})
			t.setBackendInitialized(err)
			return
		}
		t.serverStarted.Store(true)
		ctx, cancel := context.WithTimeout(t.ctx, 30*time.Second)
		defer cancel()
		if err := t.applyPrefs(ctx); err != nil {
			log.Errorln("[Tailscale](%s) apply prefs failed: %v", t.Name(), err)
			t.startErr = err
			t.updateStatus(func(st *TailscaleStatus) {
				st.BackendState = "Error"
				st.LastError = err.Error()
			})
			t.setBackendInitialized(err)
			return
		}
		go t.watchBackendState()
	})
	return t.startErr
}

// Start eagerly initializes the underlying tsnet.Server without waiting for the first dial.
func (t *Tailscale) Start() error {
	return t.start()
}

// LocalClient returns the tsnet LocalClient once the Tailscale server has started.
func (t *Tailscale) LocalClient() (*local.Client, error) {
	if t.server == nil || !t.serverStarted.Load() {
		return nil, errors.New("tailscale server not started")
	}
	return t.server.LocalClient()
}

// NotifyNetworkChange propagates an OS-level network switch or wake event into
// tsnet so MagicSock rebinds UDP/DERP sockets and re-runs STUN/Disco discovery
// without tearing down active inner Tailscale TCP streams.
func (t *Tailscale) NotifyNetworkChange(forceRebind bool, reason string) {
	if t == nil || t.server == nil || !t.serverStarted.Load() || t.ctx.Err() != nil {
		return
	}
	if reason == "" {
		reason = "host-network-change"
	}
	t.recordLog(fmt.Sprintf("network change (%s, rebind=%v)", reason, forceRebind), false)
	t.server.NotifyNetworkChange(forceRebind, reason)
}

// Option returns a copy of the configured Tailscale outbound options.
func (t *Tailscale) Option() TailscaleOption {
	return t.option
}

// ConnectICMP forwards real ICMP Echo packets through the Tailscale tsnet gVisor stack
// so `ping` to Tailscale peers and advertised subnet routers (e.g. 192.168.1.x) returns real RTT.
func (t *Tailscale) ConnectICMP(ctx context.Context, source, destination netip.Addr, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error) {
	if err := t.ensureStarted(ctx); err != nil {
		return nil, err
	}
	ns, err := t.server.Netstack(ctx)
	if err != nil {
		return nil, err
	}
	if ns == nil || ns.IPStack() == nil {
		return nil, errors.New("tailscale netstack unavailable")
	}

	var bind4, bind6 netip.Addr
	for _, rawIP := range t.StatusSnapshot().TailscaleIPs {
		addr, pErr := netip.ParseAddr(strings.TrimSpace(rawIP))
		if pErr != nil || !addr.IsValid() {
			continue
		}
		if addr.Is4() && !bind4.IsValid() {
			bind4 = addr
		} else if addr.Is6() && !bind6.IsValid() {
			bind6 = addr
		}
	}
	if (!destination.Is6() && !bind4.IsValid()) || (destination.Is6() && !bind6.IsValid()) {
		if lc, lcErr := t.server.LocalClient(); lcErr == nil {
			qCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			st, sErr := lc.StatusWithoutPeers(qCtx)
			cancel()
			if sErr == nil && st != nil {
				for _, addr := range st.TailscaleIPs {
					if addr.Is4() && !bind4.IsValid() {
						bind4 = addr
					} else if addr.Is6() && !bind6.IsValid() {
						bind6 = addr
					}
				}
			}
		}
	}

	return ping.ConnectGVisor(ctx, log.SingLogger, source, destination, routeContext, ns.IPStack(), bind4, bind6, timeout)
}

func (t *Tailscale) ensureStarted(ctx context.Context) error {
	if err := t.start(); err != nil {
		return err
	}
	return t.waitBackendInitialized(ctx)
}

type tailscaleWatchEvent struct {
	notify ipn.Notify
	err    error
}

func (t *Tailscale) watchBackendState() {
	lc, err := t.server.LocalClient()
	if err != nil {
		t.updateStatus(func(st *TailscaleStatus) {
			st.BackendState = "Error"
			st.LastError = err.Error()
		})
		t.setBackendInitialized(err)
		return
	}
	watcher, err := lc.WatchIPNBus(t.ctx, ipn.NotifyInitialState)
	if err != nil {
		t.updateStatus(func(st *TailscaleStatus) {
			st.BackendState = "Error"
			st.LastError = err.Error()
		})
		t.setBackendInitialized(err)
		return
	}
	defer watcher.Close()

	eventCh := make(chan tailscaleWatchEvent, 8)
	go func() {
		for {
			n, nextErr := watcher.Next()
			select {
			case eventCh <- tailscaleWatchEvent{notify: n, err: nextErr}:
			case <-t.ctx.Done():
				return
			}
			if nextErr != nil {
				return
			}
		}
	}()

	backendInitialized := false
	exitNodeNeedsStatus := tailscaleExitNodeNeedsStatus(t.option)
	exitNodeApplied := false
	subnetForwarderInstalled := false
	var lastAuthRequest time.Time

	ensureRunningFeatures := func() {
		if len(t.advertisePrefixes) > 0 && !subnetForwarderInstalled {
			if err := t.applyPrefs(t.ctx); err != nil {
				log.Warnln("[Tailscale](%s) re-apply advertise-routes prefs failed: %v", t.Name(), err)
			}
			if t.installSubnetRouteForwarders(t.ctx) {
				subnetForwarderInstalled = true
			}
		}
	}

	refreshFromLocalClient := func() string {
		ctx, cancel := context.WithTimeout(t.ctx, 3*time.Second)
		st, statusErr := lc.StatusWithoutPeers(ctx)
		cancel()
		if statusErr != nil {
			if t.ctx.Err() == nil {
				t.recordLog(fmt.Sprintf("status query failed: %v", statusErr), false)
			}
			return ""
		}

		ips := make([]string, 0, len(st.TailscaleIPs))
		for _, ip := range st.TailscaleIPs {
			ips = append(ips, ip.String())
		}
		var authURL string
		t.updateStatus(func(out *TailscaleStatus) {
			out.BackendState = st.BackendState
			if st.BackendState == ipn.Running.String() {
				out.AuthURL = ""
				out.LastError = ""
			} else if st.AuthURL != "" {
				out.AuthURL = st.AuthURL
			}
			authURL = out.AuthURL
			out.TailscaleIPs = ips
			if st.Self != nil && st.Self.HostName != "" {
				out.Hostname = st.Self.HostName
			}
			out.Health = cloneNonNilStrings(st.Health)
		})

		if st.BackendState == ipn.NeedsLogin.String() && authURL == "" && t.option.AuthKey == "" &&
			time.Since(lastAuthRequest) >= 15*time.Second {
			lastAuthRequest = time.Now()
			loginCtx, loginCancel := context.WithTimeout(t.ctx, 5*time.Second)
			loginErr := lc.StartLoginInteractive(loginCtx)
			loginCancel()
			if loginErr != nil && t.ctx.Err() == nil {
				t.recordLog(fmt.Sprintf("StartLoginInteractive failed: %v", loginErr), true)
			} else if loginErr == nil {
				t.recordLog("requested interactive login URL", true)
			}
		}
		return st.BackendState
	}

	currentState := refreshFromLocalClient()
	if currentState == ipn.Running.String() {
		ensureRunningFeatures()
	}
	tickerInterval := 3 * time.Second
	if currentState == ipn.Running.String() {
		tickerInterval = 30 * time.Second
	}
	ticker := time.NewTicker(tickerInterval)
	defer ticker.Stop()

	updateTicker := func(state string) {
		if state == "" {
			return
		}
		desired := 3 * time.Second
		if state == ipn.Running.String() {
			desired = 30 * time.Second
		}
		if desired != tickerInterval {
			tickerInterval = desired
			ticker.Reset(desired)
		}
	}

	for {
		select {
		case <-t.ctx.Done():
			return
		case ev := <-eventCh:
			if ev.err != nil {
				if t.ctx.Err() == nil {
					t.setBackendInitialized(ev.err)
					t.recordLog(fmt.Sprintf("IPN bus watch stopped: %v", ev.err), true)
				}
				return
			}
			n := ev.notify
			if n.BrowseToURL != nil && *n.BrowseToURL != "" {
				urlStr := *n.BrowseToURL
				log.Infoln("[Tailscale](%s) login URL: %s", t.Name(), urlStr)
				t.updateStatus(func(out *TailscaleStatus) {
					out.AuthURL = urlStr
				})
				t.recordLog(fmt.Sprintf("login URL ready: %s", urlStr), true)
			}
			if n.State != nil {
				if *n.State != ipn.NoState && !backendInitialized {
					t.setBackendInitialized(nil)
					backendInitialized = true
				}
				if *n.State == ipn.Running {
					ensureRunningFeatures()
					if exitNodeNeedsStatus && !exitNodeApplied {
						if err := t.applyExitNodePrefs(t.ctx); err != nil {
							log.Warnln("[Tailscale](%s) set exit node failed: %v", t.Name(), err)
							t.recordLog(fmt.Sprintf("set exit node failed: %v", err), true)
						} else {
							exitNodeApplied = true
						}
					}
				}
				state := refreshFromLocalClient()
				if state == ipn.Running.String() {
					ensureRunningFeatures()
				}
				updateTicker(state)
			}
		case <-ticker.C:
			state := refreshFromLocalClient()
			if state == ipn.Running.String() {
				ensureRunningFeatures()
			}
			updateTicker(state)
		}
	}
}

func (t *Tailscale) setBackendInitialized(err error) {
	t.backendInitOnce.Do(func() {
		t.backendInitErr = err
		close(t.backendInitCh)
	})
}

func (t *Tailscale) waitBackendInitialized(ctx context.Context) error {
	select {
	case <-t.backendInitCh:
		return t.backendInitErr
	case <-ctx.Done():
		return ctx.Err()
	case <-t.ctx.Done():
		return t.ctx.Err()
	}
}

func (t *Tailscale) applyPrefs(ctx context.Context) error {
	mp, err := buildTailscaleMaskedPrefs(t.option)
	if err != nil {
		return err
	}
	if mp == nil {
		return nil
	}
	lc, err := t.server.LocalClient()
	if err != nil {
		return err
	}
	_, err = lc.EditPrefs(ctx, mp)
	return err
}

func (t *Tailscale) applyExitNodePrefs(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	lc, err := t.server.LocalClient()
	if err != nil {
		return err
	}
	status, err := lc.Status(ctx)
	if err != nil {
		return err
	}
	mp := &ipn.MaskedPrefs{
		ExitNodeIPSet: true,
	}
	if t.option.ExitNodeAllowLANAccess != nil {
		mp.ExitNodeAllowLANAccess = *t.option.ExitNodeAllowLANAccess
		mp.ExitNodeAllowLANAccessSet = true
	}
	if err = mp.SetExitNodeIP(t.option.ExitNode, status); err != nil {
		return err
	}
	_, err = lc.EditPrefs(ctx, mp)
	return err
}

func buildTailscaleMaskedPrefs(option TailscaleOption) (*ipn.MaskedPrefs, error) {
	var mp ipn.MaskedPrefs
	changed := false

	if option.AcceptRoutes != nil {
		mp.RouteAll = *option.AcceptRoutes
		mp.RouteAllSet = true
		changed = true
	}
	if option.AdvertiseRoutes != nil {
		prefixes, err := parseTailscaleAdvertiseRoutes(option.AdvertiseRoutes)
		if err != nil {
			return nil, err
		}
		mp.AdvertiseRoutes = prefixes
		mp.AdvertiseRoutesSet = true
		changed = true
	}
	if option.ExitNode != "" {
		if autoExitNode, ok := ipn.ParseAutoExitNodeString(option.ExitNode); ok {
			mp.AutoExitNode = autoExitNode
			mp.AutoExitNodeSet = true
			changed = true
		}
	}
	if option.ExitNodeAllowLANAccess != nil && !tailscaleExitNodeNeedsStatus(option) {
		mp.ExitNodeAllowLANAccess = *option.ExitNodeAllowLANAccess
		mp.ExitNodeAllowLANAccessSet = true
		changed = true
	}
	if !changed {
		return nil, nil
	}
	return &mp, nil
}

func tailscaleExitNodeNeedsStatus(option TailscaleOption) bool {
	if option.ExitNode == "" {
		return false
	}
	_, ok := ipn.ParseAutoExitNodeString(option.ExitNode)
	return !ok
}

func parseTailscaleAdvertiseRoutes(raw []string) ([]netip.Prefix, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(raw))
	seen := make(map[netip.Prefix]bool, len(raw))
	for _, entry := range raw {
		s := strings.TrimSpace(entry)
		if s == "" {
			continue
		}
		p, err := netip.ParsePrefix(s)
		if err != nil {
			return nil, fmt.Errorf("invalid tailscale advertise-route %q: %w", s, err)
		}
		p = p.Masked()
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out, nil
}

func (t *Tailscale) isAdvertisedSubnetIP(ip netip.Addr) bool {
	if !ip.IsValid() || tsaddr.IsTailscaleIP(ip) {
		return false
	}
	u := ip.Unmap()
	for _, p := range t.advertisePrefixes {
		if p.Contains(u) {
			return true
		}
	}
	return false
}

// installSubnetRouteForwarders allows tsnet's netstack to forward inbound TCP/UDP
// connections targeting explicitly advertised non-Tailscale subnet CIDRs (e.g. 10.10.1.0/24)
// to the host/LAN via SystemDial, while keeping all Tailscale self-IP traffic closed by default.
func (t *Tailscale) installSubnetRouteForwarders(ctx context.Context) bool {
	if len(t.advertisePrefixes) == 0 || t.server == nil {
		return true
	}
	nsCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ns, err := t.server.Netstack(nsCtx)
	if err != nil || ns == nil {
		log.Warnln("[Tailscale](%s) enable subnet route forwarder failed: %v", t.Name(), err)
		return false
	}
	origTCP := ns.GetTCPHandlerForFlow
	ns.GetTCPHandlerForFlow = func(src, dst netip.AddrPort) (func(net.Conn), bool) {
		if t.isAdvertisedSubnetIP(dst.Addr()) {
			return nil, false
		}
		if origTCP != nil {
			return origTCP(src, dst)
		}
		return nil, true
	}
	origUDP := ns.GetUDPHandlerForFlow
	ns.GetUDPHandlerForFlow = func(src, dst netip.AddrPort) (func(nettype.ConnPacketConn), bool) {
		if t.isAdvertisedSubnetIP(dst.Addr()) {
			return nil, false
		}
		if origUDP != nil {
			return origUDP(src, dst)
		}
		return nil, true
	}
	log.Infoln("[Tailscale](%s) enabled subnet router forwarding for %v", t.Name(), t.advertisePrefixes)
	return true
}

func (t *Tailscale) DialContext(ctx context.Context, metadata *C.Metadata) (_ C.Conn, err error) {
	if err = t.ensureStarted(ctx); err != nil {
		return nil, err
	}
	netStack, err := t.server.Netstack(ctx)
	if err != nil {
		return nil, err
	}
	v4, v6 := t.server.TailscaleIPs()
	options := t.DialOptions()
	options = append(options, dialer.WithResolver(t.dnsResolver))
	options = append(options, dialer.WithNetDialer(dialer.NetDialerFunc(func(ctx context.Context, network, address string) (net.Conn, error) {
		dst, err := netip.ParseAddrPort(address) // the dialer will resolve the domain to ip
		if err != nil {
			return nil, err
		}
		src := v4
		if dst.Addr().Is6() {
			src = v6
		}
		tcpConn, err := netStack.DialContextTCPWithBind(ctx, src, dst)
		if err != nil {
			return nil, err
		}
		return tcpConn, nil
	})))
	var conn net.Conn
	conn, err = dialer.NewDialer(options...).DialContext(ctx, "tcp", metadata.RemoteAddress())
	if err != nil {
		return nil, err
	}
	if conn == nil {
		return nil, errors.New("conn is nil")
	}
	return NewConn(conn, t), nil
}

func (t *Tailscale) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (_ C.PacketConn, err error) {
	if err = t.ensureStarted(ctx); err != nil {
		return nil, err
	}
	if err = t.ResolveUDP(ctx, metadata); err != nil {
		return nil, err
	}
	v4, v6 := t.server.TailscaleIPs()
	src := v4
	if metadata.DstIP.Is6() {
		src = v6
	}
	pc, err := t.server.ListenPacket("udp", net.JoinHostPort(src.String(), "0"))
	if err != nil {
		return nil, err
	}
	if pc == nil {
		return nil, errors.New("packetConn is nil")
	}
	return NewPacketConn(pc, t), nil
}

func (t *Tailscale) ResolveUDP(ctx context.Context, metadata *C.Metadata) error {
	if metadata.Host != "" {
		ip, err := resolveIPWithResolver(ctx, metadata.Host, t.prefer, t.dnsResolver)
		if err != nil {
			return fmt.Errorf("can't resolve ip: %w", err)
		}
		metadata.DstIP = ip
	}
	return nil
}

type tailscaleDNSTransport struct {
	tailscale *Tailscale
}

func (t tailscaleDNSTransport) Address() string {
	return "tailscale://" + t.tailscale.Name()
}

func (t tailscaleDNSTransport) ResetConnection() {}

func (t tailscaleDNSTransport) ExchangeContext(ctx context.Context, msg *D.Msg) (*D.Msg, error) {
	if len(msg.Question) == 0 {
		return nil, errors.New("should have one question at least")
	}
	if err := t.tailscale.ensureStarted(ctx); err != nil {
		return nil, err
	}
	q := msg.Question[0]
	if q.Qtype == D.TypeHTTPS || q.Qtype == D.TypeSVCB {
		resp := new(D.Msg)
		resp.SetReply(msg)
		resp.RecursionAvailable = true
		return resp, nil
	}
	qtypeName, ok := D.TypeToString[q.Qtype]
	if !ok {
		return nil, fmt.Errorf("unsupported query type: %d", q.Qtype)
	}
	lc, err := t.tailscale.server.LocalClient()
	if err != nil {
		return nil, err
	}
	response, _, err := lc.QueryDNS(ctx, q.Name, qtypeName)
	if err != nil {
		return nil, err
	}
	var responseMsg D.Msg
	if err = responseMsg.Unpack(response); err != nil {
		return nil, err
	}
	responseMsg.Id = msg.Id
	return &responseMsg, nil
}

func (t *Tailscale) ProxyInfo() C.ProxyInfo {
	info := t.Base.ProxyInfo()
	info.DialerProxy = t.option.DialerProxy
	return info
}

func (t *Tailscale) IsL3Protocol(metadata *C.Metadata) bool {
	return true
}

func (t *Tailscale) Close() error {
	t.cancel()
	if t.unregisterDNSResolver != nil {
		t.unregisterDNSResolver()
	}
	t.startOnce.Do(func() {
		t.startErr = errors.New("tailscale outbound closed")
	})
	if t.server != nil && t.serverStarted.Load() { // tsnet.Server.Close() must not be called before or concurrently with Start.
		t.updateStatus(func(st *TailscaleStatus) {
			st.BackendState = "Stopped"
			st.AuthURL = ""
		})
		return t.server.Close()
	}
	return nil
}
