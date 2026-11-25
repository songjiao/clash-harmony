package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	appVersion              = "v2.4.2-win"
	defaultControllerAddr   = "127.0.0.1:9090"
	defaultUIAddr           = "127.0.0.1:9091"
	defaultMixedPort        = 7890
	defaultProxyBypassRules = "localhost;127.*;<local>"
	defaultTunStack         = "mixed"
)

// AppSettings stores desktop application preferences persisted in settings.json.
type AppSettings struct {
	ActiveProfileID  string `json:"activeProfileId"`
	SystemProxy      bool   `json:"systemProxy"`
	TunMode          bool   `json:"tunMode"`
	TunStack         string `json:"tunStack"`
	StrictRoute      bool   `json:"strictRoute"`
	BlockQuic        bool   `json:"blockQuic"`
	MixedPort        int    `json:"mixedPort"`
	ControllerAddr   string `json:"controllerAddr"`
	UIAddr           string `json:"uiAddr"`
	AutoStartCore    bool   `json:"autoStartCore"`
	StartWithWindows bool   `json:"startWithWindows"`
	ProxyBypass      string `json:"proxyBypass"`
	AutoUpdateHours  int    `json:"autoUpdateHours"`
}

func defaultAppSettings() AppSettings {
	return AppSettings{
		ActiveProfileID:  "",
		SystemProxy:      true,
		TunMode:          false,
		TunStack:         defaultTunStack,
		StrictRoute:      true,
		BlockQuic:        true,
		MixedPort:        defaultMixedPort,
		ControllerAddr:   defaultControllerAddr,
		UIAddr:           defaultUIAddr,
		AutoStartCore:    true,
		StartWithWindows: false,
		ProxyBypass:      defaultProxyBypassRules,
	}
}

// TailscaleNativePrefs mirrors HarmonyOS TailscalePrefsService schema 1:1.
type TailscaleNativePrefs struct {
	ManagedByApp       bool     `json:"managedByApp"`
	Enabled            bool     `json:"enabled"`
	ProxyName          string   `json:"proxyName"`
	Hostname           string   `json:"hostname"`
	ControlURL         string   `json:"controlUrl"`
	AcceptRoutes       bool     `json:"acceptRoutes"`
	ExitNode           string   `json:"exitNode"`
	ExitNodeAllowLAN   bool     `json:"exitNodeAllowLan"`
	AuthKey            string   `json:"authKey"`
	AutoInjectMagicDNS bool     `json:"autoInjectMagicDns"`
	TailnetSuffix      string   `json:"tailnetSuffix"`
	AutoSyncSplitDNS   bool     `json:"autoSyncSplitDns"`
	SplitDNSDomains    []string `json:"splitDnsDomains"`
	SubnetRoutes       []string `json:"subnetRoutes"`
}

func defaultTailscaleHostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "clash-harmony-win"
	}
	clean := strings.ToLower(strings.TrimSpace(h))
	var b strings.Builder
	for _, r := range clean {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			b.WriteRune(r)
		} else if r == '_' || r == ' ' {
			b.WriteRune('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "clash-harmony-win"
	}
	return out + "-clash"
}

func defaultTailscalePrefs() TailscaleNativePrefs {
	return TailscaleNativePrefs{
		ManagedByApp:       true,
		Enabled:            true,
		ProxyName:          "Tailscale",
		Hostname:           defaultTailscaleHostname(),
		ControlURL:         "",
		AcceptRoutes:       true,
		ExitNode:           "",
		ExitNodeAllowLAN:   true,
		AuthKey:            "",
		AutoInjectMagicDNS: true,
		TailnetSuffix:      "",
		AutoSyncSplitDNS:   true,
		SplitDNSDomains:    []string{},
		SubnetRoutes:       []string{},
	}
}

// SubscriptionUserinfo holds parsed Subscription-Userinfo header metrics.
type SubscriptionUserinfo struct {
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
	Total    int64 `json:"total"`
	Expire   int64 `json:"expire"`
}

// ProfileMeta describes a saved Clash/Mihomo YAML profile or subscription.
type ProfileMeta struct {
	ID         string                `json:"id"`
	Name       string                `json:"name"`
	URL        string                `json:"url,omitempty"`
	FetchMode  string                `json:"fetchMode,omitempty"` // auto | direct | proxy
	FileName   string                `json:"fileName"`
	UpdatedAt  string                `json:"updatedAt"`
	SizeBytes  int64                 `json:"sizeBytes"`
	ProxyCount int                   `json:"proxyCount"`
	GroupCount int                   `json:"groupCount"`
	RuleCount  int                   `json:"ruleCount"`
	Userinfo   *SubscriptionUserinfo `json:"userinfo,omitempty"`
}

