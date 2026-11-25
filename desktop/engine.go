package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
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
	"github.com/metacubex/tailscale/ipn"
)

const (
	maxCoreLogBytes = 512 * 1024
	maxLogRingLines = 400
)

type tailscaleStarter interface {
	Start() error
}

type adapterUnwrapper interface {
	UnwrapAdapter() C.ProxyAdapter
}

type DesktopEngineState struct {
	Version           string `json:"version"`
	CoreVersion       string `json:"coreVersion"`
	Running           bool   `json:"running"`
	Elevated          bool   `json:"elevated"`
	ActiveProfileID   string `json:"activeProfileId"`
	ActiveProfileName string `json:"activeProfileName"`
	SystemProxyActive bool   `json:"systemProxyActive"`
	SystemProxyWanted bool   `json:"systemProxy"`
	TunActive         bool   `json:"tunActive"`
	TunWanted         bool   `json:"tunMode"`
	TunStack          string `json:"tunStack"`
	StrictRoute       bool   `json:"strictRoute"`
	BlockQuic         bool   `json:"blockQuic"`
	MixedPort         int    `json:"mixedPort"`
	ControllerAddr    string `json:"controllerAddr"`
	UIAddr            string `json:"uiAddr"`
	AutoStartCore     bool   `json:"autoStartCore"`
	StartWithWindows  bool   `json:"startWithWindows"`
	ProxyBypass       string `json:"proxyBypass"`
	AutoUpdateHours   int    `json:"autoUpdateHours"`
	OverlayEnabled    bool   `json:"overlayEnabled"`
	DataDir           string `json:"dataDir"`
	LastError         string `json:"lastError"`
	StartedAt         string `json:"startedAt,omitempty"`
}

type DesktopEngine struct {
	store *DataStore
	proxy *SystemProxyManager

	mu                sync.Mutex
	running           bool
	tunActive         bool
	activeCtlAddr     string
	activeProfileID   string
	activeProfileName string
	startedAt         time.Time
	lastErr           string

	logSub      observable.Subscription[log.Event]
	logStopDone chan struct{}

	ringMu   sync.RWMutex
	logRing  []string
	lastErrL string

	syncCancel context.CancelFunc
	onChange   func()
}

func NewDesktopEngine(store *DataStore) *DesktopEngine {
	return &DesktopEngine{
		store:   store,
		proxy:   NewSystemProxyManager(),
		logRing: make([]string, 0, maxLogRingLines),
	}
}

func (e *DesktopEngine) SetOnChange(fn func()) {
	e.mu.Lock()
	e.onChange = fn
	e.mu.Unlock()
}

func (e *DesktopEngine) notifyChange() {
	e.mu.Lock()
	fn := e.onChange
	e.mu.Unlock()
	if fn != nil {
		go fn()
	}
}

func (e *DesktopEngine) CoreVersion() string {
	return fmt.Sprintf("mihomo-%s-tailscale-desktop", C.Version)
}

func (e *DesktopEngine) State() DesktopEngineState {
	settings := e.store.LoadSettings()
	e.mu.Lock()
	running := e.running
	tunActive := e.tunActive
	lastErr := e.lastErr
	profID := e.activeProfileID
	profName := e.activeProfileName
	startedAt := ""
	if running && !e.startedAt.IsZero() {
		startedAt = e.startedAt.Format(time.RFC3339)
	}
	e.mu.Unlock()

	if profID == "" {
		profID = settings.ActiveProfileID
	}
	if profName == "" && profID != "" {
		if meta, _, err := e.store.GetProfile(profID); err == nil {
			profName = meta.Name
		}
	}

	return DesktopEngineState{
		Version:           appVersion,
		CoreVersion:       e.CoreVersion(),
		Running:           running,
		Elevated:          IsElevated(),
		ActiveProfileID:   profID,
		ActiveProfileName: profName,
		SystemProxyActive: e.proxy.IsActive(),
		SystemProxyWanted: settings.SystemProxy,
		TunActive:         tunActive,
		TunWanted:         settings.TunMode,
		TunStack:          settings.TunStack,
		StrictRoute:       settings.StrictRoute,
		BlockQuic:         settings.BlockQuic,
		MixedPort:         settings.MixedPort,
		ControllerAddr:    settings.ControllerAddr,
		UIAddr:            settings.UIAddr,
		AutoStartCore:     settings.AutoStartCore,
		StartWithWindows:  IsAutoStartEnabled(),
		ProxyBypass:       settings.ProxyBypass,
		AutoUpdateHours:   settings.AutoUpdateHours,
		OverlayEnabled:    e.store.LoadOverlay().Enabled,
		DataDir:           e.store.BaseDir(),
		LastError:         lastErr,
		StartedAt:         startedAt,
	}
}

