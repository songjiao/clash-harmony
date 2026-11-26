package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

const defaultSelfHostedGroupName = "🛡️ AI严格自建"

// AIProviderPreset describes a one-click AI vendor preset for strict Fail-Closed self-hosted routing.
type AIProviderPreset struct {
	ID       string   `json:"id"`
	Label    string   `json:"label"`
	Subtitle string   `json:"subtitle"`
	Domains  []string `json:"domains"`
	Keywords []string `json:"keywords"`
}

func allAIProviderPresets() []AIProviderPreset {
	return []AIProviderPreset{
		{
			ID:       "claude",
			Label:    "Claude",
			Subtitle: "Anthropic / Claude.ai / Claude Code",
			Domains: []string{
				"anthropic.com",
				"claude.ai",
				"claude.com",
				"claudeusercontent.com",
				"statsig.anthropic.com",
			},
			Keywords: []string{"anthropic", "claude"},
		},
		{
			ID:       "gemini",
			Label:    "Gemini / Antigravity",
			Subtitle: "Gemini / AI Studio / Antigravity / Google AI",
			Domains: []string{
				"gemini.google.com",
				"aistudio.google.com",
				"makersuite.google.com",
				"generativelanguage.googleapis.com",
				"ai.google.dev",
				"deepmind.google",
				"labs.google",
				"jules.google.com",
				"notebooklm.google.com",
				"antigravity.google",
				"antigravity.google.com",
				"cloudcode-pa.googleapis.com",
				"daily-cloudcode-pa.googleapis.com",
				"daily-cloudcode-pa.sandbox.googleapis.com",
				"autopush-cloudcode-pa.sandbox.googleapis.com",
				"proactivebackend-pa.googleapis.com",
				"aisandbox-pa.googleapis.com",
				"oauth2.googleapis.com",
				"accounts.google.com",
			},
		},
		{
			ID:       "openai",
			Label:    "OpenAI / ChatGPT",
			Subtitle: "ChatGPT / API / Sora / Codex",
			Domains: []string{
				"openai.com",
				"chatgpt.com",
				"oaistatic.com",
				"oaiusercontent.com",
				"sora.com",
			},
		},
		{
			ID:       "cursor",
			Label:    "Cursor / Copilot",
			Subtitle: "Cursor IDE / GitHub Copilot / Codeium",
			Domains: []string{
				"cursor.sh",
				"cursor.com",
				"githubcopilot.com",
				"copilot.github.com",
				"copilot-proxy.githubusercontent.com",
				"codeium.com",
			},
		},
		{
			ID:       "xai",
			Label:    "Grok / xAI",
			Subtitle: "x.ai / grok.com",
			Domains: []string{
				"x.ai",
				"grok.com",
			},
		},
		{
			ID:       "other_ai",
			Label:    "其他 AI",
			Subtitle: "Perplexity / OpenRouter / Groq / Mistral / Poe / HF",
			Domains: []string{
				"perplexity.ai",
				"poe.com",
				"openrouter.ai",
				"groq.com",
				"mistral.ai",
				"cohere.ai",
				"cohere.com",
				"huggingface.co",
				"hf.co",
				"copilot.microsoft.com",
				"openai.azure.com",
				"cognitiveservices.azure.com",
				"api.cognitive.microsoft.com",
				"midjourney.com",
				"suno.com",
				"runwayml.com",
				"elevenlabs.io",
			},
		},
	}
}

func defaultAIProviders() []string {
	presets := allAIProviderPresets()
	out := make([]string, 0, len(presets))
	for _, p := range presets {
		out = append(out, p.ID)
	}
	return out
}

func expandAIProviders(selected []string) (domains []string, keywords []string) {
	want := map[string]bool{}
	for _, id := range selected {
		want[strings.ToLower(strings.TrimSpace(id))] = true
	}
	for _, p := range allAIProviderPresets() {
		if want[p.ID] {
			domains = append(domains, p.Domains...)
			keywords = append(keywords, p.Keywords...)
		}
	}
	return normalizeDomainList(domains), keywords
}

