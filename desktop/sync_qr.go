package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// TailscaleRoutingSync holds ONLY the shareable Tailscale routing policy
// (which traffic/domains route via Tailscale). Device identity (hostname),
// credentials (authKey / tailscaled.state), and exitNode stay strictly device-local.
type TailscaleRoutingSync struct {
	ManagedByApp       bool     `json:"managedByApp"`
	Enabled            bool     `json:"enabled"`
	ProxyName          string   `json:"proxyName"`
	ControlURL         string   `json:"controlUrl"`
	AcceptRoutes       bool     `json:"acceptRoutes"`
	AutoInjectMagicDNS bool     `json:"autoInjectMagicDns"`
	TailnetSuffix      string   `json:"tailnetSuffix"`
	AutoSyncSplitDNS   bool     `json:"autoSyncSplitDns"`
	SplitDNSDomains    []string `json:"splitDnsDomains"`
	SubnetRoutes       []string `json:"subnetRoutes"`
}

// MobileSyncBundle is the clean cross-device sync payload sent PC -> Phone over LAN QR.
type MobileSyncBundle struct {
	FormatVersion    int                   `json:"formatVersion"`
	ExportedAt       string                `json:"exportedAt"`
	SourcePlatform   string                `json:"sourcePlatform"`
	Sanitized        bool                  `json:"sanitized"`
	Overlay          CustomOverlay         `json:"overlay"`
	TailscaleRouting TailscaleRoutingSync  `json:"tailscaleRouting"`
	Profiles         []BackupProfileRecord `json:"profiles"`
}

// BuildMobileSyncBundle constructs a portable PC->Phone bundle that transfers:
//   - Self-hosted nodes + AI strict provider presets + Fail-Closed + custom rules
//   - Tailscale routing policy ONLY (SplitDNS domains, acceptRoutes, MagicDNS — NO PC hostname/authKey/exitNode)
//   - Active subscription / local YAML profile (so phone works immediately without re-typing URLs)
func BuildMobileSyncBundle(store *DataStore) MobileSyncBundle {
	overlay := store.LoadOverlay()
	tsPrefs := store.LoadTailscalePrefs()
	settings := store.LoadSettings()

	routing := TailscaleRoutingSync{
		ManagedByApp:       tsPrefs.ManagedByApp,
		Enabled:            tsPrefs.Enabled,
		ProxyName:          tsPrefs.ProxyName,
		ControlURL:         tsPrefs.ControlURL,
		AcceptRoutes:       tsPrefs.AcceptRoutes,
		AutoInjectMagicDNS: tsPrefs.AutoInjectMagicDNS,
		TailnetSuffix:      tsPrefs.TailnetSuffix,
		AutoSyncSplitDNS:   tsPrefs.AutoSyncSplitDNS,
		SplitDNSDomains:    append([]string(nil), tsPrefs.SplitDNSDomains...),
		SubnetRoutes:       append([]string(nil), tsPrefs.SubnetRoutes...),
	}
	if routing.ProxyName == "" {
		routing.ProxyName = "Tailscale"
	}

	profiles := []BackupProfileRecord{}
	// Prefer syncing the currently active profile (cleanest for mobile's "max 2 cards" flow).
	if settings.ActiveProfileID != "" {
		if meta, content, err := store.GetProfile(settings.ActiveProfileID); err == nil {
			profiles = append(profiles, BackupProfileRecord{
				Name:      meta.Name,
				URL:       meta.URL,
				FetchMode: meta.FetchMode,
				Content:   content,
			})
		}
	}
	if len(profiles) == 0 {
		for _, meta := range store.ListProfiles() {
			_, content, err := store.GetProfile(meta.ID)
			if err != nil {
				continue
			}
			profiles = append(profiles, BackupProfileRecord{
				Name:      meta.Name,
				URL:       meta.URL,
				FetchMode: meta.FetchMode,
				Content:   content,
			})
			break
		}
	}

	return MobileSyncBundle{
		FormatVersion:    1,
		ExportedAt:       time.Now().Format(time.RFC3339),
		SourcePlatform:   "windows-desktop",
		Sanitized:        false,
		Overlay:          overlay,
		TailscaleRouting: routing,
		Profiles:         profiles,
	}
}

