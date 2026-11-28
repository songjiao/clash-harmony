package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strings"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/tailscale/ipn"
	"github.com/metacubex/tailscale/tailcfg"
	D "github.com/miekg/dns"
)

const defaultTailscaleAPIAddr = "127.0.0.1:9091"

type tailscalePeerDTO struct {
	ID             string   `json:"id"`
	HostName       string   `json:"hostName"`
	DNSName        string   `json:"dnsName"`
	OS             string   `json:"os"`
	TailscaleIPs   []string `json:"tailscaleIPs"`
	Online         bool     `json:"online"`
	Active         bool     `json:"active"`
	ExitNode       bool     `json:"exitNode"`
	ExitNodeOption bool     `json:"exitNodeOption"`
	CurAddr        string   `json:"curAddr"`
	Relay          string   `json:"relay"`
	RxBytes        int64    `json:"rxBytes"`
	TxBytes        int64    `json:"txBytes"`
	PrimaryRoutes  []string `json:"primaryRoutes"`
}

type tailscaleAdvertisedRouteDTO struct {
	CIDR     string `json:"cidr"`
	PeerName string `json:"peerName"`
	PeerIP   string `json:"peerIp"`
	Online   bool   `json:"online"`
}

type tailscaleSplitDnsDTO struct {
	Domain      string   `json:"domain"`
	Nameservers []string `json:"nameservers"`
}

type tailscaleDnsQueryReq struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type tailscaleDnsQueryResp struct {
	OK        bool     `json:"ok"`
	Name      string   `json:"name"`
	Type      string   `json:"type"`
	Answers   []string `json:"answers"`
	Resolvers []string `json:"resolvers"`
	LatencyMs float64  `json:"latencyMs"`
	Error     string   `json:"error"`
}

type tailscaleControlStatusDTO struct {
	Available        bool                          `json:"available"`
	ProxyName        string                        `json:"proxyName"`
	BackendState     string                        `json:"backendState"`
	AuthURL          string                        `json:"authUrl"`
	TailnetName      string                        `json:"tailnetName"`
	MagicDNSSuffix   string                        `json:"magicDnsSuffix"`
	ControlURL       string                        `json:"controlUrl"`
	Hostname         string                        `json:"hostname"`
	LoginName        string                        `json:"loginName"`
	TailscaleIPs     []string                      `json:"tailscaleIPs"`
	AcceptRoutes     bool                          `json:"acceptRoutes"`
	ExitNodeID       string                        `json:"exitNodeId"`
	ExitNodeIP       string                        `json:"exitNodeIp"`
	ExitNodeAllowLAN bool                          `json:"exitNodeAllowLan"`
	Health           []string                      `json:"health"`
	LastError        string                        `json:"lastError"`
	RecentLogs       []string                      `json:"recentLogs"`
	Peers            []tailscalePeerDTO            `json:"peers"`
	AdvertisedRoutes []tailscaleAdvertisedRouteDTO `json:"advertisedRoutes"`
	SplitDNS         []tailscaleSplitDnsDTO        `json:"splitDns"`
	SearchDomains    []string                      `json:"searchDomains"`
	UpdatedAt        string                        `json:"updatedAt"`
}

type tailscalePrefsPatchReq struct {
	Hostname         *string `json:"hostname,omitempty"`
	AcceptRoutes     *bool   `json:"acceptRoutes,omitempty"`
	ExitNode         *string `json:"exitNode,omitempty"`
	ExitNodeAllowLAN *bool   `json:"exitNodeAllowLan,omitempty"`
	ControlURL       *string `json:"controlUrl,omitempty"`
}

type tailscalePingReq struct {
	IP string `json:"ip"`
}

type tailscalePingResp struct {
	OK             bool    `json:"ok"`
	IP             string  `json:"ip"`
	LatencyMs      float64 `json:"latencyMs"`
	Direct         bool    `json:"direct"`
	Endpoint       string  `json:"endpoint"`
	DERPRegionCode string  `json:"derpRegionCode"`
	Error          string  `json:"error"`
}

