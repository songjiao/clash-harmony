package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/tailscale/net/netns"
	"golang.org/x/sys/unix"
)

const (
	defaultControllerAddr = "127.0.0.1:9090"
	maxCoreLogBytes       = 256 * 1024
)

type tailscaleStarter interface {
	Start() error
}

type adapterUnwrapper interface {
	UnwrapAdapter() C.ProxyAdapter
}

type bridgeManager struct {
	mu            sync.Mutex
	running       bool
	lastErr       string
	errorLogMu    sync.Mutex
	lastErrorLog  string
	activeCtlAddr string
	logFilePath   string
	logSub        observable.Subscription[log.Event]
	logStopDone   chan struct{}
	tsAPIServer   *http.Server
	tsAPIAddr     string
}

var bridge bridgeManager

func init() {
	// OpenHarmony app sandboxes lack a writable/standard /etc/resolv.conf, so use Go's resolver,
	// and disable Linux netns socket marks / SO_BINDTODEVICE which fail inside app sandboxes.
	net.DefaultResolver.PreferGo = true
	netns.SetEnabled(false)
}

func (m *bridgeManager) versionString() string {
	return fmt.Sprintf("mihomo-%s-tailscale-ohos", C.Version)
}

func (m *bridgeManager) adapterInfoJSON() string {
	return fmt.Sprintf(
		`{"implementation":"mihomo","version":%q,"supportsControllerOnly":true,"supportsTunAttach":false,"tailscale":true}`,
		m.versionString(),
	)
}

func (m *bridgeManager) lastError() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastErr
}

func (m *bridgeManager) setLastErrorLocked(err error) {
	if err == nil {
		m.lastErr = ""
		return
	}
	m.lastErr = err.Error()
}

func configureRuntimeConfig(cfg *config.Config, tunFd int) (int, error) {
	if cfg == nil {
		return -1, fmt.Errorf("nil config")
	}
	if cfg.General == nil {
		cfg.General = &config.General{}
	}
	if cfg.Controller == nil {
		cfg.Controller = &config.Controller{}
	}
	if strings.TrimSpace(cfg.Controller.ExternalController) == "" {
		cfg.Controller.ExternalController = defaultControllerAddr
	}
	if tunFd < 0 {
		cfg.General.Tun.Enable = false
		cfg.General.Tun.FileDescriptor = 0
		return -1, nil
	}

	dupFd, err := unix.Dup(tunFd)
	if err != nil {
		return -1, fmt.Errorf("dup tun fd %d: %w", tunFd, err)
	}

	cfg.General.Tun.Enable = true
	cfg.General.Tun.Stack = C.TunGvisor
	cfg.General.Tun.FileDescriptor = dupFd
	cfg.General.Tun.Device = "vpn-tun"
	if cfg.General.Tun.MTU == 0 || cfg.General.Tun.MTU > 1360 {
		cfg.General.Tun.MTU = 1360
	}
	if len(cfg.General.Tun.Inet4Address) == 0 {
		cfg.General.Tun.Inet4Address = []netip.Prefix{netip.MustParsePrefix("198.18.0.1/16")}
	}
	cfg.General.Tun.DNSHijack = []string{"any:53"}
	cfg.General.Tun.AutoRoute = false
	cfg.General.Tun.AutoRedirect = false
	cfg.General.Tun.AutoDetectInterface = false
	cfg.General.Tun.EndpointIndependentNat = true
	cfg.General.Tun.StrictRoute = false
	return dupFd, nil
}

func (m *bridgeManager) startLogSinkLocked(logPath string) error {
	m.stopLogSinkLocked()

	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}

	sub := log.Subscribe()
	done := make(chan struct{})
	m.logFilePath = logPath
	m.logSub = sub
	m.logStopDone = done

	go func() {
		defer close(done)
		defer f.Close()
		var written int64
		for ev := range sub {
			if ev.LogLevel >= log.ERROR {
				m.errorLogMu.Lock()
				m.lastErrorLog = ev.Payload
				m.errorLogMu.Unlock()
			}
			if ev.LogLevel < log.Level() {
				continue
			}
			line := fmt.Sprintf("%s [%s] %s\n", time.Now().Format("15:04:05"), strings.ToUpper(ev.LogLevel.String()), ev.Payload)
			n, _ := f.WriteString(line)
			written += int64(n)
			if written > maxCoreLogBytes {
				_ = f.Truncate(0)
				_, _ = f.Seek(0, io.SeekStart)
				_, _ = f.WriteString(line)
				written = int64(len(line))
			}
		}
	}()
	return nil
}

func (m *bridgeManager) stopLogSinkLocked() {
	if m.logSub != nil {
		log.UnSubscribe(m.logSub)
		m.logSub = nil
	}
	if m.logStopDone != nil {
		<-m.logStopDone
		m.logStopDone = nil
	}
}

