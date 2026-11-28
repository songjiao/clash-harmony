package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

//go:embed web/index.html
var webFS embed.FS

type DesktopServer struct {
	store     *DataStore
	engine    *DesktopEngine
	onElevate func(enableTun bool)
	srv       *http.Server
	addr      string
	syncMgr   *SyncSessionManager
}

func NewDesktopServer(store *DataStore, engine *DesktopEngine, onElevate func(enableTun bool)) *DesktopServer {
	return &DesktopServer{
		store:     store,
		engine:    engine,
		onElevate: onElevate,
		syncMgr:   NewSyncSessionManager(),
	}
}

func (s *DesktopServer) Start(addr string) (string, error) {
	if strings.TrimSpace(addr) == "" {
		addr = defaultUIAddr
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return "", fmt.Errorf("listen UI server %s: %w", addr, err)
	}
	s.addr = ln.Addr().String()
	s.srv = &http.Server{
		Handler:           s.buildMux(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		_ = s.srv.Serve(ln)
	}()
	return s.addr, nil
}

func (s *DesktopServer) Stop() {
	if s.syncMgr != nil {
		s.syncMgr.Close()
	}
	if s.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
		_ = s.srv.Shutdown(ctx)
		cancel()
	}
}

func (s *DesktopServer) buildMux() http.Handler {
	mux := http.NewServeMux()

	// Embedded Web Dashboard
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" && r.URL.Path != "/index.html" {
			http.NotFound(w, r)
			return
		}
		data, err := webFS.ReadFile("web/index.html")
		if err != nil {
			http.Error(w, "UI asset missing", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(data)
	})

	// Shared Tailscale & YAML validation endpoints (100% compatible with HarmonyOS bridge)
	registerTailscaleRoutes(mux)

	// Desktop state
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, s.engine.State())
	})

	// Mobile / roaming network-change trigger & stats
	mux.HandleFunc("/api/network/rebind", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stats": mobileNetCoordinator.Stats()})
			return
		}
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			IfaceName         string `json:"ifaceName"`
			Gateway           string `json:"gateway"`
			Reason            string `json:"reason"`
			RebindTailscale   *bool  `json:"rebindTailscale"`
			PruneNonTailscale *bool  `json:"pruneNonTailscale"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req)
		rebindTS := true
		if req.RebindTailscale != nil {
			rebindTS = *req.RebindTailscale
		}
		pruneNonTS := false
		if req.PruneNonTailscale != nil {
			pruneNonTS = *req.PruneNonTailscale
		}
		reason := strings.TrimSpace(req.Reason)
		if reason == "" {
			reason = "api-rebind"
		}
		s.engine.NotifyNetworkChange(req.IfaceName, req.Gateway, reason, rebindTS, pruneNonTS)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stats": mobileNetCoordinator.Stats()})
	})

	// Core lifecycle
	mux.HandleFunc("/api/core/start", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		if err := s.engine.Start(); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error(), "state": s.engine.State()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "state": s.engine.State()})
	})

	mux.HandleFunc("/api/core/stop", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		_ = s.engine.Stop()
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "state": s.engine.State()})
	})

	mux.HandleFunc("/api/core/restart", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		if err := s.engine.Restart(); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error(), "state": s.engine.State()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "state": s.engine.State()})
	})

	// Desktop settings update
	mux.HandleFunc("/api/settings", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			writeJSON(w, http.StatusOK, s.store.LoadSettings())
			return
		}
		if r.Method != http.MethodPost && r.Method != http.MethodPatch {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			SystemProxy      *bool   `json:"systemProxy"`
			TunMode          *bool   `json:"tunMode"`
			TunStack         *string `json:"tunStack"`
			StrictRoute      *bool   `json:"strictRoute"`
			BlockQuic        *bool   `json:"blockQuic"`
			MixedPort        *int    `json:"mixedPort"`
			AutoStartCore    *bool   `json:"autoStartCore"`
			StartWithWindows *bool   `json:"startWithWindows"`
			ProxyBypass      *string `json:"proxyBypass"`
			AutoUpdateHours  *int    `json:"autoUpdateHours"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 32*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}

		cfg := s.store.LoadSettings()
		needRestart := false
		needProxyUpdate := false

		if req.TunMode != nil && *req.TunMode != cfg.TunMode {
			if *req.TunMode && !IsElevated() {
				writeJSON(w, http.StatusForbidden, map[string]any{
					"ok":            false,
					"needElevation": true,
					"error":         "开启 TUN 全局接管需要管理员权限，请点击「以管理员重启」",
				})
				return
			}
			cfg.TunMode = *req.TunMode
			needRestart = true
		}
		if req.TunStack != nil {
			ns := normalizeTunStack(*req.TunStack)
			if ns != cfg.TunStack {
				cfg.TunStack = ns
				needRestart = true
			}
		}
		if req.StrictRoute != nil && *req.StrictRoute != cfg.StrictRoute {
			cfg.StrictRoute = *req.StrictRoute
			needRestart = true
		}
		if req.BlockQuic != nil && *req.BlockQuic != cfg.BlockQuic {
			cfg.BlockQuic = *req.BlockQuic
			needRestart = true
		}
		if req.MixedPort != nil && *req.MixedPort > 0 && *req.MixedPort <= 65535 && *req.MixedPort != cfg.MixedPort {
			cfg.MixedPort = *req.MixedPort
			needRestart = true
			needProxyUpdate = true
		}
		if req.ProxyBypass != nil && strings.TrimSpace(*req.ProxyBypass) != cfg.ProxyBypass {
			cfg.ProxyBypass = strings.TrimSpace(*req.ProxyBypass)
			needProxyUpdate = true
		}
		if req.SystemProxy != nil && *req.SystemProxy != cfg.SystemProxy {
			cfg.SystemProxy = *req.SystemProxy
			needProxyUpdate = true
		}
		if req.AutoStartCore != nil {
			cfg.AutoStartCore = *req.AutoStartCore
		}
		if req.AutoUpdateHours != nil && *req.AutoUpdateHours >= 0 && *req.AutoUpdateHours <= 168 {
			cfg.AutoUpdateHours = *req.AutoUpdateHours
		}
		if req.StartWithWindows != nil {
			if err := SetAutoStart(*req.StartWithWindows); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			cfg.StartWithWindows = *req.StartWithWindows
		}

		if err := s.store.SaveSettings(cfg); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}

		if s.engine.State().Running {
			if needRestart {
				if err := s.engine.Restart(); err != nil {
					writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error(), "state": s.engine.State()})
					return
				}
			} else if needProxyUpdate {
				if err := s.engine.UpdateSystemProxyState(); err != nil {
					writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error(), "state": s.engine.State()})
					return
				}
			}
		} else {
			s.engine.notifyChange()
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "state": s.engine.State()})
	})

	// Relaunch elevated (for Wintun TUN mode)
	mux.HandleFunc("/api/elevate", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			EnableTun bool `json:"enableTun"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req)
		if IsElevated() {
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "当前已是管理员权限"})
			return
		}
		if s.onElevate == nil {
			writeJSON(w, http.StatusNotImplemented, map[string]any{"ok": false, "error": "当前平台不支持提权重启"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "message": "正在请求 UAC 管理员提权重启..."})
		go func() {
			time.Sleep(200 * time.Millisecond)
			s.onElevate(req.EnableTun)
		}()
	})

	// Custom Overlay (self-hosted nodes + Fail-Closed AI strict group + custom rules)
	mux.HandleFunc("/api/overlay", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			ov := s.store.LoadOverlay()
			parsed, _ := ParseCustomProxiesYAML(ov.CustomProxiesYAML)
			names := make([]string, 0, len(parsed))
			for _, p := range parsed {
				names = append(names, p.Name)
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":               true,
				"overlay":          ov,
				"presets":          allAIProviderPresets(),
				"customProxyNames": names,
			})
			return
		}
		if r.Method != http.MethodPost && r.Method != http.MethodPut {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			Overlay CustomOverlay `json:"overlay"`
			Restart bool          `json:"restart"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 2*1024*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		parsed, err := ParseCustomProxiesYAML(req.Overlay.CustomProxiesYAML)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		names := make([]string, 0, len(parsed))
		for _, p := range parsed {
			names = append(names, p.Name)
		}
		// Pre-validate final merged runtime YAML against active profile before saving!
		settings := s.store.LoadSettings()
		if settings.ActiveProfileID != "" {
			if _, rawYAML, gErr := s.store.GetProfile(settings.ActiveProfileID); gErr == nil {
				merged, mErr := BuildRuntimeYAMLWithOverlay(rawYAML, req.Overlay, s.store.LoadTailscalePrefs(), settings)
				if mErr != nil {
					writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": mErr.Error()})
					return
				}
				vRes := validateConfigYAML(merged)
				if !vRes.OK {
					writeJSON(w, http.StatusBadRequest, map[string]any{
						"ok":    false,
						"error": fmt.Sprintf("融合后运行配置校验失败 (第 %d 行): %s", vRes.Line, vRes.Error),
					})
					return
				}
			}
		}
		if err := s.store.SaveOverlay(req.Overlay); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if req.Restart && s.engine.State().Running {
			if err := s.engine.Restart(); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error(), "overlay": s.store.LoadOverlay(), "customProxyNames": names})
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":               true,
			"overlay":          s.store.LoadOverlay(),
			"presets":          allAIProviderPresets(),
			"customProxyNames": names,
		})
	})

	// Ephemeral LAN QR Sync (PC -> HarmonyOS Phone)
	mux.HandleFunc("/api/sync/create", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			PreferredIP string `json:"preferredIp"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req)
		info, err := s.syncMgr.Create(s.store, req.PreferredIP)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, info)
			return
		}
		writeJSON(w, http.StatusOK, info)
	})

	mux.HandleFunc("/api/sync/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, s.syncMgr.Status())
	})

	mux.HandleFunc("/api/sync/close", func(w http.ResponseWriter, r *http.Request) {
		s.syncMgr.Close()
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	// Portable Backup Export / Import (Windows <-> HarmonyOS sync)
	mux.HandleFunc("/api/backup/export", func(w http.ResponseWriter, r *http.Request) {
		sanitize := r.URL.Query().Get("sanitize") == "1" || strings.EqualFold(r.URL.Query().Get("sanitize"), "true")
		bundle := BuildBackupBundle(s.store, sanitize)
		fname := "clash-harmony-backup.json"
		if sanitize {
			fname = "clash-harmony-backup-sanitized.json"
		}
		w.Header().Set("Content-Disposition", `attachment; filename="`+fname+`"`)
		writeJSON(w, http.StatusOK, bundle)
	})

	mux.HandleFunc("/api/backup/import", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		rawBytes, rErr := io.ReadAll(io.LimitReader(r.Body, 16*1024*1024))
		if rErr != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": rErr.Error()})
			return
		}
		var bundle ConfigBackupBundle
		if err := json.Unmarshal(rawBytes, &bundle); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "解析备份包 JSON 失败: " + err.Error()})
			return
		}
		// Accept either formatVersion or schemaVersion for seamless HarmonyOS interop
		if bundle.FormatVersion <= 0 {
			var compat struct {
				SchemaVersion int `json:"schemaVersion"`
			}
			_ = json.Unmarshal(rawBytes, &compat)
			bundle.FormatVersion = compat.SchemaVersion
		}
		if bundle.FormatVersion <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "无效的备份包格式（缺少 formatVersion）"})
			return
		}
		if _, err := ParseCustomProxiesYAML(bundle.Overlay.CustomProxiesYAML); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if err := s.store.SaveOverlay(bundle.Overlay); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if bundle.TailscalePrefs.ProxyName != "" || bundle.TailscalePrefs.Hostname != "" {
			curTS := s.store.LoadTailscalePrefs()
			// Preserve local device hostname if importing from another platform (e.g. phone -> Windows)
			if bundle.SourcePlatform != "windows-desktop" && curTS.Hostname != "" {
				bundle.TailscalePrefs.Hostname = curTS.Hostname
			}
			_ = s.store.SaveTailscalePrefs(bundle.TailscalePrefs)
		}
		importedProfiles := 0
		settings := s.store.LoadSettings()
		for _, p := range bundle.Profiles {
			if strings.TrimSpace(p.Content) != "" {
				if _, err := s.store.SaveProfileContent("", p.Name, p.URL, p.FetchMode, p.UserAgent, p.Content, nil); err == nil {
					importedProfiles++
				}
			} else if strings.TrimSpace(p.URL) != "" && !strings.Contains(p.URL, "<REDACTED>") {
				if res, err := FetchSubscription(p.URL, p.FetchMode, p.UserAgent, settings.MixedPort); err == nil {
					if _, sErr := s.store.SaveProfileContent("", p.Name, p.URL, p.FetchMode, p.UserAgent, res.Body, res.Userinfo); sErr == nil {
						importedProfiles++
					}
				}
			}
		}
		if s.engine.State().Running {
			_ = s.engine.Restart()
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":               true,
			"importedProfiles": importedProfiles,
			"overlay":          s.store.LoadOverlay(),
		})
	})

	// Receive PC -> Phone LAN QR sync URL (clashharmony://sync?url=...) or raw JSON bundle
	mux.HandleFunc("/api/sync/import-url", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			QRText string `json:"qrText"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 4*1024*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		rawVal := strings.TrimSpace(req.QRText)
		if rawVal == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "未提供同步二维码或链接"})
			return
		}
		var rawJSON []byte
		if strings.HasPrefix(rawVal, "{") {
			rawJSON = []byte(rawVal)
		} else {
			syncURL := rawVal
			if strings.HasPrefix(strings.ToLower(rawVal), "clashharmony://sync") {
				if parsed, pErr := url.Parse(rawVal); pErr == nil {
					if uParam := strings.TrimSpace(parsed.Query().Get("url")); uParam != "" {
						syncURL = uParam
					}
				}
			}
			if !strings.HasPrefix(strings.ToLower(syncURL), "http://") && !strings.HasPrefix(strings.ToLower(syncURL), "https://") {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "不是有效的 Clash Harmony 同步二维码（请在电脑端点击「扫码同步到手机」生成）"})
				return
			}
			client := &http.Client{
				Timeout:   12 * time.Second,
				Transport: &http.Transport{Proxy: nil},
			}
			resp, err := client.Get(syncURL)
			if err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "连接电脑同步地址失败（请确认手机和电脑在同一 Wi-Fi）: " + err.Error()})
				return
			}
			defer resp.Body.Close()
			body, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024))
			if err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "读取同步内容失败: " + err.Error()})
				return
			}
			if resp.StatusCode < 200 || resp.StatusCode >= 300 {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": fmt.Sprintf("电脑同步服务返回 HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))})
				return
			}
			rawJSON = body
		}

		var payload struct {
			FormatVersion    int                   `json:"formatVersion"`
			Overlay          CustomOverlay         `json:"overlay"`
			TailscaleRouting *TailscaleRoutingSync `json:"tailscaleRouting"`
			TailscalePrefs   *TailscaleNativePrefs `json:"tailscalePrefs"`
			Profiles         []BackupProfileRecord `json:"profiles"`
		}
		if err := json.Unmarshal(rawJSON, &payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "解析同步包 JSON 失败: " + err.Error()})
			return
		}
		if _, err := ParseCustomProxiesYAML(payload.Overlay.CustomProxiesYAML); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if err := s.store.SaveOverlay(payload.Overlay); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}

		// Sync Tailscale routing policy ONLY — strictly preserve this device's own hostname/authKey/exitNode!
		curTS := s.store.LoadTailscalePrefs()
		if payload.TailscaleRouting != nil {
			rt := payload.TailscaleRouting
			curTS.ManagedByApp = rt.ManagedByApp
			curTS.Enabled = rt.Enabled
			if strings.TrimSpace(rt.ProxyName) != "" {
				curTS.ProxyName = rt.ProxyName
			}
			curTS.ControlURL = rt.ControlURL
			curTS.AcceptRoutes = rt.AcceptRoutes
			curTS.AutoInjectMagicDNS = rt.AutoInjectMagicDNS
			if strings.TrimSpace(rt.TailnetSuffix) != "" {
				curTS.TailnetSuffix = rt.TailnetSuffix
			}
			curTS.AutoSyncSplitDNS = rt.AutoSyncSplitDNS
			if len(rt.SplitDNSDomains) > 0 {
				curTS.SplitDNSDomains = append([]string(nil), rt.SplitDNSDomains...)
			}
			if len(rt.SubnetRoutes) > 0 {
				curTS.SubnetRoutes = append([]string(nil), rt.SubnetRoutes...)
			}
			_ = s.store.SaveTailscalePrefs(curTS)
		} else if payload.TailscalePrefs != nil {
			tp := payload.TailscalePrefs
			curTS.ManagedByApp = tp.ManagedByApp
			curTS.Enabled = tp.Enabled
			if strings.TrimSpace(tp.ProxyName) != "" {
				curTS.ProxyName = tp.ProxyName
			}
			curTS.ControlURL = tp.ControlURL
			curTS.AcceptRoutes = tp.AcceptRoutes
			curTS.AutoInjectMagicDNS = tp.AutoInjectMagicDNS
			if strings.TrimSpace(tp.TailnetSuffix) != "" {
				curTS.TailnetSuffix = tp.TailnetSuffix
			}
			curTS.AutoSyncSplitDNS = tp.AutoSyncSplitDNS
			if len(tp.SplitDNSDomains) > 0 {
				curTS.SplitDNSDomains = append([]string(nil), tp.SplitDNSDomains...)
			}
			_ = s.store.SaveTailscalePrefs(curTS)
		}

		importedProfiles := 0
		lastID := ""
		settings := s.store.LoadSettings()
		for _, p := range payload.Profiles {
			if strings.TrimSpace(p.Content) != "" {
				if meta, err := s.store.SaveProfileContent("", p.Name, p.URL, p.FetchMode, p.UserAgent, p.Content, nil); err == nil {
					importedProfiles++
					lastID = meta.ID
				}
			} else if strings.TrimSpace(p.URL) != "" && !strings.Contains(p.URL, "<REDACTED>") {
				if res, err := FetchSubscription(p.URL, p.FetchMode, p.UserAgent, settings.MixedPort); err == nil {
					if meta, sErr := s.store.SaveProfileContent("", p.Name, p.URL, p.FetchMode, p.UserAgent, res.Body, res.Userinfo); sErr == nil {
						importedProfiles++
						lastID = meta.ID
					}
				}
			}
		}
		if lastID != "" {
			settings.ActiveProfileID = lastID
			_ = s.store.SaveSettings(settings)
		}
		if s.engine.State().Running {
			_ = s.engine.Restart()
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":               true,
			"importedProfiles": importedProfiles,
			"message":          fmt.Sprintf("已同步电脑配置（订阅 %d 份 + 自建节点与 AI 规则 + Tailscale 分流策略），点击顶部「开启 VPN」后登录 Tailscale 即可使用！", importedProfiles),
		})
	})

	// Tailscale native prefs (persisted in tailscale-prefs.json)
	mux.HandleFunc("/api/tailscale/prefs", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			writeJSON(w, http.StatusOK, s.store.LoadTailscalePrefs())
			return
		}
		if r.Method != http.MethodPost && r.Method != http.MethodPut {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			Prefs   TailscaleNativePrefs `json:"prefs"`
			Restart bool                 `json:"restart"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if err := s.store.SaveTailscalePrefs(req.Prefs); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if req.Restart && s.engine.State().Running {
			if err := s.engine.Restart(); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error(), "prefs": s.store.LoadTailscalePrefs()})
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "prefs": s.store.LoadTailscalePrefs()})
	})

	// Profiles CRUD & Subscription import
	mux.HandleFunc("/api/profiles", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			id := strings.TrimSpace(r.URL.Query().Get("id"))
			if id != "" {
				meta, content, err := s.store.GetProfile(id)
				if err != nil {
					writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": err.Error()})
					return
				}
				writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": meta, "content": content})
				return
			}
			settings := s.store.LoadSettings()
			writeJSON(w, http.StatusOK, map[string]any{
				"activeId": settings.ActiveProfileID,
				"profiles": s.store.ListProfiles(),
			})
		case http.MethodDelete:
			id := strings.TrimSpace(r.URL.Query().Get("id"))
			if id == "" {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "缺少 id"})
				return
			}
			if err := s.store.DeleteProfile(id); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			settings := s.store.LoadSettings()
			if settings.ActiveProfileID == id {
				settings.ActiveProfileID = ""
				remaining := s.store.ListProfiles()
				if len(remaining) > 0 {
					settings.ActiveProfileID = remaining[0].ID
				}
				_ = s.store.SaveSettings(settings)
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		default:
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
		}
	})

	mux.HandleFunc("/api/profiles/import", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			URL       string `json:"url"`
			FetchMode string `json:"fetchMode"`
			UserAgent string `json:"userAgent"`
			Content   string `json:"content"`
			Activate  bool   `json:"activate"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 16*1024*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		settings := s.store.LoadSettings()
		yamlText := req.Content
		var userinfo *SubscriptionUserinfo
		usedMode := ""
		if strings.TrimSpace(yamlText) == "" && strings.TrimSpace(req.URL) != "" {
			res, err := FetchSubscription(req.URL, req.FetchMode, req.UserAgent, settings.MixedPort)
			if err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			yamlText = res.Body
			userinfo = res.Userinfo
			usedMode = res.UsedMode
		}
		if strings.TrimSpace(req.Name) == "" {
			if strings.TrimSpace(req.URL) != "" {
				if parsed, err := url.Parse(strings.TrimSpace(req.URL)); err == nil && parsed.Host != "" {
					req.Name = parsed.Host
				}
			}
			if strings.TrimSpace(req.Name) == "" {
				req.Name = "本地配置 " + time.Now().Format("01-02 15:04")
			}
		}

		// Pre-validate final merged runtime YAML (including Overlay + Tailscale) BEFORE saving!
		mergedPreview, mErr := BuildRuntimeYAMLWithOverlay(yamlText, s.store.LoadOverlay(), s.store.LoadTailscalePrefs(), settings)
		if mErr != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "融合运行配置失败: " + mErr.Error()})
			return
		}
		if mergedVal := validateConfigYAML(mergedPreview); !mergedVal.OK {
			writeJSON(w, http.StatusBadRequest, map[string]any{
				"ok":    false,
				"line":  mergedVal.Line,
				"error": fmt.Sprintf("融合运行态预校验失败 (第 %d 行): %s%s", mergedVal.Line, mergedVal.Error, formatLineSnippetSuffix(mergedPreview, mergedVal.Line)),
			})
			return
		}

		meta, err := s.store.SaveProfileContent(req.ID, req.Name, req.URL, req.FetchMode, req.UserAgent, yamlText, userinfo)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if req.Activate || settings.ActiveProfileID == "" {
			settings.ActiveProfileID = meta.ID
			_ = s.store.SaveSettings(settings)
			if s.engine.State().Running {
				if rErr := s.engine.Restart(); rErr != nil {
					writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": meta, "usedMode": usedMode, "restartError": rErr.Error()})
					return
				}
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": meta, "usedMode": usedMode})
	})

	mux.HandleFunc("/api/profiles/activate", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			ID string `json:"id"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if _, _, err := s.store.GetProfile(req.ID); err != nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		settings := s.store.LoadSettings()
		settings.ActiveProfileID = req.ID
		_ = s.store.SaveSettings(settings)
		if s.engine.State().Running {
			if err := s.engine.Restart(); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error(), "state": s.engine.State()})
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "state": s.engine.State()})
	})

	mux.HandleFunc("/api/profiles/refresh", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			ID        string `json:"id"`
			FetchMode string `json:"fetchMode"`
			UserAgent string `json:"userAgent"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		meta, _, err := s.store.GetProfile(req.ID)
		if err != nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if strings.TrimSpace(meta.URL) == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "该配置为本地导入，没有订阅 URL"})
			return
		}
		settings := s.store.LoadSettings()
		mode := req.FetchMode
		if strings.TrimSpace(mode) == "" {
			mode = meta.FetchMode
		}
		ua := sanitizeUserAgentInput(req.UserAgent)
		if ua == "" {
			ua = meta.UserAgent
		}
		res, err := FetchSubscription(meta.URL, mode, ua, settings.MixedPort)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		mergedPreview, mErr := BuildRuntimeYAMLWithOverlay(res.Body, s.store.LoadOverlay(), s.store.LoadTailscalePrefs(), settings)
		if mErr != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "融合运行配置失败: " + mErr.Error()})
			return
		}
		if mergedVal := validateConfigYAML(mergedPreview); !mergedVal.OK {
			writeJSON(w, http.StatusBadRequest, map[string]any{
				"ok":    false,
				"line":  mergedVal.Line,
				"error": fmt.Sprintf("订阅更新融合后预校验失败 (第 %d 行): %s%s", mergedVal.Line, mergedVal.Error, formatLineSnippetSuffix(mergedPreview, mergedVal.Line)),
			})
			return
		}
		updated, err := s.store.SaveProfileContent(meta.ID, meta.Name, meta.URL, mode, ua, res.Body, res.Userinfo)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if settings.ActiveProfileID == updated.ID && s.engine.State().Running {
			_ = s.engine.Restart()
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": updated, "usedMode": res.UsedMode})
	})

	mux.HandleFunc("/api/profiles/meta", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			URL       string `json:"url"`
			FetchMode string `json:"fetchMode"`
			UserAgent string `json:"userAgent"`
			Refresh   bool   `json:"refresh"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 16*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		updated, err := s.store.UpdateProfileSource(req.ID, req.Name, req.URL, req.FetchMode, req.UserAgent)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if !req.Refresh || strings.TrimSpace(updated.URL) == "" {
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": updated, "refreshed": false})
			return
		}
		settings := s.store.LoadSettings()
		res, err := FetchSubscription(updated.URL, updated.FetchMode, updated.UserAgent, settings.MixedPort)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "profile": updated, "error": "设置已保存，但拉取订阅失败: " + err.Error()})
			return
		}
		mergedPreview, mErr := BuildRuntimeYAMLWithOverlay(res.Body, s.store.LoadOverlay(), s.store.LoadTailscalePrefs(), settings)
		if mErr != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "profile": updated, "error": "设置已保存，但融合运行配置失败: " + mErr.Error()})
			return
		}
		if mergedVal := validateConfigYAML(mergedPreview); !mergedVal.OK {
			writeJSON(w, http.StatusBadRequest, map[string]any{
				"ok":      false,
				"profile": updated,
				"line":    mergedVal.Line,
				"error":   fmt.Sprintf("设置已保存，但订阅融合预校验失败 (第 %d 行): %s%s", mergedVal.Line, mergedVal.Error, formatLineSnippetSuffix(mergedPreview, mergedVal.Line)),
			})
			return
		}
		saved, err := s.store.SaveProfileContent(updated.ID, updated.Name, updated.URL, updated.FetchMode, updated.UserAgent, res.Body, res.Userinfo)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "profile": updated, "error": err.Error()})
			return
		}
		if settings.ActiveProfileID == saved.ID && s.engine.State().Running {
			_ = s.engine.Restart()
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": saved, "refreshed": true, "usedMode": res.UsedMode})
	})

	// Logs & active runtime YAML inspection
	mux.HandleFunc("/api/logs", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"lines": s.engine.RecentLogs(300),
		})
	})

	mux.HandleFunc("/api/runtime-yaml", func(w http.ResponseWriter, r *http.Request) {
		data, err := os.ReadFile(s.store.RuntimeConfigPath())
		if err != nil {
			writeJSON(w, http.StatusOK, map[string]any{"ok": false, "content": "", "error": "尚未生成运行配置"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "content": string(data)})
	})

	// Reverse proxy /clash/* -> Mihomo REST Controller (127.0.0.1:9090/*)
	mux.HandleFunc("/clash/", func(w http.ResponseWriter, r *http.Request) {
		ctlAddr := s.store.LoadSettings().ControllerAddr
		if !strings.HasPrefix(ctlAddr, "http://") && !strings.HasPrefix(ctlAddr, "https://") {
			ctlAddr = "http://" + ctlAddr
		}
		target, err := url.Parse(ctlAddr)
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
			return
		}
		proxy := httputil.NewSingleHostReverseProxy(target)
		proxy.Director = func(req *http.Request) {
			req.URL.Scheme = target.Scheme
			req.URL.Host = target.Host
			req.URL.Path = strings.TrimPrefix(req.URL.Path, "/clash")
			if req.URL.Path == "" {
				req.URL.Path = "/"
			}
			req.Host = target.Host
		}
		proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, pErr error) {
			writeJSON(rw, http.StatusBadGateway, map[string]any{"error": "Mihomo 控制器未响应（请确认核心已启动）: " + pErr.Error()})
		}
		proxy.ServeHTTP(w, r)
	})

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		mux.ServeHTTP(w, r)
	})
}