// CustomOverlay defines the subscription-independent user overlay layer (shared 1:1 with HarmonyOS).
// When commercial subscriptions (e.g. BitzNet) are refreshed, this overlay is preserved and merged at runtime.
type CustomOverlay struct {
	Enabled             bool     `json:"enabled"`
	SelfHostedGroupName string   `json:"selfHostedGroupName"`
	FailClosed          bool     `json:"failClosed"`
	AIStrictEnabled     bool     `json:"aiStrictEnabled"`
	AIProviders         []string `json:"aiProviders"`
	AIDomains           []string `json:"aiDomains"`
	AIKeywords          []string `json:"aiKeywords"`
	CustomProxiesYAML   string   `json:"customProxiesYaml"`
	CustomRules         []string `json:"customRules"`
	DirectDomains       []string `json:"directDomains"`
}

func defaultCustomOverlay() CustomOverlay {
	return CustomOverlay{
		Enabled:             false,
		SelfHostedGroupName: defaultSelfHostedGroupName,
		FailClosed:          true,
		AIStrictEnabled:     true,
		AIProviders:         defaultAIProviders(),
		AIDomains:           []string{},
		AIKeywords:          []string{},
		CustomProxiesYAML:   "",
		CustomRules:         []string{},
		DirectDomains:       []string{},
	}
}

func normalizeOverlay(o CustomOverlay) CustomOverlay {
	if strings.TrimSpace(o.SelfHostedGroupName) == "" {
		o.SelfHostedGroupName = defaultSelfHostedGroupName
	} else {
		o.SelfHostedGroupName = strings.TrimSpace(o.SelfHostedGroupName)
	}
	// Migrate legacy overlays that did not have aiProviders yet.
	if o.AIProviders == nil {
		if len(o.AIDomains) == 0 && len(o.AIKeywords) == 0 {
			o.AIProviders = defaultAIProviders()
		} else {
			o.AIProviders = []string{}
		}
	} else {
		valid := map[string]bool{}
		for _, p := range allAIProviderPresets() {
			valid[p.ID] = true
		}
		clean := []string{}
		seen := map[string]bool{}
		for _, id := range o.AIProviders {
			c := strings.ToLower(strings.TrimSpace(id))
			if valid[c] && !seen[c] {
				seen[c] = true
				clean = append(clean, c)
			}
		}
		o.AIProviders = clean
	}

	o.AIDomains = normalizeDomainList(o.AIDomains)
	o.DirectDomains = normalizeDomainList(o.DirectDomains)

	kwOut := []string{}
	kwSeen := map[string]bool{}
	for _, k := range o.AIKeywords {
		c := strings.ToLower(strings.TrimSpace(k))
		if c != "" && !kwSeen[c] {
			kwSeen[c] = true
			kwOut = append(kwOut, c)
		}
	}
	o.AIKeywords = kwOut

	ruleOut := []string{}
	ruleSeen := map[string]bool{}
	for _, r := range o.CustomRules {
		c := strings.TrimSpace(r)
		if c == "" || strings.HasPrefix(c, "#") {
			continue
		}
		if strings.HasPrefix(c, "- ") {
			c = strings.TrimSpace(c[2:])
		}
		c = stripQuotes(c)
		if c != "" && !ruleSeen[c] {
			ruleSeen[c] = true
			ruleOut = append(ruleOut, c)
		}
	}
	o.CustomRules = ruleOut
	return o
}

type parsedCustomProxy struct {
	Name   string
	Server string
	RawMap map[string]any
}

// ParseCustomProxiesYAML parses user-defined self-hosted proxies YAML snippet OR share URIs
// (vless://, trojan://, ss://, vmess://, hy2://, hysteria2://).
func ParseCustomProxiesYAML(snippet string) ([]parsedCustomProxy, error) {
	trimmed := strings.TrimSpace(snippet)
	if trimmed == "" {
		return nil, nil
	}

	// Support pasting one or more share links directly (vless://, trojan://, ss://, vmess://, hy2://).
	if looksLikeShareURIs(trimmed) {
		list, err := parseShareURIsToProxyMaps(trimmed)
		if err != nil {
			return nil, err
		}
		return finalizeParsedCustomProxies(list)
	}

	var list []map[string]any
	if err := yaml.Unmarshal([]byte(trimmed), &list); err != nil || len(list) == 0 {
		var wrapper struct {
			Proxies []map[string]any `yaml:"proxies"`
		}
		if wErr := yaml.Unmarshal([]byte(trimmed), &wrapper); wErr == nil && len(wrapper.Proxies) > 0 {
			list = wrapper.Proxies
		} else {
			var single map[string]any
			if sErr := yaml.Unmarshal([]byte(trimmed), &single); sErr == nil && single != nil && single["name"] != nil {
				list = []map[string]any{single}
			} else if err != nil {
				return nil, fmt.Errorf("解析自建节点失败（请填入标准 Clash YAML 或 vless:// / trojan:// / ss:// 节点链接）: %w", err)
			}
		}
	}
	return finalizeParsedCustomProxies(list)
}