func findActiveTailscaleOutbound() *outbound.Tailscale {
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
		if tsProxy, ok := adapter.(*outbound.Tailscale); ok {
			return tsProxy
		}
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func buildTailscaleControlStatus(ctx context.Context) tailscaleControlStatusDTO {
	dto := tailscaleControlStatusDTO{
		TailscaleIPs:     []string{},
		Health:           []string{},
		RecentLogs:       []string{},
		Peers:            []tailscalePeerDTO{},
		AdvertisedRoutes: []tailscaleAdvertisedRouteDTO{},
		SplitDNS:         []tailscaleSplitDnsDTO{},
		SearchDomains:    []string{},
		UpdatedAt:        time.Now().Format(time.RFC3339),
	}

	tsProxy := findActiveTailscaleOutbound()
	if tsProxy == nil {
		dto.BackendState = "Unavailable"
		dto.LastError = "当前配置未启用 Tailscale 出站"
		return dto
	}

	snap := tsProxy.StatusSnapshot()
	opt := tsProxy.Option()
	dto.Available = true
	dto.ProxyName = tsProxy.Name()
	dto.BackendState = snap.BackendState
	dto.AuthURL = snap.AuthURL
	dto.Hostname = snap.Hostname
	if dto.Hostname == "" {
		dto.Hostname = opt.Hostname
	}
	dto.ControlURL = opt.ControlURL
	dto.TailscaleIPs = snap.TailscaleIPs
	dto.Health = snap.Health
	dto.LastError = snap.LastError
	dto.RecentLogs = snap.RecentLogs
	if opt.AcceptRoutes != nil {
		dto.AcceptRoutes = *opt.AcceptRoutes
	}
	if opt.ExitNodeAllowLANAccess != nil {
		dto.ExitNodeAllowLAN = *opt.ExitNodeAllowLANAccess
	}

	lc, err := tsProxy.LocalClient()
	if err != nil {
		return dto
	}

	stCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	if prefs, pErr := lc.GetPrefs(stCtx); pErr == nil && prefs != nil {
		dto.AcceptRoutes = prefs.RouteAll
		dto.ExitNodeAllowLAN = prefs.ExitNodeAllowLANAccess
		if prefs.Hostname != "" {
			dto.Hostname = prefs.Hostname
		}
		if prefs.ControlURL != "" {
			dto.ControlURL = prefs.ControlURL
		}
		if prefs.ExitNodeID != "" {
			dto.ExitNodeID = string(prefs.ExitNodeID)
		}
		if prefs.ExitNodeIP.IsValid() {
			dto.ExitNodeIP = prefs.ExitNodeIP.String()
		}
	}

	st, sErr := lc.Status(stCtx)
	if sErr != nil || st == nil {
		return dto
	}

	dto.BackendState = st.BackendState
	if st.BackendState == ipn.Running.String() {
		dto.AuthURL = ""
	} else if st.AuthURL != "" {
		dto.AuthURL = st.AuthURL
	}
	if st.CurrentTailnet != nil {
		dto.TailnetName = st.CurrentTailnet.Name
		dto.MagicDNSSuffix = st.CurrentTailnet.MagicDNSSuffix
	}
	if dto.MagicDNSSuffix == "" {
		dto.MagicDNSSuffix = st.MagicDNSSuffix
	}
	if len(st.Health) > 0 {
		dto.Health = append([]string(nil), st.Health...)
	}

	ips := make([]string, 0, len(st.TailscaleIPs))
	for _, ip := range st.TailscaleIPs {
		ips = append(ips, ip.String())
	}
	if len(ips) > 0 {
		dto.TailscaleIPs = ips
	}

	if st.Self != nil {
		if st.Self.HostName != "" {
			dto.Hostname = st.Self.HostName
		}
		if u, ok := st.User[st.Self.UserID]; ok {
			if u.LoginName != "" {
				dto.LoginName = u.LoginName
			} else if u.DisplayName != "" {
				dto.LoginName = u.DisplayName
			}
		}
	}

	if st.ExitNodeStatus != nil {
		dto.ExitNodeID = string(st.ExitNodeStatus.ID)
		if len(st.ExitNodeStatus.TailscaleIPs) > 0 {
			dto.ExitNodeIP = st.ExitNodeStatus.TailscaleIPs[0].Addr().String()
		}
	}

	seenRoutes := map[string]bool{}
	for _, peer := range st.Peer {
		if peer == nil {
			continue
		}
		peerIPs := make([]string, 0, len(peer.TailscaleIPs))
		for _, ip := range peer.TailscaleIPs {
			peerIPs = append(peerIPs, ip.String())
		}
		routes := []string{}
		if peer.PrimaryRoutes != nil {
			for i := 0; i < peer.PrimaryRoutes.Len(); i++ {
				cidr := peer.PrimaryRoutes.At(i).String()
				routes = append(routes, cidr)
				if !seenRoutes[cidr] {
					seenRoutes[cidr] = true
					primaryIP := ""
					if len(peerIPs) > 0 {
						primaryIP = peerIPs[0]
					}
					dto.AdvertisedRoutes = append(dto.AdvertisedRoutes, tailscaleAdvertisedRouteDTO{
						CIDR:     cidr,
						PeerName: peer.HostName,
						PeerIP:   primaryIP,
						Online:   peer.Online,
					})
				}
			}
		}
		if peer.ExitNode && dto.ExitNodeIP == "" && len(peerIPs) > 0 {
			dto.ExitNodeIP = peerIPs[0]
		}
		dto.Peers = append(dto.Peers, tailscalePeerDTO{
			ID:             string(peer.ID),
			HostName:       peer.HostName,
			DNSName:        strings.TrimSuffix(peer.DNSName, "."),
			OS:             peer.OS,
			TailscaleIPs:   peerIPs,
			Online:         peer.Online,
			Active:         peer.Active,
			ExitNode:       peer.ExitNode,
			ExitNodeOption: peer.ExitNodeOption,
			CurAddr:        peer.CurAddr,
			Relay:          peer.Relay,
			RxBytes:        peer.RxBytes,
			TxBytes:        peer.TxBytes,
			PrimaryRoutes:  routes,
		})
	}

	sort.Slice(dto.Peers, func(i, j int) bool {
		if dto.Peers[i].Online != dto.Peers[j].Online {
			return dto.Peers[i].Online
		}
		return strings.ToLower(dto.Peers[i].HostName) < strings.ToLower(dto.Peers[j].HostName)
	})
	sort.Slice(dto.AdvertisedRoutes, func(i, j int) bool {
		return dto.AdvertisedRoutes[i].CIDR < dto.AdvertisedRoutes[j].CIDR
	})

	if dnsCfg, dErr := lc.DNSConfig(stCtx); dErr == nil && dnsCfg != nil {
		dto.SplitDNS, dto.SearchDomains = extractSplitDnsFromConfig(dnsCfg, dto.MagicDNSSuffix)
	}

	return dto
}

func extractSplitDnsFromConfig(dnsCfg *tailcfg.DNSConfig, magicSuffix string) ([]tailscaleSplitDnsDTO, []string) {
	split := []tailscaleSplitDnsDTO{}
	search := []string{}
	if dnsCfg == nil {
		return split, search
	}

	cleanMagic := strings.ToLower(strings.Trim(strings.TrimSpace(magicSuffix), "."))
	seenDomain := map[string]bool{}
	for rawDomain, resolvers := range dnsCfg.Routes {
		domain := strings.ToLower(strings.Trim(strings.TrimSpace(rawDomain), "."))
		if domain == "" || seenDomain[domain] {
			continue
		}
		if domain == "ts.net" || domain == cleanMagic ||
			strings.HasSuffix(domain, ".in-addr.arpa") || domain == "in-addr.arpa" ||
			strings.HasSuffix(domain, ".ip6.arpa") || domain == "ip6.arpa" {
			continue
		}
		seenDomain[domain] = true
		nsList := []string{}
		seenNS := map[string]bool{}
		for _, r := range resolvers {
			if r == nil {
				continue
			}
			addr := strings.TrimSpace(r.Addr)
			if addr != "" && !seenNS[addr] {
				seenNS[addr] = true
				nsList = append(nsList, addr)
			}
		}
		split = append(split, tailscaleSplitDnsDTO{
			Domain:      domain,
			Nameservers: nsList,
		})
	}
	sort.Slice(split, func(i, j int) bool {
		return split[i].Domain < split[j].Domain
	})

	seenSearch := map[string]bool{}
	for _, d := range dnsCfg.Domains {
		clean := strings.ToLower(strings.Trim(strings.TrimSpace(d), "."))
		if clean == "" || seenSearch[clean] {
			continue
		}
		seenSearch[clean] = true
		search = append(search, clean)
	}
	return split, search
}

func newTailscaleAPIMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/tailscale/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, buildTailscaleControlStatus(r.Context()))
	})

	mux.HandleFunc("/tailscale/prefs", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost && r.Method != http.MethodPatch {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		tsProxy := findActiveTailscaleOutbound()
		if tsProxy == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "Tailscale 出站未启用"})
			return
		}
		lc, err := tsProxy.LocalClient()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": err.Error()})
			return
		}

		var req tailscalePrefsPatchReq
		if err := json.NewDecoder(io.LimitReader(r.Body, 64*1024)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}

		mp := &ipn.MaskedPrefs{}
		if req.Hostname != nil {
			mp.Hostname = strings.TrimSpace(*req.Hostname)
			mp.HostnameSet = true
		}
		if req.AcceptRoutes != nil {
			mp.RouteAll = *req.AcceptRoutes
			mp.RouteAllSet = true
		}
		if req.ExitNodeAllowLAN != nil {
			mp.ExitNodeAllowLANAccess = *req.ExitNodeAllowLAN
			mp.ExitNodeAllowLANAccessSet = true
		}
		if req.ControlURL != nil {
			mp.ControlURL = strings.TrimSpace(*req.ControlURL)
			mp.ControlURLSet = true
		}

		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		if req.ExitNode != nil {
			target := strings.TrimSpace(*req.ExitNode)
			if target == "" {
				mp.ExitNodeID = ""
				mp.ExitNodeIDSet = true
				mp.ExitNodeIP = netip.Addr{}
				mp.ExitNodeIPSet = true
			} else {
				st, sErr := lc.Status(ctx)
				if sErr != nil {
					writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": fmt.Sprintf("读取节点状态失败: %v", sErr)})
					return
				}
				mp.ExitNodeIPSet = true
				if err := mp.SetExitNodeIP(target, st); err != nil {
					writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": fmt.Sprintf("设置 Exit Node 失败: %v", err)})
					return
				}
			}
		}

		if _, err := lc.EditPrefs(ctx, mp); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":     true,
			"status": buildTailscaleControlStatus(ctx),
		})
	})

	mux.HandleFunc("/tailscale/login", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		tsProxy := findActiveTailscaleOutbound()
		if tsProxy == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "Tailscale 出站未启用"})
			return
		}
		lc, err := tsProxy.LocalClient()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		if err := lc.StartLoginInteractive(ctx); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":     true,
			"status": buildTailscaleControlStatus(ctx),
		})
	})

	mux.HandleFunc("/tailscale/logout", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		tsProxy := findActiveTailscaleOutbound()
		if tsProxy == nil {
			writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "Tailscale 出站未启用"})
			return
		}
		lc, err := tsProxy.LocalClient()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		if err := lc.Logout(ctx); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":     true,
			"status": buildTailscaleControlStatus(ctx),
		})
	})

	mux.HandleFunc("/tailscale/ping", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		tsProxy := findActiveTailscaleOutbound()
		if tsProxy == nil {
			writeJSON(w, http.StatusNotFound, tailscalePingResp{OK: false, Error: "Tailscale 出站未启用"})
			return
		}
		lc, err := tsProxy.LocalClient()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, tailscalePingResp{OK: false, Error: err.Error()})
			return
		}
		var req tailscalePingReq
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, tailscalePingResp{OK: false, Error: err.Error()})
			return
		}
		addr, err := netip.ParseAddr(strings.TrimSpace(req.IP))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, tailscalePingResp{OK: false, IP: req.IP, Error: "无效 IP 地址"})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		pr, err := lc.Ping(ctx, addr, tailcfg.PingDisco)
		if err != nil {
			writeJSON(w, http.StatusOK, tailscalePingResp{OK: false, IP: addr.String(), Error: err.Error()})
			return
		}
		if pr.Err != "" {
			writeJSON(w, http.StatusOK, tailscalePingResp{OK: false, IP: addr.String(), Error: pr.Err})
			return
		}
		writeJSON(w, http.StatusOK, tailscalePingResp{
			OK:             true,
			IP:             addr.String(),
			LatencyMs:      pr.LatencySeconds * 1000.0,
			Direct:         pr.Endpoint != "",
			Endpoint:       pr.Endpoint,
			DERPRegionCode: pr.DERPRegionCode,
		})
	})

	mux.HandleFunc("/tailscale/dns-query", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, tailscaleDnsQueryResp{OK: false, Answers: []string{}, Resolvers: []string{}, Error: "method not allowed"})
			return
		}
		tsProxy := findActiveTailscaleOutbound()
		if tsProxy == nil {
			writeJSON(w, http.StatusNotFound, tailscaleDnsQueryResp{OK: false, Answers: []string{}, Resolvers: []string{}, Error: "Tailscale 出站未启用"})
			return
		}
		lc, err := tsProxy.LocalClient()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, tailscaleDnsQueryResp{OK: false, Answers: []string{}, Resolvers: []string{}, Error: err.Error()})
			return
		}
		var req tailscaleDnsQueryReq
		if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, tailscaleDnsQueryResp{OK: false, Answers: []string{}, Resolvers: []string{}, Error: err.Error()})
			return
		}
		name := strings.TrimSpace(req.Name)
		if name == "" {
			writeJSON(w, http.StatusBadRequest, tailscaleDnsQueryResp{OK: false, Answers: []string{}, Resolvers: []string{}, Error: "域名不能为空"})
			return
		}
		qtype := strings.ToUpper(strings.TrimSpace(req.Type))
		if qtype == "" {
			qtype = "A"
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		started := time.Now()
		rawResp, resolvers, err := lc.QueryDNS(ctx, name, qtype)
		latencyMs := float64(time.Since(started).Microseconds()) / 1000.0
		if err != nil {
			writeJSON(w, http.StatusOK, tailscaleDnsQueryResp{
				OK:        false,
				Name:      name,
				Type:      qtype,
				Answers:   []string{},
				Resolvers: []string{},
				LatencyMs: latencyMs,
				Error:     err.Error(),
			})
			return
		}
		answers := []string{}
		var msg D.Msg
		if uErr := msg.Unpack(rawResp); uErr == nil {
			for _, rr := range msg.Answer {
				switch v := rr.(type) {
				case *D.A:
					answers = append(answers, v.A.String())
				case *D.AAAA:
					answers = append(answers, v.AAAA.String())
				case *D.CNAME:
					answers = append(answers, strings.TrimSuffix(v.Target, "."))
				default:
					answers = append(answers, rr.String())
				}
			}
		}
		resolverAddrs := []string{}
		for _, res := range resolvers {
			if res != nil && strings.TrimSpace(res.Addr) != "" {
				resolverAddrs = append(resolverAddrs, strings.TrimSpace(res.Addr))
			}
		}
		writeJSON(w, http.StatusOK, tailscaleDnsQueryResp{
			OK:        len(answers) > 0,
			Name:      name,
			Type:      qtype,
			Answers:   answers,
			Resolvers: resolverAddrs,
			LatencyMs: latencyMs,
			Error:     func() string {
				if len(answers) == 0 {
					return "未返回解析记录"
				}
				return ""
			}(),
		})
	})

	mux.HandleFunc("/config/validate", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, ValidationResult{OK: false, Error: "method not allowed", Warnings: []string{}})
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 4*1024*1024))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, ValidationResult{OK: false, Error: err.Error(), Warnings: []string{}})
			return
		}
		writeJSON(w, http.StatusOK, validateConfigYAML(string(body)))
	})

	mux.HandleFunc("/config/rule-test", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			Target  string `json:"target"`
			Port    int    `json:"port"`
			Network string `json:"network"`
		}
		if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, evaluateLiveRuleMatch(req.Target, req.Port, req.Network))
	})

	mux.HandleFunc("/network/rebind", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stats": ohosNetCoordinator.Stats()})
			return
		}
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "method not allowed"})
			return
		}
		var req struct {
			IfaceName         string `json:"ifaceName"`
			Reason            string `json:"reason"`
			RebindTailscale   *bool  `json:"rebindTailscale"`
			PruneNonTailscale *bool  `json:"pruneNonTailscale"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req)
		flags := 0
		if req.RebindTailscale == nil || *req.RebindTailscale {
			flags |= netChangeFlagRebindTS
		}
		if req.PruneNonTailscale != nil && *req.PruneNonTailscale {
			flags |= netChangeFlagPruneNonTS
		}
		reason := strings.TrimSpace(req.Reason)
		if reason == "" {
			reason = "api-rebind"
		}
		bridge.notifyNetworkChange(req.IfaceName, reason, flags)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stats": ohosNetCoordinator.Stats()})
	})

	return mux
}

type ruleTestResultDTO struct {
	OK            bool     `json:"ok"`
	Target        string   `json:"target"`
	Host          string   `json:"host"`
	IP            string   `json:"ip"`
	Port          uint16   `json:"port"`
	Network       string   `json:"network"`
	Mode          string   `json:"mode"`
	RuleType      string   `json:"ruleType"`
	RulePayload   string   `json:"rulePayload"`
	RuleRaw       string   `json:"ruleRaw"`
	ProxyChain    []string `json:"proxyChain"`
	FinalOutbound string   `json:"finalOutbound"`
	FinalType     string   `json:"finalType"`
	Error         string   `json:"error,omitempty"`
}

func evaluateLiveRuleMatch(rawTarget string, port int, network string) ruleTestResultDTO {
	res := ruleTestResultDTO{
		Target:     strings.TrimSpace(rawTarget),
		ProxyChain: []string{},
		Mode:       tunnel.Mode().String(),
	}
	if res.Target == "" {
		res.Error = "请输入域名、URL 或 IP 地址"
		return res
	}
	if len(tunnel.Proxies()) == 0 {
		res.Error = "核心尚未启动，请先启动核心后再执行规则测试"
		return res
	}

	cleaned := res.Target
	if idx := strings.Index(cleaned, "://"); idx >= 0 {
		cleaned = cleaned[idx+3:]
	}
	if idx := strings.IndexAny(cleaned, "/?#"); idx >= 0 {
		cleaned = cleaned[:idx]
	}
	cleaned = strings.TrimSpace(cleaned)

	dstPort := uint16(443)
	if port > 0 && port <= 65535 {
		dstPort = uint16(port)
	}
	host := cleaned
	if strings.HasPrefix(cleaned, "[") {
		if end := strings.IndexByte(cleaned, ']'); end > 0 {
			host = cleaned[1:end]
			if rest := cleaned[end+1:]; strings.HasPrefix(rest, ":") {
				var p int
				if _, err := fmt.Sscanf(rest[1:], "%d", &p); err == nil && p > 0 && p <= 65535 {
					dstPort = uint16(p)
				}
			}
		}
	} else if strings.Count(cleaned, ":") == 1 {
		parts := strings.SplitN(cleaned, ":", 2)
		host = parts[0]
		var p int
		if _, err := fmt.Sscanf(parts[1], "%d", &p); err == nil && p > 0 && p <= 65535 {
			dstPort = uint16(p)
		}
	}

	netKind := C.TCP
	netLabel := "TCP"
	if strings.EqualFold(strings.TrimSpace(network), "udp") {
		netKind = C.UDP
		netLabel = "UDP"
	}

	md := &C.Metadata{
		NetWork: netKind,
		Type:    C.TUN,
		DstPort: dstPort,
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		md.DstIP = ip
		res.IP = ip.String()
	} else {
		md.Host = strings.ToLower(strings.Trim(host, "."))
		res.Host = md.Host
	}
	res.Port = dstPort
	res.Network = netLabel

	proxy, rule, err := tunnel.Tunnel.ResolveProxy(md)
	if err != nil || proxy == nil {
		if err != nil {
			res.Error = err.Error()
		} else {
			res.Error = "未匹配到可用出站"
		}
		return res
	}
	if md.DstIP.IsValid() && res.IP == "" {
		res.IP = md.DstIP.String()
	}

	if rule != nil {
		res.RuleType = rule.RuleType().String()
		res.RulePayload = rule.Payload()
		if res.RulePayload != "" {
			res.RuleRaw = fmt.Sprintf("%s,%s,%s", res.RuleType, res.RulePayload, proxy.Name())
		} else {
			res.RuleRaw = fmt.Sprintf("%s,%s", res.RuleType, proxy.Name())
		}
	} else {
		res.RuleType = strings.ToUpper(res.Mode)
		res.RuleRaw = fmt.Sprintf("MODE(%s) -> %s", res.Mode, proxy.Name())
	}

	chain := []string{}
	cur := proxy
	for cur != nil {
		chain = append(chain, cur.Name())
		next := cur.Unwrap(md, false)
		if next == nil || next == cur {
			res.FinalOutbound = cur.Name()
			res.FinalType = cur.Type().String()
			break
		}
		cur = next
	}
	res.ProxyChain = chain
	res.OK = true
	return res
}

func (m *bridgeManager) startTailscaleAPILocked(addr string) {
	m.stopTailscaleAPILocked()
	if strings.TrimSpace(addr) == "" {
		addr = defaultTailscaleAPIAddr
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Warnln("[Bridge] Tailscale control API listen %s failed: %v", addr, err)
		return
	}
	srv := &http.Server{
		Handler:           newTailscaleAPIMux(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	m.tsAPIServer = srv
	m.tsAPIAddr = ln.Addr().String()
	log.Infoln("[Bridge] Tailscale control API listening at: %s", m.tsAPIAddr)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Warnln("[Bridge] Tailscale control API stopped: %v", err)
		}
	}()
}

func (m *bridgeManager) stopTailscaleAPILocked() {
	if m.tsAPIServer != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		_ = m.tsAPIServer.Shutdown(ctx)
		cancel()
		m.tsAPIServer = nil
		m.tsAPIAddr = ""
	}
}
