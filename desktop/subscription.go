package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"unicode/utf8"

	"go.yaml.in/yaml/v3"
)

// NormalizeFetchedSubscription inspects raw HTTP subscription response bodies and
// normalizes them into valid Clash/Mihomo YAML before overlay merging:
//   - Strips UTF-8 BOM and normalizes CRLF/CR line endings.
//   - Passes valid Clash/Mihomo YAML through directly.
//   - Decodes Base64-encoded Clash YAML or Base64-encoded share-URI lists (ss/vmess/vless/trojan/hy2).
//   - Converts plain-text share-URI lists to Clash/Mihomo YAML.
//   - Detects HTML, JSON error bodies, and Surge/Shadowrocket INI (.conf) early with clear diagnostics.
func NormalizeFetchedSubscription(raw string) (yamlText string, converted bool, err error) {
	text := strings.TrimPrefix(raw, "\xef\xbb\xbf")
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	text = strings.TrimSpace(text)
	if text == "" {
		return "", false, fmt.Errorf("订阅返回内容为空")
	}

	low := strings.ToLower(text)
	if strings.HasPrefix(low, "<!doctype") ||
		strings.HasPrefix(low, "<html") ||
		strings.HasPrefix(low, "<head") ||
		strings.HasPrefix(low, "<body") ||
		strings.HasPrefix(low, "<script") {
		return "", false, fmt.Errorf("订阅返回的是 HTML 页面而非 Clash YAML（可能是链接过期、需要验证或 User-Agent 不匹配），响应开头: %q", safePreviewSnippet(text, 120))
	}

	if strings.HasPrefix(text, "{") {
		var obj map[string]any
		if jErr := json.Unmarshal([]byte(text), &obj); jErr == nil && obj != nil {
			if _, hasProxies := obj["proxies"]; !hasProxies {
				for _, k := range []string{"message", "msg", "error", "detail"} {
					if v, ok := obj[k]; ok && v != nil && strings.TrimSpace(fmt.Sprint(v)) != "" {
						return "", false, fmt.Errorf("订阅返回 JSON 错误而非 Clash YAML: %s", safePreviewSnippet(fmt.Sprint(v), 120))
					}
				}
				return "", false, fmt.Errorf("订阅返回的是 JSON 而非 Clash YAML，响应开头: %q", safePreviewSnippet(text, 120))
			}
		}
	}

	if looksLikeClashYAML(text) {
		val := validateConfigYAML(text)
		if val.OK {
			return text, false, nil
		}
		return "", false, fmt.Errorf("原始订阅 YAML 语法异常 (第 %d 行): %s%s", val.Line, val.Error, formatLineSnippetSuffix(text, val.Line))
	}

	// Try Base64 decoding (both Base64-encoded Clash YAML and Base64-encoded node URI lists).
	compactB64 := strings.NewReplacer("\n", "", "\r", "", " ", "", "\t", "").Replace(text)
	if len(compactB64) >= 16 && looksLikeBase64String(compactB64) {
		if decoded, dErr := decodeFlexibleBase64(compactB64); dErr == nil && utf8.ValidString(decoded) {
			decClean := strings.TrimSpace(strings.TrimPrefix(decoded, "\xef\xbb\xbf"))
			decClean = strings.ReplaceAll(strings.ReplaceAll(decClean, "\r\n", "\n"), "\r", "\n")
			if looksLikeClashYAML(decClean) {
				val := validateConfigYAML(decClean)
				if val.OK {
					return decClean, true, nil
				}
				return "", false, fmt.Errorf("Base64 解码后的订阅 YAML 语法异常 (第 %d 行): %s%s", val.Line, val.Error, formatLineSnippetSuffix(decClean, val.Line))
			}
			if convertedYAML, count, cErr := buildClashYAMLFromShareURIs(decClean); cErr == nil && count > 0 {
				return convertedYAML, true, nil
			}
		}
	}

	// Try plain-text share URI list (vless://, trojan://, ss://, vmess://, hy2://).
	if convertedYAML, count, cErr := buildClashYAMLFromShareURIs(text); cErr == nil && count > 0 {
		return convertedYAML, true, nil
	}

	if looksLikeSurgeINI(text) {
		return "", false, fmt.Errorf("订阅返回的是 Surge/Shadowrocket INI (.conf) 格式而非 Clash YAML（响应开头: %q）；请确认订阅链接带 Clash 格式参数或调整 User-Agent", safePreviewSnippet(text, 120))
	}

	return "", false, fmt.Errorf("订阅返回内容不是有效的 Clash YAML 或 Base64 节点列表（响应开头: %q）", safePreviewSnippet(text, 120))
}

func looksLikeClashYAML(text string) bool {
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
			continue
		}
		t := strings.TrimSpace(line)
		if t == "proxies:" || strings.HasPrefix(t, "proxies: ") ||
			t == "proxy-groups:" || strings.HasPrefix(t, "proxy-groups: ") ||
			t == "proxy-providers:" || strings.HasPrefix(t, "proxy-providers: ") ||
			t == "rules:" || strings.HasPrefix(t, "rules: ") {
			return true
		}
	}
	return false
}