func looksLikeShareURIs(text string) bool {
	for _, line := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		l := strings.TrimSpace(line)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		low := strings.ToLower(l)
		return strings.HasPrefix(low, "vless://") ||
			strings.HasPrefix(low, "trojan://") ||
			strings.HasPrefix(low, "ss://") ||
			strings.HasPrefix(low, "vmess://") ||
			strings.HasPrefix(low, "hy2://") ||
			strings.HasPrefix(low, "hysteria2://")
	}
	return false
}

func parseShareURIsToProxyMaps(text string) ([]map[string]any, error) {
	out := []map[string]any{}
	idx := 0
	for _, rawLine := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx++
		low := strings.ToLower(line)
		var (
			m   map[string]any
			err error
		)
		switch {
		case strings.HasPrefix(low, "vless://"):
			m, err = parseVLESSURI(line, idx)
		case strings.HasPrefix(low, "trojan://"):
			m, err = parseTrojanURI(line, idx)
		case strings.HasPrefix(low, "ss://"):
			m, err = parseSSURI(line, idx)
		case strings.HasPrefix(low, "vmess://"):
			m, err = parseVMessURI(line, idx)
		case strings.HasPrefix(low, "hy2://"), strings.HasPrefix(low, "hysteria2://"):
			m, err = parseHysteria2URI(line, idx)
		default:
			return nil, fmt.Errorf("第 %d 行节点链接协议暂不支持（支持 vless/trojan/ss/vmess/hy2 或 Clash YAML）", idx)
		}
		if err != nil {
			return nil, fmt.Errorf("第 %d 行节点链接解析失败: %w", idx, err)
		}
		out = append(out, m)
	}
	return out, nil
}

func parseVLESSURI(raw string, idx int) (map[string]any, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port <= 0 {
		port = 443
	}
	name, _ := url.QueryUnescape(strings.TrimSpace(u.Fragment))
	if name == "" {
		name = fmt.Sprintf("自建-VLESS-%d", idx)
	}
	q := u.Query()
	m := map[string]any{
		"name":   name,
		"type":   "vless",
		"server": u.Hostname(),
		"port":   port,
		"uuid":   u.User.Username(),
		"udp":    true,
	}
	sec := strings.ToLower(q.Get("security"))
	if sec == "tls" || sec == "reality" {
		m["tls"] = true
	}
	if sni := firstNonEmpty(q.Get("sni"), q.Get("servername"), q.Get("host")); sni != "" {
		m["servername"] = sni
	}
	if fp := q.Get("fp"); fp != "" {
		m["client-fingerprint"] = fp
	}
	if flow := q.Get("flow"); flow != "" {
		m["flow"] = flow
	}
	if q.Get("allowInsecure") == "1" || strings.EqualFold(q.Get("allowInsecure"), "true") {
		m["skip-cert-verify"] = true
	}
	if sec == "reality" {
		ro := map[string]any{}
		if pbk := q.Get("pbk"); pbk != "" {
			ro["public-key"] = pbk
		}
		if sid := q.Get("sid"); sid != "" {
			ro["short-id"] = sid
		}
		if len(ro) > 0 {
			m["reality-opts"] = ro
		}
	}
	netType := strings.ToLower(q.Get("type"))
	if netType != "" && netType != "tcp" {
		m["network"] = netType
	}
	if netType == "ws" {
		ws := map[string]any{}
		if p := q.Get("path"); p != "" {
			ws["path"] = p
		}
		if h := q.Get("host"); h != "" {
			ws["headers"] = map[string]any{"Host": h}
		}
		if len(ws) > 0 {
			m["ws-opts"] = ws
		}
	} else if netType == "grpc" {
		if sn := q.Get("serviceName"); sn != "" {
			m["grpc-opts"] = map[string]any{"grpc-service-name": sn}
		}
	}
	return m, nil
}

