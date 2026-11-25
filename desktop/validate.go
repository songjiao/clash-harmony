package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/config"
)

type ValidationResult struct {
	OK           bool     `json:"ok"`
	Line         int      `json:"line"`
	Error        string   `json:"error"`
	Warnings     []string `json:"warnings"`
	ProxyCount   int      `json:"proxyCount"`
	GroupCount   int      `json:"groupCount"`
	RuleCount    int      `json:"ruleCount"`
	HasTailscale bool     `json:"hasTailscale"`
	DNSMode      string   `json:"dnsMode"`
}

var yamlLineRegexp = regexp.MustCompile(`line\s+(\d+)`)

func extractErrorLine(msg string) int {
	m := yamlLineRegexp.FindStringSubmatch(msg)
	if len(m) < 2 {
		return 0
	}
	n, err := strconv.Atoi(m[1])
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func validateConfigYAML(yamlText string) ValidationResult {
	res := ValidationResult{
		OK:       false,
		Warnings: []string{},
	}

	trimmed := strings.TrimSpace(yamlText)
	if trimmed == "" {
		res.Error = "配置内容为空"
		return res
	}

	rawCfg, err := config.UnmarshalRawConfig([]byte(yamlText))
	if err != nil {
		res.Error = err.Error()
		res.Line = extractErrorLine(res.Error)
		return res
	}

	knownTargets := map[string]bool{
		"DIRECT":      true,
		"REJECT":      true,
		"REJECT-DROP": true,
		"PASS":        true,
		"COMPATIBLE":  true,
		"GLOBAL":      true,
	}

	proxyNames := map[string]bool{}
	for i, item := range rawCfg.Proxy {
		name, _ := item["name"].(string)
		name = strings.TrimSpace(name)
		ptype, _ := item["type"].(string)
		ptype = strings.TrimSpace(strings.ToLower(ptype))
		if name == "" {
			res.Error = fmt.Sprintf("proxies[%d] 缺少 name 字段", i)
			return res
		}
		if ptype == "" {
			res.Error = fmt.Sprintf("代理节点 %q 缺少 type 字段", name)
			return res
		}
		if proxyNames[name] {
			res.Error = fmt.Sprintf("代理节点重名: %q", name)
			return res
		}
		proxyNames[name] = true
		knownTargets[name] = true
		if ptype == "tailscale" {
			res.HasTailscale = true
		}
	}

	hasProviders := len(rawCfg.ProxyProvider) > 0

	groupNames := map[string]bool{}
	for i, item := range rawCfg.ProxyGroup {
		name, _ := item["name"].(string)
		name = strings.TrimSpace(name)
		gtype, _ := item["type"].(string)
		gtype = strings.TrimSpace(gtype)
		if name == "" {
			res.Error = fmt.Sprintf("proxy-groups[%d] 缺少 name 字段", i)
			return res
		}
		if gtype == "" {
			res.Error = fmt.Sprintf("策略组 %q 缺少 type 字段", name)
			return res
		}
		if groupNames[name] {
			res.Error = fmt.Sprintf("策略组重名: %q", name)
			return res
		}
		if proxyNames[name] {
			res.Error = fmt.Sprintf("策略组与代理节点重名: %q", name)
			return res
		}
		groupNames[name] = true
		knownTargets[name] = true
	}

	for _, item := range rawCfg.ProxyGroup {
		gname, _ := item["name"].(string)
		rawProxies, hasList := item["proxies"]
		_, hasUse := item["use"]
		if !hasList && !hasUse {
			res.Error = fmt.Sprintf("策略组 %q 缺少 proxies 或 use 列表", gname)
			return res
		}
		if list, ok := rawProxies.([]any); ok {
			for _, ref := range list {
				refName, _ := ref.(string)
				refName = strings.TrimSpace(refName)
				if refName == "" {
					continue
				}
				if !knownTargets[refName] && !hasProviders {
					if strings.EqualFold(refName, "Tailscale") {
						res.Warnings = append(res.Warnings, fmt.Sprintf("策略组 %q 引用了 Tailscale（将由内置 Tailscale 自动注入）", gname))
					} else {
						res.Error = fmt.Sprintf("策略组 %q 引用了不存在的节点/策略组: %q", gname, refName)
						return res
					}
				}
			}
		}
	}

	for i, rawRule := range rawCfg.Rule {
		rule := strings.TrimSpace(rawRule)
		if rule == "" {
			continue
		}
		target := extractRuleTarget(rule)
		if target == "" {
			res.Error = fmt.Sprintf("第 %d 条规则格式无效: %s", i+1, rule)
			return res
		}
		if !knownTargets[target] && !hasProviders {
			if strings.EqualFold(target, "Tailscale") {
				continue
			}
			res.Warnings = append(res.Warnings, fmt.Sprintf("第 %d 条规则目标 %q 未在 proxies/proxy-groups 中定义", i+1, target))
		}
	}

	res.ProxyCount = len(rawCfg.Proxy)
	res.GroupCount = len(rawCfg.ProxyGroup)
	res.RuleCount = len(rawCfg.Rule)
	res.DNSMode = rawCfg.DNS.EnhancedMode.String()
	if res.DNSMode == "" {
		res.DNSMode = "normal"
	}
	res.OK = true
	return res
}

func extractRuleTarget(rule string) string {
	upper := strings.ToUpper(rule)
	if strings.HasPrefix(upper, "AND,") || strings.HasPrefix(upper, "OR,") || strings.HasPrefix(upper, "NOT,") {
		lastComma := strings.LastIndex(rule, ",")
		if lastComma <= 0 || lastComma+1 >= len(rule) {
			return ""
		}
		return strings.TrimSpace(rule[lastComma+1:])
	}
	parts := strings.Split(rule, ",")
	if len(parts) < 2 {
		return ""
	}
	ruleType := strings.ToUpper(strings.TrimSpace(parts[0]))
	if ruleType == "MATCH" {
		return strings.TrimSpace(parts[1])
	}
	if len(parts) < 3 {
		return ""
	}
	return strings.TrimSpace(parts[2])
}