// RecoverAfterResume rebuilds TUN routes and WFP rules cleanly after Windows sleep/standby wake-up.
func (e *DesktopEngine) RecoverAfterResume() {
	e.mu.Lock()
	shouldRecover := e.running && e.tunActive
	e.mu.Unlock()
	if !shouldRecover {
		return
	}
	go func() {
		log.Infoln("[Desktop] System resumed from sleep; scheduling TUN/route recovery in 4s...")
		time.Sleep(4 * time.Second)
		e.mu.Lock()
		stillRunning := e.running && e.tunActive
		e.mu.Unlock()
		if !stillRunning {
			return
		}
		if err := e.Restart(); err != nil {
			log.Warnln("[Desktop] Post-resume TUN recovery failed: %v", err)
		} else {
			log.Infoln("[Desktop] Post-resume TUN recovery completed")
		}
	}()
}

func (e *DesktopEngine) RecentLogs(limit int) []string {
	e.ringMu.RLock()
	defer e.ringMu.RUnlock()
	if limit <= 0 || limit >= len(e.logRing) {
		return append([]string(nil), e.logRing...)
	}
	return append([]string(nil), e.logRing[len(e.logRing)-limit:]...)
}

func (e *DesktopEngine) appendRingLine(line string) {
	e.ringMu.Lock()
	e.logRing = append(e.logRing, line)
	if len(e.logRing) > maxLogRingLines {
		e.logRing = append([]string(nil), e.logRing[len(e.logRing)-maxLogRingLines:]...)
	}
	e.ringMu.Unlock()
}

func (e *DesktopEngine) startLogSinkLocked(logPath string) error {
	e.stopLogSinkLocked()

	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}

	sub := log.Subscribe()
	done := make(chan struct{})
	e.logSub = sub
	e.logStopDone = done

	e.ringMu.Lock()
	e.lastErrL = ""
	e.ringMu.Unlock()

	go func() {
		defer close(done)
		defer f.Close()
		var written int64
		for ev := range sub {
			if ev.LogLevel >= log.ERROR {
				e.ringMu.Lock()
				e.lastErrL = ev.Payload
				e.ringMu.Unlock()
			}
			if ev.LogLevel < log.Level() {
				continue
			}
			line := fmt.Sprintf("%s [%s] %s", time.Now().Format("15:04:05"), strings.ToUpper(ev.LogLevel.String()), ev.Payload)
			e.appendRingLine(line)
			n, _ := f.WriteString(line + "\n")
			written += int64(n)
			if written > maxCoreLogBytes {
				_ = f.Truncate(0)
				_, _ = f.Seek(0, io.SeekStart)
				_, _ = f.WriteString(line + "\n")
				written = int64(len(line) + 1)
			}
		}
	}()
	return nil
}

func (e *DesktopEngine) stopLogSinkLocked() {
	if e.logSub != nil {
		log.UnSubscribe(e.logSub)
		e.logSub = nil
	}
	if e.logStopDone != nil {
		<-e.logStopDone
		e.logStopDone = nil
	}
}

func (e *DesktopEngine) Start() error {
	e.mu.Lock()
	err := e.startLocked()
	e.mu.Unlock()
	e.notifyChange()
	return err
}

func (e *DesktopEngine) Stop() error {
	e.mu.Lock()
	e.stopLocked()
	e.lastErr = ""
	e.mu.Unlock()
	e.notifyChange()
	return nil
}

func (e *DesktopEngine) Restart() error {
	e.mu.Lock()
	if e.running {
		e.stopLocked()
	}
	err := e.startLocked()
	e.mu.Unlock()
	e.notifyChange()
	return err
}

func (e *DesktopEngine) UpdateSystemProxyState() error {
	settings := e.store.LoadSettings()
	e.mu.Lock()
	running := e.running
	e.mu.Unlock()

	var err error
	if running && settings.SystemProxy {
		err = e.proxy.Enable(fmt.Sprintf("127.0.0.1:%d", settings.MixedPort), settings.ProxyBypass)
	} else {
		err = e.proxy.Restore()
	}
	e.notifyChange()
	return err
}