type SyncSessionInfo struct {
	OK          bool     `json:"ok"`
	Active      bool     `json:"active"`
	SyncURL     string   `json:"syncUrl"`
	QRText      string   `json:"qrText"`
	QRDataURL   string   `json:"qrDataUrl"`
	SelectedIP  string   `json:"selectedIp"`
	LanIPs      []string `json:"lanIps"`
	Port        int      `json:"port"`
	ExpiresAt   string   `json:"expiresAt"`
	SyncedCount int      `json:"syncedCount"`
	Summary     string   `json:"summary"`
	Error       string   `json:"error,omitempty"`
}

type SyncSessionManager struct {
	mu          sync.Mutex
	srv         *http.Server
	ln          net.Listener
	token       string
	payload     []byte
	port        int
	selectedIP  string
	lanIPs      []string
	expiresAt   time.Time
	syncedCount int
	summary     string
	timer       *time.Timer
}

func NewSyncSessionManager() *SyncSessionManager {
	return &SyncSessionManager{}
}

func (m *SyncSessionManager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closeLocked()
}

func (m *SyncSessionManager) closeLocked() {
	if m.timer != nil {
		m.timer.Stop()
		m.timer = nil
	}
	if m.srv != nil {
		_ = m.srv.Close()
		m.srv = nil
	}
	if m.ln != nil {
		_ = m.ln.Close()
		m.ln = nil
	}
	m.token = ""
	m.payload = nil
	m.port = 0
}

func (m *SyncSessionManager) Create(store *DataStore, preferredIP string) (SyncSessionInfo, error) {
	lanIPs := detectBestLANIPv4s()
	if len(lanIPs) == 0 {
		return SyncSessionInfo{OK: false, Error: "未检测到可用的局域网 IPv4 地址，请确认电脑已连接 Wi-Fi 或局域网"}, fmt.Errorf("no LAN IPv4 found")
	}

	chosenIP := lanIPs[0]
	if pref := strings.TrimSpace(preferredIP); pref != "" {
		for _, ip := range lanIPs {
			if ip == pref {
				chosenIP = ip
				break
			}
		}
	}

	bundle := BuildMobileSyncBundle(store)
	payload, err := json.Marshal(bundle)
	if err != nil {
		return SyncSessionInfo{OK: false, Error: err.Error()}, err
	}

	tokBytes := make([]byte, 16)
	_, _ = rand.Read(tokBytes)
	token := hex.EncodeToString(tokBytes)

	ln, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		return SyncSessionInfo{OK: false, Error: "开启临时局域网同步监听失败: " + err.Error()}, err
	}
	port := ln.Addr().(*net.TCPAddr).Port

	parsedCustom, _ := ParseCustomProxiesYAML(bundle.Overlay.CustomProxiesYAML)
	summary := fmt.Sprintf("同步内容：自建节点 %d 个 · %d 家 AI 严格分流 · Tailscale 分流域 %d 个 · 订阅配置 %d 份（不同步电脑设备名与 Tailscale 登录凭据，手机扫码后独立授权）",
		len(parsedCustom), len(bundle.Overlay.AIProviders), len(bundle.TailscaleRouting.SplitDNSDomains), len(bundle.Profiles))

	m.mu.Lock()
	m.closeLocked()
	m.ln = ln
	m.token = token
	m.payload = payload
	m.port = port
	m.selectedIP = chosenIP
	m.lanIPs = lanIPs
	m.expiresAt = time.Now().Add(5 * time.Minute)
	m.syncedCount = 0
	m.summary = summary

	mux := http.NewServeMux()
	mux.HandleFunc("/sync", m.handleSyncFetch)
	srv := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	m.srv = srv
	m.timer = time.AfterFunc(5*time.Minute, func() {
		m.Close()
	})
	info := m.buildInfoLocked()
	m.mu.Unlock()

	go func() {
		_ = srv.Serve(ln)
	}()

	return info, nil
}