func parseTrojanURI(raw string, idx int) (map[string]any, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port <= 0 {
		port = 443
	}
	name, _ := url.QueryUnescape(strings.TrimSpace(u.Fragment))
	if name == "" {
		name = fmt.Sprintf("自建-Trojan-%d", idx)
	}
	q := u.Query()
	m := map[string]any{
		"name":     name,
		"type":     "trojan",
		"server":   u.Hostname(),
		"port":     port,
		"password": u.User.Username(),
		"udp":      true,
	}
	if sni := firstNonEmpty(q.Get("sni"), q.Get("peer"), q.Get("host")); sni != "" {
		m["sni"] = sni
	}
	if q.Get("allowInsecure") == "1" || strings.EqualFold(q.Get("allowInsecure"), "true") {
		m["skip-cert-verify"] = true
	}
	if netType := strings.ToLower(q.Get("type")); netType == "ws" {
		m["network"] = "ws"
		ws := map[string]any{}
		if p := q.Get("path"); p != "" {
			ws["path"] = p
		}
		if h := q.Get("host"); h != "" {
			ws["headers"] = map[string]any{"Host": h}
		}
		if len(ws) > 0 {
			m["ws-opts"] = ws
		}
	}
	return m, nil
}

func parseSSURI(raw string, idx int) (map[string]any, error) {
	body := strings.TrimPrefix(raw, "ss://")
	name := fmt.Sprintf("自建-SS-%d", idx)
	if hIdx := strings.IndexByte(body, '#'); hIdx >= 0 {
		if dec, err := url.QueryUnescape(strings.TrimSpace(body[hIdx+1:])); err == nil && dec != "" {
			name = dec
		}
		body = body[:hIdx]
	}
	queryPart := ""
	if qIdx := strings.IndexByte(body, '?'); qIdx >= 0 {
		queryPart = body[qIdx+1:]
		body = body[:qIdx]
	}
	var method, password, server string
	var port int
	if atIdx := strings.LastIndexByte(body, '@'); atIdx >= 0 {
		userPart := body[:atIdx]
		hostPort := body[atIdx+1:]
		if dec, err := decodeFlexibleBase64(userPart); err == nil && strings.Contains(dec, ":") {
			userPart = dec
		}
		parts := strings.SplitN(userPart, ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("无效的 ss 用户信息")
		}
		method, password = parts[0], parts[1]
		u, err := url.Parse("http://" + hostPort)
		if err != nil {
			return nil, err
		}
		server = u.Hostname()
		port, _ = strconv.Atoi(u.Port())
	} else {
		dec, err := decodeFlexibleBase64(body)
		if err != nil {
			return nil, err
		}
		at := strings.LastIndexByte(dec, '@')
		if at < 0 {
			return nil, fmt.Errorf("无效的 ss 链接")
		}
		parts := strings.SplitN(dec[:at], ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("无效的 ss 加密字段")
		}
		method, password = parts[0], parts[1]
		u, err := url.Parse("http://" + dec[at+1:])
		if err != nil {
			return nil, err
		}
		server = u.Hostname()
		port, _ = strconv.Atoi(u.Port())
	}
	if server == "" || port <= 0 {
		return nil, fmt.Errorf("ss 缺少服务器地址或端口")
	}
	m := map[string]any{
		"name":     name,
		"type":     "ss",
		"server":   server,
		"port":     port,
		"cipher":   method,
		"password": password,
		"udp":      true,
	}
	if pName, pOpts := parseSSPluginQuery(queryPart); pName != "" {
		m["plugin"] = pName
		if len(pOpts) > 0 {
			m["plugin-opts"] = pOpts
		}
	}
	return m, nil
}

func parseVMessURI(raw string, idx int) (map[string]any, error) {
	b64 := strings.TrimSpace(strings.TrimPrefix(raw, "vmess://"))
	dec, err := decodeFlexibleBase64(b64)
	if err != nil {
		return nil, err
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(dec), &obj); err != nil {
		return nil, err
	}
	str := func(k string) string {
		if v, ok := obj[k]; ok && v != nil {
			return strings.TrimSpace(fmt.Sprint(v))
		}
		return ""
	}
	port, _ := strconv.Atoi(str("port"))
	if port <= 0 {
		port = 443
	}
	aid, _ := strconv.Atoi(str("aid"))
	name := str("ps")
	if name == "" {
		name = fmt.Sprintf("自建-VMess-%d", idx)
	}
	m := map[string]any{
		"name":    name,
		"type":    "vmess",
		"server":  str("add"),
		"port":    port,
		"uuid":    str("id"),
		"alterId": aid,
		"cipher":  firstNonEmpty(str("scy"), "auto"),
		"udp":     true,
	}
	if strings.EqualFold(str("tls"), "tls") {
		m["tls"] = true
		if sni := firstNonEmpty(str("sni"), str("host")); sni != "" {
			m["servername"] = sni
		}
	}
	if netType := strings.ToLower(str("net")); netType == "ws" {
		m["network"] = "ws"
		ws := map[string]any{}
		if p := str("path"); p != "" {
			ws["path"] = p
		}
		if h := str("host"); h != "" {
			ws["headers"] = map[string]any{"Host": h}
		}
		if len(ws) > 0 {
			m["ws-opts"] = ws
		}
	}
	return m, nil
}