func (e *DesktopEngine) startLocked() error {
	if e.running {
		e.stopLocked()
	}

	settings := e.store.LoadSettings()
	if settings.TunMode && !IsElevated() {
		err := fmt.Errorf("开启 TUN 全局接管需要管理员权限，请先点击「以管理员重启」或关闭 TUN 模式")
		e.lastErr = err.Error()
		return err
	}

	profID := strings.TrimSpace(settings.ActiveProfileID)
	if profID == "" {
		profiles := e.store.ListProfiles()
		if len(profiles) == 0 {
			err := fmt.Errorf("尚未导入任何配置，请先在「订阅配置」中导入 YAML 或订阅链接")
			e.lastErr = err.Error()
			return err
		}
		profID = profiles[0].ID
		settings.ActiveProfileID = profID
		_ = e.store.SaveSettings(settings)
	}

	meta, rawYAML, err := e.store.GetProfile(profID)
	if err != nil {
		err = fmt.Errorf("加载配置失败: %w", err)
		e.lastErr = err.Error()
		return err
	}

	runtimeDir := e.store.RuntimeDir()
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		e.lastErr = err.Error()
		return err
	}
	ensureGeoipDB(runtimeDir)

	tsPrefs := e.store.LoadTailscalePrefs()
	overlay := e.store.LoadOverlay()
	runtimeYAML, err := BuildRuntimeYAMLWithOverlay(rawYAML, overlay, tsPrefs, settings)
	if err != nil {
		err = fmt.Errorf("融合自建节点/覆写层失败: %w", err)
		e.lastErr = err.Error()
		return err
	}
	runtimePath := e.store.RuntimeConfigPath()
	if err := writeAtomicBytes(runtimePath, []byte(runtimeYAML)); err != nil {
		err = fmt.Errorf("写入运行配置失败: %w", err)
		e.lastErr = err.Error()
		return err
	}

	C.SetHomeDir(runtimeDir)
	C.SetConfig(runtimePath)
	if err := config.Init(runtimeDir); err != nil {
		err = fmt.Errorf("初始化配置目录失败: %w", err)
		e.lastErr = err.Error()
		return err
	}

	_ = os.Remove(filepath.Join(runtimeDir, "tailscale-status.json"))

	if err := e.startLogSinkLocked(e.store.CoreLogPath()); err != nil {
		err = fmt.Errorf("打开日志文件失败: %w", err)
		e.lastErr = err.Error()
		return err
	}

	cfg, err := executor.ParseWithPath(runtimePath)
	if err != nil {
		e.stopLogSinkLocked()
		err = fmt.Errorf("解析配置失败: %w", err)
		e.lastErr = err.Error()
		return err
	}

	if cfg.Controller == nil {
		cfg.Controller = &config.Controller{}
	}
	cfg.Controller.ExternalController = settings.ControllerAddr

	hub.ApplyConfig(cfg)
	e.activeCtlAddr = cfg.Controller.ExternalController
	e.activeProfileID = meta.ID
	e.activeProfileName = meta.Name
	e.startedAt = time.Now()
	e.running = true

	actualTun := listener.GetTunConf()
	e.tunActive = actualTun.Enable
	if settings.TunMode && !actualTun.Enable {
		e.ringMu.RLock()
		detail := strings.TrimSpace(e.lastErrL)
		e.ringMu.RUnlock()
		e.stopLocked()
		if detail != "" {
			err = fmt.Errorf("Wintun TUN 启动失败: %s", detail)
		} else {
			err = fmt.Errorf("Wintun TUN 启动失败 (enable=false)，请确认以管理员身份运行且无冲突虚拟网卡")
		}
		e.lastErr = err.Error()
		return err
	}

	if settings.SystemProxy {
		if pErr := e.proxy.Enable(fmt.Sprintf("127.0.0.1:%d", settings.MixedPort), settings.ProxyBypass); pErr != nil {
			log.Warnln("[Desktop] Enable system proxy failed: %v", pErr)
		}
	} else {
		_ = e.proxy.Restore()
	}

	e.lastErr = ""
	log.Infoln("[Desktop] Mihomo core started (profile=%s, tun=%v, sysproxy=%v, mixed=%d, ctl=%s)",
		meta.Name, e.tunActive, e.proxy.IsActive(), settings.MixedPort, e.activeCtlAddr)

	eagerStartTailscaleProxies()

	syncCtx, cancel := context.WithCancel(context.Background())
	e.syncCancel = cancel
	go e.splitDNSSyncLoop(syncCtx)
	go e.autoUpdateSubLoop(syncCtx)
	return nil
}