func eagerStartTailscaleProxies() {
	for _, proxy := range tunnel.Proxies() {
		if proxy == nil || proxy.Type() != C.Tailscale {
			continue
		}
		adapter := proxy.Adapter()
		for {
			unwrapper, ok := adapter.(adapterUnwrapper)
			if !ok {
				break
			}
			adapter = unwrapper.UnwrapAdapter()
		}
		starter, ok := adapter.(tailscaleStarter)
		if !ok {
			log.Warnln("[Bridge] Tailscale outbound %s (%T) does not implement Start()", proxy.Name(), adapter)
			continue
		}
		name := proxy.Name()
		log.Infoln("[Bridge] Starting Tailscale outbound: %s", name)
		go func() {
			if err := starter.Start(); err != nil {
				log.Errorln("[Tailscale](%s) eager start failed: %v", name, err)
				return
			}
			log.Infoln("[Bridge] Tailscale outbound started: %s", name)
		}()
	}
}

func (m *bridgeManager) startEngine(configPath string, tunFd int) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.running {
		m.stopEngineLocked()
	}

	cleanPath := strings.TrimSpace(configPath)
	if cleanPath == "" {
		err := fmt.Errorf("empty config path")
		m.setLastErrorLocked(err)
		return err
	}

	homeDir := filepath.Dir(cleanPath)
	if err := os.MkdirAll(homeDir, 0o755); err != nil {
		err = fmt.Errorf("prepare runtime dir %s: %w", homeDir, err)
		m.setLastErrorLocked(err)
		return err
	}

	C.SetHomeDir(homeDir)
	C.SetConfig(cleanPath)
	if err := config.Init(homeDir); err != nil {
		err = fmt.Errorf("init config dir: %w", err)
		m.setLastErrorLocked(err)
		return err
	}

	_ = os.Remove(filepath.Join(homeDir, "tailscale-status.json"))

	m.errorLogMu.Lock()
	m.lastErrorLog = ""
	m.errorLogMu.Unlock()
	if err := m.startLogSinkLocked(filepath.Join(homeDir, "mihomo-core.log")); err != nil {
		err = fmt.Errorf("open log sink: %w", err)
		m.setLastErrorLocked(err)
		return err
	}

	cfg, err := executor.ParseWithPath(cleanPath)
	if err != nil {
		m.stopLogSinkLocked()
		err = fmt.Errorf("parse config %s: %w", cleanPath, err)
		m.setLastErrorLocked(err)
		return err
	}

	dupFd, err := configureRuntimeConfig(cfg, tunFd)
	if err != nil {
		m.stopLogSinkLocked()
		m.setLastErrorLocked(err)
		return err
	}

	applied := false
	defer func() {
		if !applied && dupFd >= 0 {
			_ = unix.Close(dupFd)
		}
	}()

	hub.ApplyConfig(cfg)
	applied = true
	m.activeCtlAddr = cfg.Controller.ExternalController
	m.running = true

	actualTun := listener.GetTunConf()
	if tunFd >= 0 && !actualTun.Enable {
		m.errorLogMu.Lock()
		detail := strings.TrimSpace(m.lastErrorLog)
		m.errorLogMu.Unlock()
		m.stopEngineLocked()
		if detail != "" {
			err = fmt.Errorf("TUN start failed: %s", detail)
		} else {
			err = fmt.Errorf("TUN start failed: enable=false for fd=%d", dupFd)
		}
		m.setLastErrorLocked(err)
		return err
	}

	m.setLastErrorLocked(nil)
	log.Infoln("[Bridge] Mihomo core started (tun=%v, fd=%d, ctl=%s)",
		actualTun.Enable, actualTun.FileDescriptor, m.activeCtlAddr)
	m.startTailscaleAPILocked(defaultTailscaleAPIAddr)
	eagerStartTailscaleProxies()
	return nil
}

func closeAllActiveProxies() {
	for _, proxy := range tunnel.Proxies() {
		if proxy == nil {
			continue
		}
		if closer, ok := proxy.Adapter().(io.Closer); ok {
			_ = closer.Close()
		}
	}
	tunnel.UpdateProxies(map[string]C.Proxy{}, map[string]P.ProxyProvider{})
}

func waitPortReleased(addr string, timeout time.Duration) {
	if strings.TrimSpace(addr) == "" {
		return
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 20*time.Millisecond)
		if err != nil {
			return
		}
		_ = conn.Close()
		time.Sleep(15 * time.Millisecond)
	}
}

func (m *bridgeManager) stopEngineLocked() {
	ctlAddr := m.activeCtlAddr
	m.activeCtlAddr = ""
	m.running = false

	m.stopTailscaleAPILocked()
	executor.Shutdown()
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.PatchInboundListeners(map[string]C.InboundListener{}, tunnel.Tunnel, true)
	dns.ReCreateServer("", nil, nil)
	route.ReCreateServer(&route.Config{})
	closeAllActiveProxies()

	waitPortReleased(ctlAddr, 500*time.Millisecond)
	m.stopLogSinkLocked()
}

func (m *bridgeManager) stopEngine() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stopEngineLocked()
	m.setLastErrorLocked(nil)
	return nil
}
