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
}

func NewDesktopServer(store *DataStore, engine *DesktopEngine, onElevate func(enableTun bool)) *DesktopServer {
	return &DesktopServer{
		store:     store,
		engine:    engine,
		onElevate: onElevate,
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
				if _, err := s.store.SaveProfileContent("", p.Name, p.URL, p.FetchMode, p.Content, nil); err == nil {
					importedProfiles++
				}
			} else if strings.TrimSpace(p.URL) != "" && !strings.Contains(p.URL, "<REDACTED>") {
				if res, err := FetchSubscription(p.URL, p.FetchMode, settings.MixedPort); err == nil {
					if _, sErr := s.store.SaveProfileContent("", p.Name, p.URL, p.FetchMode, res.Body, res.Userinfo); sErr == nil {
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
			res, err := FetchSubscription(req.URL, req.FetchMode, settings.MixedPort)
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
				"error": fmt.Sprintf("融合运行态预校验失败 (第 %d 行): %s", mergedVal.Line, mergedVal.Error),
			})
			return
		}

		meta, err := s.store.SaveProfileContent(req.ID, req.Name, req.URL, req.FetchMode, yamlText, userinfo)
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
		res, err := FetchSubscription(meta.URL, mode, settings.MixedPort)
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
				"error": fmt.Sprintf("订阅更新融合后预校验失败 (第 %d 行): %s", mergedVal.Line, mergedVal.Error),
			})
			return
		}
		updated, err := s.store.SaveProfileContent(meta.ID, meta.Name, meta.URL, mode, res.Body, res.Userinfo)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if settings.ActiveProfileID == updated.ID && s.engine.State().Running {
			_ = s.engine.Restart()
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "profile": updated, "usedMode": res.UsedMode})
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