// DataStore manages persistent desktop settings, profiles, and runtime directory.
type DataStore struct {
	mu      sync.Mutex
	baseDir string
}

func NewDataStore(baseDir string) (*DataStore, error) {
	if strings.TrimSpace(baseDir) == "" {
		cfgDir, err := os.UserConfigDir()
		if err != nil || strings.TrimSpace(cfgDir) == "" {
			cfgDir = "."
		}
		baseDir = filepath.Join(cfgDir, "ClashHarmony")
	}
	absDir, err := filepath.Abs(baseDir)
	if err == nil {
		baseDir = absDir
	}
	for _, sub := range []string{"", "profiles", "runtime"} {
		if err := os.MkdirAll(filepath.Join(baseDir, sub), 0o755); err != nil {
			return nil, fmt.Errorf("create data dir: %w", err)
		}
	}
	return &DataStore{baseDir: baseDir}, nil
}

func (s *DataStore) BaseDir() string          { return s.baseDir }
func (s *DataStore) RuntimeDir() string       { return filepath.Join(s.baseDir, "runtime") }
func (s *DataStore) ProfilesDir() string      { return filepath.Join(s.baseDir, "profiles") }
func (s *DataStore) RuntimeConfigPath() string { return filepath.Join(s.RuntimeDir(), "current.yaml") }
func (s *DataStore) CoreLogPath() string      { return filepath.Join(s.RuntimeDir(), "mihomo-core.log") }
func (s *DataStore) settingsPath() string     { return filepath.Join(s.baseDir, "settings.json") }
func (s *DataStore) profilesIndexPath() string { return filepath.Join(s.ProfilesDir(), "profiles.json") }
func (s *DataStore) tsPrefsPath() string       { return filepath.Join(s.RuntimeDir(), "tailscale-prefs.json") }
func (s *DataStore) overlayPath() string       { return filepath.Join(s.RuntimeDir(), "overlay.json") }

func (s *DataStore) LoadOverlay() CustomOverlay {
	s.mu.Lock()
	defer s.mu.Unlock()
	o := defaultCustomOverlay()
	data, err := os.ReadFile(s.overlayPath())
	if err != nil {
		return o
	}
	_ = json.Unmarshal(data, &o)
	return normalizeOverlay(o)
}

func (s *DataStore) SaveOverlay(o CustomOverlay) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return writeAtomicJSON(s.overlayPath(), normalizeOverlay(o))
}

func writeAtomicJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomicBytes(path, data)
}

func writeAtomicBytes(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func normalizeTunStack(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "mixed", "system", "gvisor":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return defaultTunStack
	}
}

func (s *DataStore) LoadSettings() AppSettings {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg := defaultAppSettings()
	data, err := os.ReadFile(s.settingsPath())
	if err != nil {
		return cfg
	}
	_ = json.Unmarshal(data, &cfg)
	cfg.TunStack = normalizeTunStack(cfg.TunStack)
	if cfg.MixedPort <= 0 || cfg.MixedPort > 65535 {
		cfg.MixedPort = defaultMixedPort
	}
	if strings.TrimSpace(cfg.ControllerAddr) == "" {
		cfg.ControllerAddr = defaultControllerAddr
	}
	if strings.TrimSpace(cfg.UIAddr) == "" {
		cfg.UIAddr = defaultUIAddr
	}
	if strings.TrimSpace(cfg.ProxyBypass) == "" {
		cfg.ProxyBypass = defaultProxyBypassRules
	}
	return cfg
}

func (s *DataStore) SaveSettings(cfg AppSettings) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg.TunStack = normalizeTunStack(cfg.TunStack)
	if cfg.MixedPort <= 0 || cfg.MixedPort > 65535 {
		cfg.MixedPort = defaultMixedPort
	}
	if strings.TrimSpace(cfg.ControllerAddr) == "" {
		cfg.ControllerAddr = defaultControllerAddr
	}
	if strings.TrimSpace(cfg.UIAddr) == "" {
		cfg.UIAddr = defaultUIAddr
	}
	return writeAtomicJSON(s.settingsPath(), cfg)
}