func parseHysteria2URI(raw string, idx int) (map[string]any, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port <= 0 {
		port = 443
	}
	name, _ := url.QueryUnescape(strings.TrimSpace(u.Fragment))
	if name == "" {
		name = fmt.Sprintf("自建-HY2-%d", idx)
	}
	q := u.Query()
	m := map[string]any{
		"name":     name,
		"type":     "hysteria2",
		"server":   u.Hostname(),
		"port":     port,
		"password": u.User.Username(),
	}
	if sni := q.Get("sni"); sni != "" {
		m["sni"] = sni
	}
	if q.Get("insecure") == "1" || strings.EqualFold(q.Get("insecure"), "true") {
		m["skip-cert-verify"] = true
	}
	if obfs := q.Get("obfs"); obfs != "" {
		m["obfs"] = obfs
		if op := q.Get("obfs-password"); op != "" {
			m["obfs-password"] = op
		}
	}
	return m, nil
}

func decodeFlexibleBase64(s string) (string, error) {
	clean := strings.TrimSpace(s)
	if b, err := base64.StdEncoding.DecodeString(clean); err == nil {
		return string(b), nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(clean); err == nil {
		return string(b), nil
	}
	if b, err := base64.RawURLEncoding.DecodeString(clean); err == nil {
		return string(b), nil
	}
	b, err := base64.URLEncoding.DecodeString(clean)
	return string(b), err
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func finalizeParsedCustomProxies(list []map[string]any) ([]parsedCustomProxy, error) {
	out := make([]parsedCustomProxy, 0, len(list))
	seen := map[string]bool{}
	for i, item := range list {
		name, _ := item["name"].(string)
		name = strings.TrimSpace(name)
		ptype, _ := item["type"].(string)
		ptype = strings.TrimSpace(ptype)
		if name == "" {
			return nil, fmt.Errorf("自建节点[%d] 缺少 name 字段", i)
		}
		if ptype == "" {
			return nil, fmt.Errorf("自建节点 %q 缺少 type 字段", name)
		}
		if seen[strings.ToLower(name)] {
			return nil, fmt.Errorf("自建节点重名: %q", name)
		}
		seen[strings.ToLower(name)] = true
		srv, _ := item["server"].(string)
		out = append(out, parsedCustomProxy{
			Name:   name,
			Server: strings.TrimSpace(srv),
			RawMap: item,
		})
	}
	return out, nil
}

// ApplyCustomOverlayToYAML merges self-hosted nodes, Fail-Closed AI strict group,
// direct protection hosts, and custom high-priority rules onto a base Clash/Mihomo YAML.
func ApplyCustomOverlayToYAML(yamlText string, rawOverlay CustomOverlay) (string, error) {
	overlay := normalizeOverlay(rawOverlay)
	if !overlay.Enabled {
		return yamlText, nil
	}

	customProxies, err := ParseCustomProxiesYAML(overlay.CustomProxiesYAML)
	if err != nil {
		return yamlText, err
	}

	result := strings.ReplaceAll(strings.ReplaceAll(yamlText, "\r\n", "\n"), "\r", "\n")

	proxyNames := make([]string, 0, len(customProxies))
	directHosts := append([]string(nil), overlay.DirectDomains...)
	for _, p := range customProxies {
		proxyNames = append(proxyNames, p.Name)
		if p.Server != "" {
			if _, ipErr := netip.ParseAddr(p.Server); ipErr != nil {
				directHosts = append(directHosts, p.Server)
			}
		}
	}
	directHosts = normalizeDomainList(directHosts)

	// 1. Inject custom self-hosted proxies into `proxies:`
	if len(customProxies) > 0 {
		result, err = injectCustomProxiesIntoYAML(result, customProxies)
		if err != nil {
			return yamlText, err
		}
	}

	// 2. Inject dedicated Fail-Closed self-hosted / AI group into `proxy-groups:`
	needGroup := overlay.AIStrictEnabled || len(proxyNames) > 0
	if needGroup {
		groupMembers := append([]string(nil), proxyNames...)
		if len(groupMembers) == 0 {
			if overlay.FailClosed {
				// Hard fail-closed kill-switch: never leak AI traffic to DIRECT or commercial nodes.
				groupMembers = []string{"REJECT"}
			} else {
				groupMembers = []string{"DIRECT"}
			}
		} else if !overlay.FailClosed {
			groupMembers = append(groupMembers, "DIRECT")
		}
		result = injectProxyGroupIntoYAML(result, overlay.SelfHostedGroupName, groupMembers)
	}

	// 3. Protect self-hosted server hosts & direct domains in DNS (fake-ip-filter + public nameserver-policy)
	if len(directHosts) > 0 {
		result = ensureDirectHostsInDNS(result, directHosts)
	}

	// 4. Prepend direct host rules, custom rules, and Fail-Closed AI strict rules at top of `rules:`
	prependRules := []string{}
	for _, h := range directHosts {
		prependRules = append(prependRules, fmt.Sprintf("DOMAIN,%s,DIRECT", h))
	}
	prependRules = append(prependRules, overlay.CustomRules...)
	if overlay.AIStrictEnabled {
		presetDomains, presetKeywords := expandAIProviders(overlay.AIProviders)
		allDomains := normalizeDomainList(append(presetDomains, overlay.AIDomains...))
		allKeywords := append([]string(nil), presetKeywords...)
		allKeywords = append(allKeywords, overlay.AIKeywords...)
		for _, dom := range allDomains {
			prependRules = append(prependRules, fmt.Sprintf("DOMAIN-SUFFIX,%s,%s", dom, overlay.SelfHostedGroupName))
		}
		seenKw := map[string]bool{}
		for _, kw := range allKeywords {
			c := strings.ToLower(strings.TrimSpace(kw))
			if c != "" && !seenKw[c] {
				seenKw[c] = true
				prependRules = append(prependRules, fmt.Sprintf("DOMAIN-KEYWORD,%s,%s", c, overlay.SelfHostedGroupName))
			}
		}
	}
	if len(prependRules) > 0 {
		result = prependOverlayRules(result, prependRules)
	}

	return result, nil
}

func injectCustomProxiesIntoYAML(yamlText string, customProxies []parsedCustomProxy) (string, error) {
	lines := strings.Split(yamlText, "\n")
	headerIdx := -1
	endIdx := len(lines)
	listIndent := ""

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if headerIdx < 0 {
			if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed == "proxies:" {
				headerIdx = i
			}
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, "-") {
			endIdx = i
			break
		}
		if listIndent == "" && strings.HasPrefix(trimmed, "- ") {
			dashIdx := strings.IndexByte(line, '-')
			if dashIdx > 0 {
				listIndent = line[:dashIdx]
			}
		}
	}

	rawSlice := make([]map[string]any, 0, len(customProxies))
	dropNames := map[string]bool{}
	for _, p := range customProxies {
		rawSlice = append(rawSlice, p.RawMap)
		dropNames[strings.ToLower(p.Name)] = true
	}
	marshaled, err := yaml.Marshal(rawSlice)
	if err != nil {
		return yamlText, fmt.Errorf("序列化自建节点失败: %w", err)
	}
	builtLines := []string{}
	for _, l := range strings.Split(strings.TrimRight(string(marshaled), "\n"), "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		builtLines = append(builtLines, listIndent+l)
	}

	if headerIdx < 0 {
		out := append([]string(nil), lines...)
		out = append(out, "", "proxies:")
		out = append(out, builtLines...)
		return strings.Join(out, "\n"), nil
	}

	sectionLines := lines[headerIdx+1 : endIdx]
	keptSection := stripNamedSequenceBlocks(sectionLines, dropNames)
	out := make([]string, 0, len(lines)+len(builtLines))
	out = append(out, lines[:headerIdx+1]...)
	out = append(out, builtLines...)
	out = append(out, keptSection...)
	out = append(out, lines[endIdx:]...)
	return strings.Join(out, "\n"), nil
}

func injectProxyGroupIntoYAML(yamlText, groupName string, members []string) string {
	lines := strings.Split(yamlText, "\n")
	headerIdx := -1
	endIdx := len(lines)
	listIndent := ""

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if headerIdx < 0 {
			if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed == "proxy-groups:" {
				headerIdx = i
			}
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, "-") {
			endIdx = i
			break
		}
		if listIndent == "" && strings.HasPrefix(trimmed, "- ") {
			dashIdx := strings.IndexByte(line, '-')
			if dashIdx > 0 {
				listIndent = line[:dashIdx]
			}
		}
	}

	fieldIndent := listIndent + "  "
	itemIndent := fieldIndent + "  "
	built := []string{
		fmt.Sprintf("%s- name: %s", listIndent, quoteIfNeeded(groupName)),
		fmt.Sprintf("%stype: select", fieldIndent),
		fmt.Sprintf("%sproxies:", fieldIndent),
	}
	for _, m := range members {
		built = append(built, fmt.Sprintf("%s- %s", itemIndent, quoteIfNeeded(m)))
	}

	if headerIdx < 0 {
		out := append([]string(nil), lines...)
		out = append(out, "", "proxy-groups:")
		out = append(out, built...)
		return strings.Join(out, "\n")
	}

	sectionLines := lines[headerIdx+1 : endIdx]
	kept := stripNamedSequenceBlocks(sectionLines, map[string]bool{strings.ToLower(groupName): true})
	out := make([]string, 0, len(lines)+len(built))
	out = append(out, lines[:headerIdx+1]...)
	out = append(out, built...)
	out = append(out, kept...)
	out = append(out, lines[endIdx:]...)
	return strings.Join(out, "\n")
}