func (m *SyncSessionManager) Status() SyncSessionInfo {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.srv == nil || m.token == "" || time.Now().After(m.expiresAt) {
		return SyncSessionInfo{OK: true, Active: false, LanIPs: detectBestLANIPv4s()}
	}
	return m.buildInfoLocked()
}

func (m *SyncSessionManager) buildInfoLocked() SyncSessionInfo {
	syncURL := fmt.Sprintf("http://%s:%d/sync?token=%s", m.selectedIP, m.port, m.token)
	qrText := "clashharmony://sync?url=" + url.QueryEscape(syncURL)
	qrDataURL := ""
	if pngBytes, err := qrcode.Encode(qrText, qrcode.Medium, 256); err == nil {
		qrDataURL = "data:image/png;base64," + base64.StdEncoding.EncodeToString(pngBytes)
	}
	return SyncSessionInfo{
		OK:          true,
		Active:      true,
		SyncURL:     syncURL,
		QRText:      qrText,
		QRDataURL:   qrDataURL,
		SelectedIP:  m.selectedIP,
		LanIPs:      append([]string(nil), m.lanIPs...),
		Port:        m.port,
		ExpiresAt:   m.expiresAt.Format(time.RFC3339),
		SyncedCount: m.syncedCount,
		Summary:     m.summary,
	}
}

func (m *SyncSessionManager) handleSyncFetch(w http.ResponseWriter, r *http.Request) {
	reqToken := strings.TrimSpace(r.URL.Query().Get("token"))
	m.mu.Lock()
	valid := m.token != "" && time.Now().Before(m.expiresAt) &&
		len(reqToken) == len(m.token) &&
		subtle.ConstantTimeCompare([]byte(reqToken), []byte(m.token)) == 1
	if !valid {
		m.mu.Unlock()
		writeJSON(w, http.StatusForbidden, map[string]any{"ok": false, "error": "同步二维码已过期或无效，请在电脑端重新生成"})
		return
	}
	data := append([]byte(nil), m.payload...)
	m.syncedCount++
	m.mu.Unlock()

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func detectBestLANIPv4s() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	type cand struct {
		ip    string
		score int
	}
	cands := []cand{}
	seen := map[string]bool{}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		nameLow := strings.ToLower(iface.Name)
		// Skip TUN / virtual / WSL / Hyper-V / Bluetooth / Docker adapters
		if strings.Contains(nameLow, "clash") ||
			strings.Contains(nameLow, "wintun") ||
			strings.Contains(nameLow, "meta") ||
			strings.Contains(nameLow, "vethernet") ||
			strings.Contains(nameLow, "wsl") ||
			strings.Contains(nameLow, "docker") ||
			strings.Contains(nameLow, "vmware") ||
			strings.Contains(nameLow, "virtualbox") ||
			strings.Contains(nameLow, "bluetooth") {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok || ipNet.IP == nil {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}
			// Never advertise fake-ip range 198.18.0.0/15
			if ip4[0] == 198 && (ip4[1] == 18 || ip4[1] == 19) {
				continue
			}
			ipStr := ip4.String()
			if seen[ipStr] {
				continue
			}
			seen[ipStr] = true
			score := 50
			if ip4[0] == 192 && ip4[1] == 168 {
				score = 10 // Most common home/office Wi-Fi LAN
			} else if ip4[0] == 10 {
				score = 15 // Corporate/campus LAN
			} else if ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31 {
				score = 25
			} else if ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127 {
				score = 40 // Tailscale IP as fallback
			}
			if strings.Contains(nameLow, "wlan") || strings.Contains(nameLow, "wi-fi") || strings.Contains(nameLow, "wifi") || strings.Contains(nameLow, "ethernet") || strings.Contains(nameLow, "以太网") {
				score -= 5
			}
			cands = append(cands, cand{ip: ipStr, score: score})
		}
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].score != cands[j].score {
			return cands[i].score < cands[j].score
		}
		return cands[i].ip < cands[j].ip
	})
	out := make([]string, 0, len(cands))
	for _, c := range cands {
		out = append(out, c.ip)
	}
	return out
}