func (s *DataStore) LoadTailscalePrefs() TailscaleNativePrefs {
	s.mu.Lock()
	defer s.mu.Unlock()
	prefs := defaultTailscalePrefs()
	data, err := os.ReadFile(s.tsPrefsPath())
	if err != nil {
		return prefs
	}
	_ = json.Unmarshal(data, &prefs)
	if strings.TrimSpace(prefs.ProxyName) == "" {
		prefs.ProxyName = "Tailscale"
	}
	if strings.TrimSpace(prefs.Hostname) == "" {
		prefs.Hostname = defaultTailscaleHostname()
	}
	prefs.SplitDNSDomains = normalizeDomainList(prefs.SplitDNSDomains)
	prefs.SubnetRoutes = normalizeCIDRList(prefs.SubnetRoutes)
	return prefs
}

func (s *DataStore) SaveTailscalePrefs(prefs TailscaleNativePrefs) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if strings.TrimSpace(prefs.ProxyName) == "" {
		prefs.ProxyName = "Tailscale"
	}
	if strings.TrimSpace(prefs.Hostname) == "" {
		prefs.Hostname = defaultTailscaleHostname()
	}
	prefs.SplitDNSDomains = normalizeDomainList(prefs.SplitDNSDomains)
	prefs.SubnetRoutes = normalizeCIDRList(prefs.SubnetRoutes)
	return writeAtomicJSON(s.tsPrefsPath(), prefs)
}

func (s *DataStore) loadProfilesLocked() []ProfileMeta {
	data, err := os.ReadFile(s.profilesIndexPath())
	if err != nil {
		return []ProfileMeta{}
	}
	var list []ProfileMeta
	if err := json.Unmarshal(data, &list); err != nil {
		return []ProfileMeta{}
	}
	if list == nil {
		return []ProfileMeta{}
	}
	return list
}

func (s *DataStore) saveProfilesLocked(list []ProfileMeta) error {
	return writeAtomicJSON(s.profilesIndexPath(), list)
}

func (s *DataStore) ListProfiles() []ProfileMeta {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.loadProfilesLocked()
	sort.SliceStable(list, func(i, j int) bool {
		return list[i].UpdatedAt > list[j].UpdatedAt
	})
	return list
}

func (s *DataStore) GetProfile(id string) (ProfileMeta, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.loadProfilesLocked() {
		if p.ID == id {
			raw, err := os.ReadFile(filepath.Join(s.ProfilesDir(), p.FileName))
			if err != nil {
				return p, "", err
			}
			return p, string(raw), nil
		}
	}
	return ProfileMeta{}, "", fmt.Errorf("未找到配置 %q", id)
}

func newProfileID() string {
	buf := make([]byte, 6)
	_, _ = rand.Read(buf)
	return "prof_" + hex.EncodeToString(buf)
}

func (s *DataStore) SaveProfileContent(id, name, sourceURL, fetchMode, yamlText string, info *SubscriptionUserinfo) (ProfileMeta, error) {
	trimmed := strings.TrimSpace(yamlText)
	if trimmed == "" {
		return ProfileMeta{}, fmt.Errorf("配置内容不能为空")
	}
	validation := validateConfigYAML(yamlText)
	if !validation.OK {
		return ProfileMeta{}, fmt.Errorf("配置校验失败: %s", validation.Error)
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	list := s.loadProfilesLocked()
	var meta ProfileMeta
	idx := -1
	if id != "" {
		for i := range list {
			if list[i].ID == id {
				idx = i
				meta = list[i]
				break
			}
		}
	}
	if idx < 0 {
		meta.ID = newProfileID()
		meta.FileName = meta.ID + ".yaml"
	}
	if strings.TrimSpace(name) != "" {
		meta.Name = strings.TrimSpace(name)
	} else if meta.Name == "" {
		meta.Name = "未命名配置"
	}
	if sourceURL != "" {
		meta.URL = strings.TrimSpace(sourceURL)
	}
	if fm := normalizeFetchMode(fetchMode); fm != "" {
		meta.FetchMode = fm
	} else if meta.FetchMode == "" && meta.URL != "" {
		meta.FetchMode = "auto"
	}
	if info != nil {
		meta.Userinfo = info
	}
	meta.UpdatedAt = time.Now().Format(time.RFC3339)
	meta.SizeBytes = int64(len(yamlText))
	meta.ProxyCount = validation.ProxyCount
	meta.GroupCount = validation.GroupCount
	meta.RuleCount = validation.RuleCount

	if err := writeAtomicBytes(filepath.Join(s.ProfilesDir(), meta.FileName), []byte(yamlText)); err != nil {
		return ProfileMeta{}, err
	}
	if idx < 0 {
		list = append(list, meta)
	} else {
		list[idx] = meta
	}
	if err := s.saveProfilesLocked(list); err != nil {
		return ProfileMeta{}, err
	}
	return meta, nil
}

func (s *DataStore) DeleteProfile(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.loadProfilesLocked()
	next := make([]ProfileMeta, 0, len(list))
	var removed *ProfileMeta
	for _, p := range list {
		if p.ID == id {
			cp := p
			removed = &cp
			continue
		}
		next = append(next, p)
	}
	if removed == nil {
		return fmt.Errorf("未找到配置 %q", id)
	}
	_ = os.Remove(filepath.Join(s.ProfilesDir(), removed.FileName))
	return s.saveProfilesLocked(next)
}

func normalizeFetchMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "direct", "proxy", "auto":
		return strings.ToLower(strings.TrimSpace(raw))
	default:
		return ""
	}
}