func (e *DesktopEngine) autoUpdateSubLoop(ctx context.Context) {
	ticker := time.NewTicker(15 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			settings := e.store.LoadSettings()
			if settings.AutoUpdateHours <= 0 || settings.ActiveProfileID == "" {
				continue
			}
			meta, _, err := e.store.GetProfile(settings.ActiveProfileID)
			if err != nil || strings.TrimSpace(meta.URL) == "" {
				continue
			}
			lastUpdate, err := time.Parse(time.RFC3339, meta.UpdatedAt)
			if err == nil && time.Since(lastUpdate) < time.Duration(settings.AutoUpdateHours)*time.Hour {
				continue
			}
			log.Infoln("[Desktop] Auto-updating subscription %s (interval=%dh)...", meta.Name, settings.AutoUpdateHours)
			res, err := FetchSubscription(meta.URL, meta.FetchMode, settings.MixedPort)
			if err != nil {
				log.Warnln("[Desktop] Auto-update subscription %s failed: %v", meta.Name, err)
				continue
			}
			merged, mErr := BuildRuntimeYAMLWithOverlay(res.Body, e.store.LoadOverlay(), e.store.LoadTailscalePrefs(), settings)
			if mErr != nil || !validateConfigYAML(merged).OK {
				log.Warnln("[Desktop] Auto-update subscription %s rejected by pre-validation", meta.Name)
				continue
			}
			if _, err := e.store.SaveProfileContent(meta.ID, meta.Name, meta.URL, meta.FetchMode, res.Body, res.Userinfo); err == nil {
				log.Infoln("[Desktop] Auto-update subscription %s succeeded; reloading core", meta.Name)
				go func() { _ = e.Restart() }()
				return
			}
		}
	}
}

func (e *DesktopEngine) stopLocked() {
	if e.syncCancel != nil {
		e.syncCancel()
		e.syncCancel = nil
	}

	_ = e.proxy.Restore()

	ctlAddr := e.activeCtlAddr
	e.activeCtlAddr = ""
	e.running = false
	e.tunActive = false

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

	waitPortReleased(ctlAddr, 800*time.Millisecond)
	e.stopLogSinkLocked()
}

func (e *DesktopEngine) splitDNSSyncLoop(ctx context.Context) {
	ticker := time.NewTicker(6 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			prefs := e.store.LoadTailscalePrefs()
			if !prefs.ManagedByApp || !prefs.Enabled || !prefs.AutoSyncSplitDNS {
				continue
			}
			tsProxy := findActiveTailscaleOutbound()
			if tsProxy == nil {
				continue
			}
			lc, err := tsProxy.LocalClient()
			if err != nil {
				continue
			}
			qCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
			st, sErr := lc.Status(qCtx)
			if sErr != nil || st == nil || st.BackendState != ipn.Running.String() {
				cancel()
				continue
			}
			magicSuffix := ""
			if st.CurrentTailnet != nil {
				magicSuffix = strings.TrimSpace(st.CurrentTailnet.MagicDNSSuffix)
			}
			if magicSuffix == "" {
				magicSuffix = strings.TrimSpace(st.MagicDNSSuffix)
			}
			dnsCfg, dErr := lc.DNSConfig(qCtx)
			cancel()
			if dErr != nil || dnsCfg == nil {
				continue
			}

			splits, _ := extractSplitDnsFromConfig(dnsCfg, magicSuffix)
			discovered := make([]string, 0, len(splits))
			for _, sp := range splits {
				discovered = append(discovered, sp.Domain)
			}
			discovered = normalizeDomainList(discovered)
			sort.Strings(discovered)

			existing := normalizeDomainList(prefs.SplitDNSDomains)
			sort.Strings(existing)

			changed := false
			if magicSuffix != "" && !strings.EqualFold(prefs.TailnetSuffix, magicSuffix) {
				prefs.TailnetSuffix = magicSuffix
				changed = true
			}
			if !sameStringSlice(existing, discovered) && len(discovered) > 0 {
				prefs.SplitDNSDomains = discovered
				changed = true
			}
			if changed {
				log.Infoln("[Desktop] Tailscale SplitDNS changed (suffix=%s, domains=%v) -> saving & reloading core",
					prefs.TailnetSuffix, prefs.SplitDNSDomains)
				if err := e.store.SaveTailscalePrefs(prefs); err == nil {
					go func() {
						_ = e.Restart()
					}()
					return
				}
			}
		}
	}
}

func sameStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
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
			log.Warnln("[Desktop] Tailscale outbound %s (%T) does not implement Start()", proxy.Name(), adapter)
			continue
		}
		name := proxy.Name()
		log.Infoln("[Desktop] Starting Tailscale outbound: %s", name)
		go func() {
			if err := starter.Start(); err != nil {
				log.Errorln("[Tailscale](%s) eager start failed: %v", name, err)
				return
			}
			log.Infoln("[Desktop] Tailscale outbound started: %s", name)
		}()
	}
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