func stripNamedSequenceBlocks(sectionLines []string, dropNamesLower map[string]bool) []string {
	var blocks [][]string
	var current []string
	baseDashIndent := -1
	for _, line := range sectionLines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "- ") {
			indent := strings.IndexByte(line, '-')
			if baseDashIndent < 0 {
				baseDashIndent = indent
			}
			if indent == baseDashIndent {
				if len(current) > 0 {
					blocks = append(blocks, current)
				}
				current = []string{line}
				continue
			}
		}
		current = append(current, line)
	}
	if len(current) > 0 {
		blocks = append(blocks, current)
	}

	kept := make([]string, 0, len(sectionLines))
	for _, blk := range blocks {
		drop := false
		for _, l := range blk {
			t := strings.TrimSpace(l)
			if strings.HasPrefix(t, "- name:") || strings.HasPrefix(t, "name:") {
				var raw string
				if strings.HasPrefix(t, "- name:") {
					raw = strings.TrimSpace(t[7:])
				} else {
					raw = strings.TrimSpace(t[5:])
				}
				if dropNamesLower[strings.ToLower(stripQuotes(raw))] {
					drop = true
					break
				}
			}
		}
		if !drop {
			kept = append(kept, blk...)
		}
	}
	return kept
}

func ensureDirectHostsInDNS(yamlText string, hosts []string) string {
	lines := strings.Split(yamlText, "\n")
	dnsStart := -1
	dnsEnd := len(lines)
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if dnsStart < 0 {
			if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed == "dns:" {
				dnsStart = i
			}
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, "-") {
			dnsEnd = i
			break
		}
	}
	if dnsStart < 0 {
		return yamlText
	}

	dnsSectionLines := lines[dnsStart:dnsEnd]
	dnsTextLower := strings.ToLower(strings.Join(dnsSectionLines, "\n"))
	dnsChildIndent := detectSectionChildIndent(dnsSectionLines, "  ")
	hasFilterHeader := hasTrimmedLine(dnsSectionLines, "fake-ip-filter:")
	filterPrefix := dnsChildIndent + "  - "
	if hasFilterHeader {
		filterPrefix = detectSequenceItemPrefix(dnsSectionLines, "fake-ip-filter:", dnsChildIndent+"  - ")
	}

	extraFilters := []string{}
	for _, h := range hosts {
		if !hasFilterEntry(dnsTextLower, h) {
			extraFilters = append(extraFilters, filterPrefix+h)
		}
	}
	if len(extraFilters) == 0 {
		return yamlText
	}

	out := make([]string, 0, len(lines)+len(extraFilters)+1)
	inserted := false
	for i, line := range lines {
		out = append(out, line)
		if i > dnsStart && i < dnsEnd && !inserted && strings.TrimSpace(line) == "fake-ip-filter:" {
			out = append(out, extraFilters...)
			inserted = true
		}
		if i == dnsEnd-1 && !inserted {
			out = append(out, dnsChildIndent+"fake-ip-filter:")
			out = append(out, extraFilters...)
		}
	}
	return strings.Join(out, "\n")
}