func parseSubscriptionUserinfo(headerVal string) *SubscriptionUserinfo {
	if strings.TrimSpace(headerVal) == "" {
		return nil
	}
	info := &SubscriptionUserinfo{}
	found := false
	for _, part := range strings.Split(headerVal, ";") {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(kv[0]))
		v, err := strconv.ParseInt(strings.TrimSpace(kv[1]), 10, 64)
		if err != nil {
			continue
		}
		switch k {
		case "upload":
			info.Upload = v
			found = true
		case "download":
			info.Download = v
			found = true
		case "total":
			info.Total = v
			found = true
		case "expire":
			info.Expire = v
			found = true
		}
	}
	if !found {
		return nil
	}
	return info
}

type SubscriptionFetchResult struct {
	Body     string
	Userinfo *SubscriptionUserinfo
	UsedMode string
}

// FetchSubscription downloads a Clash YAML subscription using the chosen mode:
//   - "direct": bypasses proxy (ideal for CN-friendly subscriptions like BitzNet)
//   - "proxy": routes through local Mihomo mixed-port (ideal for overseas subscriptions)
//   - "auto": tries direct first, falls back to local proxy if direct fails
func FetchSubscription(subURL, mode string, mixedPort int) (SubscriptionFetchResult, error) {
	u := strings.TrimSpace(subURL)
	if !strings.HasPrefix(u, "http://") && !strings.HasPrefix(u, "https://") {
		return SubscriptionFetchResult{}, fmt.Errorf("订阅链接必须以 http:// 或 https:// 开头")
	}
	m := normalizeFetchMode(mode)
	if m == "" {
		m = "auto"
	}

	doFetch := func(useProxy bool) (SubscriptionFetchResult, error) {
		tr := &http.Transport{
			Proxy: nil,
		}
		if useProxy && mixedPort > 0 {
			pURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", mixedPort))
			tr.Proxy = http.ProxyURL(pURL)
		}
		client := &http.Client{
			Timeout:   25 * time.Second,
			Transport: tr,
		}
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return SubscriptionFetchResult{}, err
		}
		req.Header.Set("User-Agent", "clash-verge/v2.3.0 mihomo/1.19.34")
		resp, err := client.Do(req)
		if err != nil {
			return SubscriptionFetchResult{}, err
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return SubscriptionFetchResult{}, fmt.Errorf("订阅返回异常状态码 HTTP %d", resp.StatusCode)
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 16*1024*1024))
		if err != nil {
			return SubscriptionFetchResult{}, fmt.Errorf("读取订阅内容失败: %w", err)
		}
		text := strings.TrimSpace(string(body))
		if text == "" {
			return SubscriptionFetchResult{}, fmt.Errorf("订阅返回内容为空")
		}
		used := "direct"
		if useProxy {
			used = "proxy"
		}
		return SubscriptionFetchResult{
			Body:     text,
			Userinfo: parseSubscriptionUserinfo(resp.Header.Get("Subscription-Userinfo")),
			UsedMode: used,
		}, nil
	}

	switch m {
	case "direct":
		res, err := doFetch(false)
		if err != nil {
			return res, fmt.Errorf("直连拉取订阅失败: %w", err)
		}
		return res, nil
	case "proxy":
		res, err := doFetch(true)
		if err != nil {
			return res, fmt.Errorf("代理拉取订阅失败: %w", err)
		}
		return res, nil
	default:
		res, err := doFetch(false)
		if err == nil {
			return res, nil
		}
		res2, err2 := doFetch(true)
		if err2 == nil {
			return res2, nil
		}
		return SubscriptionFetchResult{}, fmt.Errorf("自动拉取失败（直连: %v；代理: %v）", err, err2)
	}
}