func looksLikeSurgeINI(text string) bool {
	for i, line := range strings.Split(text, "\n") {
		if i > 40 {
			break
		}
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "#!MANAGED-CONFIG") ||
			strings.EqualFold(t, "[General]") ||
			strings.EqualFold(t, "[Proxy]") ||
			strings.EqualFold(t, "[Proxy Group]") {
			return true
		}
	}
	return false
}

func looksLikeBase64String(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '+' || c == '/' || c == '-' || c == '_' || c == '=' {
			continue
		}
		return false
	}
	return true
}

func buildClashYAMLFromShareURIs(text string) (string, int, error) {
	proxies := []map[string]any{}
	usedNames := map[string]int{}
	idx := 0

	for _, rawLine := range strings.Split(text, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		low := strings.ToLower(line)
		var (
			m   map[string]any
			err error
		)
		switch {
		case strings.HasPrefix(low, "vless://"):
			idx++
			m, err = parseVLESSURI(line, idx)
		case strings.HasPrefix(low, "trojan://"):
			idx++
			m, err = parseTrojanURI(line, idx)
		case strings.HasPrefix(low, "ss://"):
			idx++
			m, err = parseSSURI(line, idx)
		case strings.HasPrefix(low, "vmess://"):
			idx++
			m, err = parseVMessURI(line, idx)
		case strings.HasPrefix(low, "hy2://"), strings.HasPrefix(low, "hysteria2://"):
			idx++
			m, err = parseHysteria2URI(line, idx)
		default:
			continue
		}
		if err != nil || m == nil {
			continue
		}
		baseName := strings.TrimSpace(fmt.Sprint(m["name"]))
		if baseName == "" {
			baseName = fmt.Sprintf("Node-%d", idx)
		}
		key := strings.ToLower(baseName)
		usedNames[key]++
		if usedNames[key] > 1 {
			baseName = fmt.Sprintf("%s (%d)", baseName, usedNames[key])
		}
		m["name"] = baseName
		proxies = append(proxies, m)
	}

	if len(proxies) == 0 {
		return "", 0, fmt.Errorf("未识别到可用节点链接")
	}

	names := make([]string, 0, len(proxies))
	for _, p := range proxies {
		names = append(names, fmt.Sprint(p["name"]))
	}
	selectList := append([]string{"♻️ 自动选择"}, names...)

	doc := map[string]any{
		"mode":    "rule",
		"proxies": proxies,
		"proxy-groups": []map[string]any{
			{
				"name":    "🚀 节点选择",
				"type":    "select",
				"proxies": selectList,
			},
			{
				"name":      "♻️ 自动选择",
				"type":      "url-test",
				"url":       "https://www.gstatic.com/generate_204",
				"interval":  300,
				"tolerance": 50,
				"proxies":   names,
			},
		},
		"rules": []string{
			"IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
			"IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
			"IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
			"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
			"GEOIP,CN,DIRECT",
			"MATCH,🚀 节点选择",
		},
	}

	rawYAML, err := yaml.Marshal(doc)
	if err != nil {
		return "", 0, err
	}
	return string(rawYAML), len(proxies), nil
}

func safePreviewSnippet(text string, maxRunes int) string {
	s := sanitizeYAMLSecrets(sanitizeURLSecrets(text))
	s = strings.NewReplacer("\r", " ", "\n", " ", "\t", " ").Replace(s)
	s = strings.TrimSpace(s)
	runes := []rune(s)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes]) + "..."
	}
	return s
}

func formatLineSnippetSuffix(text string, lineNum int) string {
	if lineNum <= 0 {
		return ""
	}
	lines := strings.Split(strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n"), "\n")
	if lineNum > len(lines) {
		return ""
	}
	snippet := safePreviewSnippet(lines[lineNum-1], 100)
	if snippet == "" {
		return ""
	}
	return fmt.Sprintf("（该行: %q）", snippet)
}

func parseSSPluginQuery(query string) (string, map[string]any) {
	if strings.TrimSpace(query) == "" {
		return "", nil
	}
	q, err := url.ParseQuery(query)
	if err != nil {
		return "", nil
	}
	rawPlugin := strings.TrimSpace(q.Get("plugin"))
	if rawPlugin == "" {
		return "", nil
	}
	parts := strings.Split(rawPlugin, ";")
	pName := strings.ToLower(strings.TrimSpace(parts[0]))
	if pName != "simple-obfs" && pName != "obfs-local" {
		return "", nil
	}
	opts := map[string]any{}
	for _, part := range parts[1:] {
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 {
			continue
		}
		k := strings.ToLower(strings.TrimSpace(kv[0]))
		v := strings.TrimSpace(kv[1])
		switch k {
		case "obfs":
			if v != "" {
				opts["mode"] = v
			}
		case "obfs-host":
			if v != "" {
				opts["host"] = v
			}
		}
	}
	return "obfs", opts
}