func prependOverlayRules(yamlText string, newRules []string) string {
	lines := strings.Split(yamlText, "\n")
	rulesHeader, rulesEnd, rulePrefix := findRulesSection(lines)
	if rulesHeader < 0 {
		out := append([]string(nil), lines...)
		out = append(out, "", "rules:")
		for _, r := range newRules {
			out = append(out, "  - "+r)
		}
		return strings.Join(out, "\n")
	}

	existing := map[string]bool{}
	for i := rulesHeader + 1; i < rulesEnd; i++ {
		t := strings.TrimSpace(lines[i])
		if strings.HasPrefix(t, "- ") {
			existing[strings.ToLower(stripQuotes(strings.TrimSpace(t[2:])))] = true
		}
	}

	toInsert := []string{}
	for _, r := range newRules {
		key := strings.ToLower(strings.TrimSpace(r))
		if key != "" && !existing[key] {
			existing[key] = true
			toInsert = append(toInsert, rulePrefix+r)
		}
	}
	if len(toInsert) == 0 {
		return yamlText
	}

	out := make([]string, 0, len(lines)+len(toInsert))
	out = append(out, lines[:rulesHeader+1]...)
	out = append(out, toInsert...)
	out = append(out, lines[rulesHeader+1:]...)
	return strings.Join(out, "\n")
}

// ConfigBackupBundle is the portable cross-platform sync/backup bundle (Windows <-> HarmonyOS).
type ConfigBackupBundle struct {
	FormatVersion  int                   `json:"formatVersion"`
	ExportedAt     string                `json:"exportedAt"`
	SourcePlatform string                `json:"sourcePlatform"`
	Sanitized      bool                  `json:"sanitized"`
	Overlay        CustomOverlay         `json:"overlay"`
	TailscalePrefs TailscaleNativePrefs  `json:"tailscalePrefs"`
	Profiles       []BackupProfileRecord `json:"profiles"`
}

type BackupProfileRecord struct {
	Name      string `json:"name"`
	URL       string `json:"url,omitempty"`
	FetchMode string `json:"fetchMode,omitempty"`
	UserAgent string `json:"userAgent,omitempty"`
	Content   string `json:"content,omitempty"`
}

var (
	secretFieldRe = regexp.MustCompile(`(?i)(\b(?:password|uuid|secret|public-key|short-id|auth-key)\s*:\s*)([^\s,#]+)`)
	urlTokenRe    = regexp.MustCompile(`(?i)([?&](?:token|key|pass|password|secret|auth)=)([^&\s]+)`)
)

func sanitizeYAMLSecrets(text string) string {
	return secretFieldRe.ReplaceAllString(text, `${1}<REDACTED>`)
}

func sanitizeURLSecrets(u string) string {
	return urlTokenRe.ReplaceAllString(u, `${1}<REDACTED>`)
}

func BuildBackupBundle(store *DataStore, sanitize bool) ConfigBackupBundle {
	overlay := store.LoadOverlay()
	tsPrefs := store.LoadTailscalePrefs()
	if sanitize {
		overlay.CustomProxiesYAML = sanitizeYAMLSecrets(overlay.CustomProxiesYAML)
		tsPrefs.AuthKey = ""
	}
	profiles := store.ListProfiles()
	records := make([]BackupProfileRecord, 0, len(profiles))
	for _, p := range profiles {
		rec := BackupProfileRecord{
			Name:      p.Name,
			URL:       p.URL,
			FetchMode: p.FetchMode,
			UserAgent: p.UserAgent,
		}
		if sanitize {
			rec.URL = sanitizeURLSecrets(rec.URL)
		} else if p.URL == "" {
			if _, content, err := store.GetProfile(p.ID); err == nil {
				rec.Content = content
			}
		}
		records = append(records, rec)
	}
	return ConfigBackupBundle{
		FormatVersion:  1,
		ExportedAt:     time.Now().Format(time.RFC3339),
		SourcePlatform: "windows-desktop",
		Sanitized:      sanitize,
		Overlay:        overlay,
		TailscalePrefs: tsPrefs,
		Profiles:       records,
	}
}
