package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// BuildRuntimeYAML produces the final runtime YAML for Desktop Mihomo without custom overlay.
func BuildRuntimeYAML(profileYAML string, tsPrefs TailscaleNativePrefs, settings AppSettings) string {
	out, _ := BuildRuntimeYAMLWithOverlay(profileYAML, defaultCustomOverlay(), tsPrefs, settings)
	return out
}

// BuildRuntimeYAMLWithOverlay produces the final runtime YAML:
// 1. Applies user CustomOverlay (self-hosted nodes, Fail-Closed AI group, custom high-priority rules).
// 2. Applies Tailscale native prefs (proxy block, MagicDNS, SplitDNS nameserver-policy, fake-ip-filter, rules).
// 3. Normalizes managed top-level keys (mixed-port, external-controller, secret, tun, QUIC block, default dns).
func BuildRuntimeYAMLWithOverlay(profileYAML string, overlay CustomOverlay, tsPrefs TailscaleNativePrefs, settings AppSettings) (string, error) {
	merged, err := ApplyCustomOverlayToYAML(profileYAML, overlay)
	if err != nil {
		return "", err
	}
	withTS := ApplyTailscalePrefsToYAML(merged, tsPrefs)
	return normalizeDesktopRuntimeYAML(withTS, settings), nil
}

func normalizeDesktopRuntimeYAML(text string, settings AppSettings) string {
	normalized := strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	if settings.BlockQuic {
		normalized = ensureQuicRejectRuleAtTop(normalized)
	}
	normalized = sanitizeDesktopDNS(normalized)
	ipv6Enabled := isTopLevelKeyTrue(normalized, "ipv6")
	ipv6Disabled := !ipv6Enabled
	if ipv6Disabled {
		normalized = ensureDNSIPv6False(normalized)
	}
	stripped := removeManagedTopLevelKeys(normalized)
	base := strings.TrimRight(stripped, "\n\r \t")

	mixedPort := settings.MixedPort
	if mixedPort <= 0 || mixedPort > 65535 {
		mixedPort = defaultMixedPort
	}
	ctlAddr := strings.TrimSpace(settings.ControllerAddr)
	if ctlAddr == "" {
		ctlAddr = defaultControllerAddr
	}
	tunStack := normalizeTunStack(settings.TunStack)
	strictRouteStr := "false"
	if settings.StrictRoute {
		strictRouteStr = "true"
	}

	managed := []string{
		fmt.Sprintf("mixed-port: %d", mixedPort),
	}
	if !hasTopLevelKey(base, "allow-lan") {
		managed = append(managed, "allow-lan: false")
	}
	if !hasTopLevelKey(base, "mode") {
		managed = append(managed, "mode: rule")
	}
	if !hasTopLevelKey(base, "log-level") {
		managed = append(managed, "log-level: info")
	}
	if !hasTopLevelKey(base, "ipv6") {
		managed = append(managed, "ipv6: false")
	}
	managed = append(managed,
		fmt.Sprintf("external-controller: %s", ctlAddr),
		`secret: ""`,
	)

	sections := []string{base, strings.Join(managed, "\n")}

	// Enable TLS/HTTP/QUIC SNI sniffing by default so raw-IP connections (e.g. agy.exe -> 172.217.x.x:443)
	// still extract their real hostname and accurately match AI Strict / Tailscale / domain rules.
	if !hasTopLevelKey(base, "sniffer") {
		defaultSniffer := []string{
			"sniffer:",
			"  enable: true",
			"  force-dns-mapping: true",
			"  parse-pure-ip: true",
			"  override-destination: true",
			"  sniff:",
			"    HTTP:",
			"      ports: [80, 8080-8880]",
			"      override-destination: true",
			"    TLS:",
			"      ports: [443, 8443]",
			"    QUIC:",
			"      ports: [443, 8443]",
			"  skip-domain:",
			"    - Mijia Cloud",
			"    - +.push.apple.com",
		}
		sections = append(sections, strings.Join(defaultSniffer, "\n"))
	}

	if !hasTopLevelKey(base, "dns") {
		defaultDNS := []string{
			"dns:",
			"  enable: true",
			"  ipv6: false",
			"  listen: 127.0.0.1:1053",
			"  enhanced-mode: fake-ip",
			"  fake-ip-range: 198.18.0.1/16",
			"  default-nameserver:",
			"    - 223.5.5.5",
			"    - 119.29.29.29",
			"  nameserver:",
			"    - 223.5.5.5",
			"    - 119.29.29.29",
		}
		sections = append(sections, strings.Join(defaultDNS, "\n"))
	}

	if settings.TunMode {
		tunBlock := []string{
			"tun:",
			"  enable: true",
			fmt.Sprintf("  stack: %s", tunStack),
			"  device: ClashHarmony",
			"  mtu: 1500",
			"  auto-route: true",
			"  auto-detect-interface: true",
			fmt.Sprintf("  strict-route: %s", strictRouteStr),
			"  endpoint-independent-nat: true",
			// Explicit non-.0 TUN local address so subscriptions with `fake-ip-range: 198.18.0.0/15`
			// (like BitzNet) never cause Windows Wintun to bind the illegal `.0` network IP 198.18.0.0!
			"  inet4-address:",
			"    - 198.18.0.1/30",
			"  dns-hijack:",
			"    - any:53",
			"    - tcp://any:53",
		}
		if ipv6Disabled {
			// Clear default Mihomo Inet6Address so Windows strict-route WFP blocks IPv6 leaks cleanly
			// instead of letting Go/CLI clients leak AAAA connections over physical WLAN IPv6.
			tunBlock = append(tunBlock, "  inet6-address: []")
		} else {
			tunBlock = append(tunBlock,
				"    - '[::]:53'",
				"    - 'tcp://[::]:53'",
			)
		}
		sections = append(sections, strings.Join(tunBlock, "\n"))
	} else {
		sections = append(sections, "tun:\n  enable: false")
	}

	return strings.Join(sections, "\n\n") + "\n"
}

func isTopLevelKeyTrue(text, targetKey string) bool {
	for _, line := range strings.Split(text, "\n") {
		if !isManagedTopLevelLine(line, []string{targetKey}) {
			continue
		}
		idx := strings.IndexByte(line, ':')
		val := strings.ToLower(strings.TrimSpace(stripQuotes(strings.TrimSpace(line[idx+1:]))))
		return val == "true"
	}
	return false
}

func isTopLevelKeyFalse(text, targetKey string) bool {
	for _, line := range strings.Split(text, "\n") {
		if !isManagedTopLevelLine(line, []string{targetKey}) {
			continue
		}
		idx := strings.IndexByte(line, ':')
		val := strings.ToLower(strings.TrimSpace(stripQuotes(strings.TrimSpace(line[idx+1:]))))
		return val == "false"
	}
	return false
}

// sanitizeDesktopDNS fixes two real-world subscription traps (notably BitzNet):
//  1. Removes loopback addresses (127.0.0.1 / localhost / ::1) from `dns.proxy-server-nameserver`,
//     which otherwise query a fake-ip DNS listener (or BitzNet's com.vortex.helper on UDP 7874)
//     and return 198.18.x.x fake-IPs for `controlplane.tailscale.com` & proxy servers!
//  2. Rewrites `dns.listen: 127.0.0.1:7874` -> `127.0.0.1:17874` to avoid UDP port conflict
//     with BitzNet/Vortex background helper (`com.vortex.helper`).
func sanitizeDesktopDNS(yamlText string) string {
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

	isLoopbackEntry := func(s string) bool {
		low := strings.ToLower(strings.TrimSpace(s))
		return strings.Contains(low, "127.0.0.1") ||
			strings.Contains(low, "localhost") ||
			strings.Contains(low, "[::1]") ||
			strings.Contains(low, "0.0.0.0")
	}

	dnsSection := lines[dnsStart:dnsEnd]
	newDNS := make([]string, 0, len(dnsSection))
	for i := 0; i < len(dnsSection); i++ {
		line := dnsSection[i]
		trimmed := strings.TrimSpace(line)

		// Rewrite conflicting listen port 7874 (used by com.vortex.helper / BitzNet)
		if strings.HasPrefix(trimmed, "listen:") {
			val := strings.TrimSpace(stripQuotes(strings.TrimSpace(trimmed[len("listen:"):])))
			if val == "127.0.0.1:7874" || val == "0.0.0.0:7874" || val == ":7874" {
				newDNS = append(newDNS, leadingSpaces(line)+"listen: 127.0.0.1:17874")
				continue
			}
		}

		// Strip loopback entries inside proxy-server-nameserver:
		if trimmed == "proxy-server-nameserver:" {
			headerIndent := len(leadingSpaces(line))
			keptItems := []string{}
			j := i + 1
			for j < len(dnsSection) {
				sub := dnsSection[j]
				subTrim := strings.TrimSpace(sub)
				if subTrim == "" || strings.HasPrefix(subTrim, "#") {
					j++
					continue
				}
				subIndent := len(leadingSpaces(sub))
				if subIndent <= headerIndent && !strings.HasPrefix(subTrim, "- ") {
					break
				}
				if strings.HasPrefix(subTrim, "- ") {
					if !isLoopbackEntry(subTrim[2:]) {
						keptItems = append(keptItems, sub)
					}
					j++
					continue
				}
				break
			}
			if len(keptItems) > 0 {
				newDNS = append(newDNS, line)
				newDNS = append(newDNS, keptItems...)
			}
			i = j - 1
			continue
		}

		newDNS = append(newDNS, line)
	}

	out := make([]string, 0, len(lines))
	out = append(out, lines[:dnsStart]...)
	out = append(out, newDNS...)
	out = append(out, lines[dnsEnd:]...)
	return strings.Join(out, "\n")
}

// ensureDNSIPv6False adds `ipv6: false` inside `dns:` when top-level `ipv6: false` is set,
// preventing Mihomo's DNS resolver from returning AAAA records to dual-stack clients.
func ensureDNSIPv6False(yamlText string) string {
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
	childIndent := ""
	for i := dnsStart + 1; i < dnsEnd; i++ {
		trimmed := strings.TrimSpace(lines[i])
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, "ipv6:") {
			return yamlText
		}
		sp := leadingSpaces(lines[i])
		if len(sp) > 0 && (childIndent == "" || len(sp) < len(childIndent)) {
			childIndent = sp
		}
	}
	if childIndent == "" {
		childIndent = "  "
	}
	out := make([]string, 0, len(lines)+1)
	out = append(out, lines[:dnsStart+1]...)
	out = append(out, childIndent+"ipv6: false")
	out = append(out, lines[dnsStart+1:]...)
	return strings.Join(out, "\n")
}

// ensureQuicRejectRuleAtTop places `AND,((NETWORK,UDP),(DST-PORT,443)),REJECT` near the top of `rules:`
// (after Tailscale / direct controlplane rules, BEFORE Google/Claude/business domain rules)
// and removes any duplicate QUIC reject rule sitting below domain rules.
func ensureQuicRejectRuleAtTop(yamlText string) string {
	lines := strings.Split(yamlText, "\n")
	rulesHeader, rulesEnd, rulePrefix := findRulesSection(lines)
	if rulesHeader < 0 {
		return yamlText
	}

	isQuicReject := func(line string) bool {
		t := strings.TrimSpace(line)
		if !strings.HasPrefix(t, "- ") {
			return false
		}
		compact := strings.ToUpper(strings.ReplaceAll(stripQuotes(strings.TrimSpace(t[2:])), " ", ""))
		return compact == "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT" ||
			compact == "AND,((DST-PORT,443),(NETWORK,UDP)),REJECT" ||
			compact == "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP"
	}

	// Remove existing QUIC reject rules inside rules: so we place a single canonical rule in the right spot.
	cleaned := make([]string, 0, len(lines)+1)
	newRulesEnd := rulesEnd
	for i, line := range lines {
		if i > rulesHeader && i < rulesEnd && isQuicReject(line) {
			newRulesEnd--
			continue
		}
		cleaned = append(cleaned, line)
	}

	// Insert right after initial Tailscale / DERP / node DIRECT rules, before general domain rules.
	insertAfter := rulesHeader
	for i := rulesHeader + 1; i < newRulesEnd; i++ {
		t := strings.TrimSpace(cleaned[i])
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if !strings.HasPrefix(t, "- ") {
			break
		}
		lower := strings.ToLower(stripQuotes(strings.TrimSpace(t[2:])))
		if strings.Contains(lower, "tailscale") ||
			strings.Contains(lower, "ts.net") ||
			strings.Contains(lower, "100.64.0.0/10") ||
			strings.Contains(lower, "fd7a:115c:a1e0::/48") ||
			strings.Contains(lower, "in.sjfarm.cc") ||
			strings.Contains(lower, "q.sjfarm.cc") ||
			strings.Contains(lower, ",direct") {
			// Only skip leading infrastructure/DIRECT rules right at the top of rules:.
			if strings.Contains(lower, "tailscale") ||
				strings.Contains(lower, "ts.net") ||
				strings.Contains(lower, "100.64.0.0/10") ||
				strings.Contains(lower, "fd7a:115c:a1e0::/48") ||
				strings.Contains(lower, "derp.") ||
				strings.Contains(lower, "node.") ||
				strings.Contains(lower, "in.sjfarm.cc") ||
				strings.Contains(lower, "q.sjfarm.cc") {
				insertAfter = i
				continue
			}
		}
		break
	}

	quicLine := rulePrefix + "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"
	out := make([]string, 0, len(cleaned)+1)
	out = append(out, cleaned[:insertAfter+1]...)
	out = append(out, quicLine)
	out = append(out, cleaned[insertAfter+1:]...)
	return strings.Join(out, "\n")
}

func removeManagedTopLevelKeys(text string) string {
	managedKeys := []string{
		"mixed-port",
		"port",
		"socks-port",
		"redir-port",
		"tproxy-port",
		"external-controller",
		"secret",
	}
	managedBlockKeys := []string{
		"tun",
	}
	lines := strings.Split(text, "\n")
	kept := make([]string, 0, len(lines))
	skippingBlock := false
	for _, line := range lines {
		if skippingBlock {
			if !isTopLevelConfigLine(line) {
				continue
			}
			skippingBlock = false
		}
		if isManagedTopLevelLine(line, managedKeys) {
			continue
		}
		if isManagedTopLevelLine(line, managedBlockKeys) {
			skippingBlock = true
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, "\n")
}

func hasTopLevelKey(text, targetKey string) bool {
	for _, line := range strings.Split(text, "\n") {
		if isManagedTopLevelLine(line, []string{targetKey}) {
			return true
		}
	}
	return false
}

func isTopLevelConfigLine(line string) bool {
	if line == "" || strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") || strings.HasPrefix(line, "#") {
		return false
	}
	return strings.IndexByte(line, ':') > 0
}

func isManagedTopLevelLine(line string, keys []string) bool {
	if !isTopLevelConfigLine(line) {
		return false
	}
	idx := strings.IndexByte(line, ':')
	key := strings.TrimSpace(line[:idx])
	for _, k := range keys {
		if key == k {
			return true
		}
	}
	return false
}

// ApplyTailscalePrefsToYAML mirrors HarmonyOS TailscalePrefsService.applyTailscalePrefsToYaml 1:1.
func ApplyTailscalePrefsToYAML(yamlText string, prefs TailscaleNativePrefs) string {
	if !prefs.ManagedByApp {
		return yamlText
	}

	proxyName := strings.TrimSpace(prefs.ProxyName)
	if proxyName == "" {
		proxyName = "Tailscale"
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(yamlText, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(normalized, "\n")

	proxiesHeaderIndex := -1
	proxiesEndIndex := len(lines)
	listIndent := ""

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if proxiesHeaderIndex < 0 {
			if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed == "proxies:" {
				proxiesHeaderIndex = i
			}
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, "-") {
			proxiesEndIndex = i
			break
		}
		if listIndent == "" && strings.HasPrefix(trimmed, "- ") {
			dashIdx := strings.IndexByte(line, '-')
			if dashIdx > 0 {
				listIndent = line[:dashIdx]
			}
		}
	}

	var builtBlock []string
	if prefs.Enabled {
		builtBlock = buildTailscaleProxyBlockLines(prefs, listIndent)
	}

	var outputLines []string
	if proxiesHeaderIndex < 0 {
		outputLines = append(outputLines, lines...)
		if len(builtBlock) > 0 {
			outputLines = append(outputLines, "", "proxies:")
			outputLines = append(outputLines, builtBlock...)
		}
	} else {
		outputLines = append(outputLines, lines[:proxiesHeaderIndex+1]...)
		sectionLines := lines[proxiesHeaderIndex+1 : proxiesEndIndex]
		filteredSection := stripExistingTailscaleProxy(sectionLines, proxyName)
		outputLines = append(outputLines, builtBlock...)
		outputLines = append(outputLines, filteredSection...)
		outputLines = append(outputLines, lines[proxiesEndIndex:]...)
	}

	resultText := strings.Join(outputLines, "\n")
	var activeSplitDomains []string
	if prefs.Enabled && prefs.AutoSyncSplitDNS {
		activeSplitDomains = normalizeDomainList(prefs.SplitDNSDomains)
	}
	if prefs.Enabled && (prefs.AutoInjectMagicDNS || len(activeSplitDomains) > 0) {
		suffix := ""
		if prefs.AutoInjectMagicDNS {
			suffix = prefs.TailnetSuffix
		}
		resultText = ensureTailscaleDNSEntries(resultText, proxyName, suffix, prefs.AutoInjectMagicDNS, activeSplitDomains)
	}
	if prefs.Enabled && len(activeSplitDomains) > 0 {
		resultText = ensureSplitDNSRules(resultText, proxyName, activeSplitDomains)
	}
	if prefs.Enabled && prefs.AutoInjectMagicDNS {
		resultText = ensureTailscaleBaseRules(resultText, proxyName)
	}
	return resultText
}

func buildTailscaleProxyBlockLines(prefs TailscaleNativePrefs, indent string) []string {
	fieldIndent := indent + "  "
	proxyName := strings.TrimSpace(prefs.ProxyName)
	if proxyName == "" {
		proxyName = "Tailscale"
	}
	hostname := strings.TrimSpace(prefs.Hostname)
	if hostname == "" {
		hostname = defaultTailscaleHostname()
	}
	acceptStr := "false"
	if prefs.AcceptRoutes {
		acceptStr = "true"
	}
	block := []string{
		fmt.Sprintf("%s- name: %s", indent, quoteIfNeeded(proxyName)),
		fmt.Sprintf("%stype: tailscale", fieldIndent),
		fmt.Sprintf("%sudp: true", fieldIndent),
		fmt.Sprintf("%shostname: %s", fieldIndent, quoteIfNeeded(hostname)),
		fmt.Sprintf("%sstate-dir: tailscale", fieldIndent),
		fmt.Sprintf("%saccept-routes: %s", fieldIndent, acceptStr),
	}
	if cu := strings.TrimSpace(prefs.ControlURL); cu != "" {
		block = append(block, fmt.Sprintf("%scontrol-url: %s", fieldIndent, quoteIfNeeded(cu)))
	}
	if ak := strings.TrimSpace(prefs.AuthKey); ak != "" {
		block = append(block, fmt.Sprintf("%sauth-key: %s", fieldIndent, quoteIfNeeded(ak)))
	}
	if en := strings.TrimSpace(prefs.ExitNode); en != "" {
		allowLAN := "false"
		if prefs.ExitNodeAllowLAN {
			allowLAN = "true"
		}
		block = append(block,
			fmt.Sprintf("%sexit-node: %s", fieldIndent, quoteIfNeeded(en)),
			fmt.Sprintf("%sexit-node-allow-lan-access: %s", fieldIndent, allowLAN),
		)
	}
	return block
}

func stripExistingTailscaleProxy(sectionLines []string, proxyName string) []string {
	var blocks [][]string
	var current []string
	for _, line := range sectionLines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "- ") {
			if len(current) > 0 {
				blocks = append(blocks, current)
			}
			current = []string{line}
		} else {
			current = append(current, line)
		}
	}
	if len(current) > 0 {
		blocks = append(blocks, current)
	}

	targetLower := strings.ToLower(proxyName)
	var kept []string
	for _, block := range blocks {
		isTS := false
		for _, l := range block {
			t := strings.TrimSpace(l)
			if strings.HasPrefix(t, "type:") && strings.EqualFold(strings.TrimSpace(t[5:]), "tailscale") {
				isTS = true
				break
			}
			if strings.Contains(t, "type: tailscale") {
				isTS = true
				break
			}
			if strings.HasPrefix(t, "- name:") || strings.HasPrefix(t, "name:") {
				var rawVal string
				if strings.HasPrefix(t, "- name:") {
					rawVal = strings.TrimSpace(t[7:])
				} else {
					rawVal = strings.TrimSpace(t[5:])
				}
				if strings.ToLower(stripQuotes(rawVal)) == targetLower {
					isTS = true
					break
				}
			}
		}
		if !isTS {
			kept = append(kept, block...)
		}
	}
	return kept
}

func ensureTailscaleDNSEntries(yamlText, proxyName, tailnetSuffix string, includeMagicDNS bool, splitDomains []string) string {
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
	policyTarget := "tailscale://" + proxyName
	directDNS := detectPrimaryPublicDNS(dnsSectionLines)
	protectedHosts := collectProtectedSubdomains(lines, splitDomains)

	// Detect the actual direct child indentation inside `dns:` (e.g. 2 spaces vs 4 spaces in BitzNet YAML).
	dnsChildIndent := detectSectionChildIndent(dnsSectionLines, "  ")
	hasPolicyHeader := hasTrimmedLine(dnsSectionLines, "nameserver-policy:")
	hasFilterHeader := hasTrimmedLine(dnsSectionLines, "fake-ip-filter:")

	policyIndent := dnsChildIndent + "  "
	if hasPolicyHeader {
		policyIndent = detectMappingChildIndent(dnsSectionLines, "nameserver-policy:", dnsChildIndent+"  ")
	}
	filterItemPrefix := dnsChildIndent + "  - "
	if hasFilterHeader {
		filterItemPrefix = detectSequenceItemPrefix(dnsSectionLines, "fake-ip-filter:", dnsChildIndent+"  - ")
	}

	var extraPolicyLines []string
	if includeMagicDNS {
		if !strings.Contains(dnsTextLower, "+.ts.net:") {
			extraPolicyLines = append(extraPolicyLines, fmt.Sprintf("%s+.ts.net: %s", policyIndent, policyTarget))
		}
		cleanSuffix := normalizeDomain(tailnetSuffix)
		if cleanSuffix != "" && !strings.Contains(dnsTextLower, "+."+cleanSuffix+":") {
			extraPolicyLines = append(extraPolicyLines, fmt.Sprintf("%s+.%s: %s", policyIndent, cleanSuffix, policyTarget))
		}
	}
	for _, dom := range splitDomains {
		if !strings.Contains(dnsTextLower, "+."+dom+":") {
			extraPolicyLines = append(extraPolicyLines, fmt.Sprintf("%s+.%s: %s", policyIndent, dom, policyTarget))
		}
	}
	for _, host := range protectedHosts {
		if !strings.Contains(dnsTextLower, host+":") {
			extraPolicyLines = append(extraPolicyLines, fmt.Sprintf("%s%s: %s", policyIndent, host, directDNS))
		}
	}

	var requiredFilters []string
	if includeMagicDNS {
		requiredFilters = append(requiredFilters, "+.tailscale.com", "+.tailscale.io", "+.ts.net")
		if cleanSuffix := normalizeDomain(tailnetSuffix); cleanSuffix != "" {
			requiredFilters = append(requiredFilters, "+."+cleanSuffix)
		}
	}
	for _, dom := range splitDomains {
		requiredFilters = append(requiredFilters, "+."+dom)
	}
	var extraFilterLines []string
	for _, entry := range requiredFilters {
		if !hasFilterEntry(dnsTextLower, entry) {
			extraFilterLines = append(extraFilterLines, filterItemPrefix+entry)
		}
	}

	if len(extraPolicyLines) == 0 && len(extraFilterLines) == 0 {
		return yamlText
	}

	out := make([]string, 0, len(lines)+len(extraPolicyLines)+len(extraFilterLines)+2)
	insertedPolicy := false
	insertedFilter := false
	for i, line := range lines {
		out = append(out, line)
		if i > dnsStart && i < dnsEnd {
			trimmed := strings.TrimSpace(line)
			if !insertedPolicy && trimmed == "nameserver-policy:" && len(extraPolicyLines) > 0 {
				out = append(out, extraPolicyLines...)
				insertedPolicy = true
			}
			if !insertedFilter && trimmed == "fake-ip-filter:" && len(extraFilterLines) > 0 {
				out = append(out, extraFilterLines...)
				insertedFilter = true
			}
		}
		if i == dnsEnd-1 {
			if !insertedPolicy && len(extraPolicyLines) > 0 {
				out = append(out, dnsChildIndent+"nameserver-policy:")
				out = append(out, extraPolicyLines...)
			}
			if !insertedFilter && len(extraFilterLines) > 0 {
				out = append(out, dnsChildIndent+"fake-ip-filter:")
				out = append(out, extraFilterLines...)
			}
		}
	}
	return strings.Join(out, "\n")
}

func findRulesSection(lines []string) (header int, end int, prefix string) {
	header = -1
	end = len(lines)
	prefix = "  - "
	foundPrefix := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if header < 0 {
			if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && trimmed == "rules:" {
				header = i
			}
			continue
		}
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, "-") {
			end = i
			break
		}
		if !foundPrefix && strings.HasPrefix(trimmed, "- ") {
			dashIdx := strings.IndexByte(line, '-')
			prefix = line[:dashIdx] + "- "
			foundPrefix = true
		}
	}
	return header, end, prefix
}

func ensureSplitDNSRules(yamlText, proxyName string, splitDomains []string) string {
	if len(splitDomains) == 0 {
		return yamlText
	}
	lines := strings.Split(yamlText, "\n")
	rulesHeader, rulesEnd, rulePrefix := findRulesSection(lines)
	if rulesHeader < 0 {
		return yamlText
	}
	working := append([]string(nil), lines...)

	for _, domain := range splitDomains {
		hasSuffixRule := false
		insertAfterIdx := rulesHeader
		for i := rulesHeader + 1; i < rulesEnd; i++ {
			trimmed := strings.TrimSpace(working[i])
			if !strings.HasPrefix(trimmed, "- ") {
				continue
			}
			rawRule := stripQuotes(strings.TrimSpace(trimmed[2:]))
			parts := strings.Split(rawRule, ",")
			if len(parts) < 3 {
				continue
			}
			ruleType := strings.ToUpper(strings.TrimSpace(parts[0]))
			payload := strings.ToLower(strings.TrimSpace(parts[1]))
			target := strings.TrimSpace(parts[2])

			if ruleType == "DOMAIN-SUFFIX" && payload == domain {
				hasSuffixRule = true
				if len(parts) > 3 && strings.EqualFold(target, proxyName) {
					working[i] = fmt.Sprintf("%sDOMAIN-SUFFIX,%s,%s", rulePrefix, domain, proxyName)
				}
			} else if ruleType == "DOMAIN" && (payload == domain || strings.HasSuffix(payload, "."+domain)) {
				insertAfterIdx = i
			} else if insertAfterIdx == rulesHeader && (payload == "tailscale.com" || payload == "tailscale.io") {
				insertAfterIdx = i
			}
		}

		if !hasSuffixRule {
			newLine := fmt.Sprintf("%sDOMAIN-SUFFIX,%s,%s", rulePrefix, domain, proxyName)
			working = append(working[:insertAfterIdx+1], append([]string{newLine}, working[insertAfterIdx+1:]...)...)
			rulesEnd++
		}
	}
	return strings.Join(working, "\n")
}

// ensureTailscaleBaseRules ensures ts.net, 100.64.0.0/10, and tailscale controlplane DIRECT rules exist
// when a user imports a generic Clash subscription that didn't hand-write Tailscale rules yet.
func ensureTailscaleBaseRules(yamlText, proxyName string) string {
	lines := strings.Split(yamlText, "\n")
	rulesHeader, rulesEnd, rulePrefix := findRulesSection(lines)
	if rulesHeader < 0 {
		return yamlText
	}
	sectionLower := strings.ToLower(strings.Join(lines[rulesHeader:rulesEnd], "\n"))
	var toInsert []string
	if !strings.Contains(sectionLower, "tailscale.com,") {
		toInsert = append(toInsert, rulePrefix+"DOMAIN-SUFFIX,tailscale.com,DIRECT")
	}
	if !strings.Contains(sectionLower, "tailscale.io,") {
		toInsert = append(toInsert, rulePrefix+"DOMAIN-SUFFIX,tailscale.io,DIRECT")
	}
	if !strings.Contains(sectionLower, "domain-suffix,ts.net,") {
		toInsert = append(toInsert, fmt.Sprintf("%sDOMAIN-SUFFIX,ts.net,%s", rulePrefix, proxyName))
	}
	if !strings.Contains(sectionLower, "100.64.0.0/10,"+strings.ToLower(proxyName)) {
		toInsert = append(toInsert, fmt.Sprintf("%sIP-CIDR,100.64.0.0/10,%s,no-resolve", rulePrefix, proxyName))
	}
	if !strings.Contains(sectionLower, "fd7a:115c:a1e0::/48,"+strings.ToLower(proxyName)) {
		toInsert = append(toInsert, fmt.Sprintf("%sIP-CIDR6,fd7a:115c:a1e0::/48,%s,no-resolve", rulePrefix, proxyName))
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

func collectProtectedSubdomains(lines []string, splitDomains []string) []string {
	if len(splitDomains) == 0 {
		return nil
	}
	var found []string
	seen := map[string]bool{}
	maybeAdd := func(rawHost string) {
		host := normalizeDomain(stripQuotes(rawHost))
		if host == "" || seen[host] {
			return
		}
		for _, dom := range splitDomains {
			if host != dom && strings.HasSuffix(host, "."+dom) {
				seen[host] = true
				found = append(found, host)
				return
			}
		}
	}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, "server:") {
			maybeAdd(strings.TrimSpace(trimmed[7:]))
			continue
		}
		if strings.HasPrefix(trimmed, "- ") {
			body := stripQuotes(strings.TrimSpace(trimmed[2:]))
			parts := strings.Split(body, ",")
			if len(parts) >= 3 && strings.EqualFold(strings.TrimSpace(parts[0]), "DOMAIN") && strings.EqualFold(strings.TrimSpace(parts[2]), "DIRECT") {
				maybeAdd(strings.TrimSpace(parts[1]))
			}
		}
	}
	return found
}

func detectPrimaryPublicDNS(dnsLines []string) string {
	for _, key := range []string{"default-nameserver:", "proxy-server-nameserver:", "nameserver:"} {
		for i, line := range dnsLines {
			if strings.TrimSpace(line) != key {
				continue
			}
			for j := i + 1; j < len(dnsLines); j++ {
				t := strings.TrimSpace(dnsLines[j])
				if t == "" || strings.HasPrefix(t, "#") {
					continue
				}
				if strings.HasPrefix(t, "- ") {
					cand := stripQuotes(strings.TrimSpace(t[2:]))
					if cand != "" && !strings.HasPrefix(strings.ToLower(cand), "tailscale://") {
						return cand
					}
				} else {
					break
				}
			}
		}
	}
	return "223.5.5.5"
}

func detectSectionChildIndent(sectionLines []string, fallback string) string {
	best := ""
	for i := 1; i < len(sectionLines); i++ {
		t := strings.TrimSpace(sectionLines[i])
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		sp := leadingSpaces(sectionLines[i])
		if len(sp) > 0 && (best == "" || len(sp) < len(best)) {
			best = sp
		}
	}
	if best == "" {
		return fallback
	}
	return best
}

func hasTrimmedLine(sectionLines []string, target string) bool {
	for _, line := range sectionLines {
		if strings.TrimSpace(line) == target {
			return true
		}
	}
	return false
}

func detectMappingChildIndent(sectionLines []string, headerKey, fallback string) string {
	for i, line := range sectionLines {
		if strings.TrimSpace(line) != headerKey {
			continue
		}
		headerIndentLen := len(leadingSpaces(line))
		for j := i + 1; j < len(sectionLines); j++ {
			t := strings.TrimSpace(sectionLines[j])
			if t == "" || strings.HasPrefix(t, "#") {
				continue
			}
			childIndent := leadingSpaces(sectionLines[j])
			if len(childIndent) > headerIndentLen {
				return childIndent
			}
			break
		}
	}
	return fallback
}

func detectSequenceItemPrefix(sectionLines []string, headerKey, fallback string) string {
	for i, line := range sectionLines {
		if strings.TrimSpace(line) != headerKey {
			continue
		}
		for j := i + 1; j < len(sectionLines); j++ {
			t := strings.TrimSpace(sectionLines[j])
			if t == "" || strings.HasPrefix(t, "#") {
				continue
			}
			if strings.HasPrefix(t, "- ") {
				dashIdx := strings.IndexByte(sectionLines[j], '-')
				return sectionLines[j][:dashIdx] + "- "
			}
			break
		}
	}
	return fallback
}

func leadingSpaces(line string) string {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i++
	}
	return line[:i]
}

func hasFilterEntry(dnsTextLower, entry string) bool {
	lower := strings.ToLower(entry)
	return strings.Contains(dnsTextLower, "- "+lower) ||
		strings.Contains(dnsTextLower, "- '"+lower+"'") ||
		strings.Contains(dnsTextLower, `- "`+lower+`"`)
}

func normalizeDomain(raw string) string {
	s := strings.ToLower(strings.TrimSpace(raw))
	for strings.HasPrefix(s, "+.") {
		s = s[2:]
	}
	s = strings.Trim(s, ".")
	return s
}

func normalizeDomainList(items []string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, item := range items {
		clean := normalizeDomain(item)
		if clean != "" && !seen[clean] {
			seen[clean] = true
			out = append(out, clean)
		}
	}
	return out
}

func stripQuotes(val string) string {
	if len(val) >= 2 {
		if (val[0] == '"' && val[len(val)-1] == '"') || (val[0] == '\'' && val[len(val)-1] == '\'') {
			return val[1 : len(val)-1]
		}
	}
	return val
}

func quoteIfNeeded(val string) string {
	if strings.ContainsAny(val, ": #") {
		return `"` + strings.ReplaceAll(val, `"`, `\"`) + `"`
	}
	return val
}

// ensureGeoipDB copies geoip.metadb from next to the executable or workspace repo if missing in runtimeDir.
func ensureGeoipDB(runtimeDir string) {
	dst := filepath.Join(runtimeDir, "geoip.metadb")
	if info, err := os.Stat(dst); err == nil && info.Size() > 10240 {
		return
	}
	candidates := []string{}
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(exeDir, "geoip.metadb"),
			filepath.Join(exeDir, "..", "..", "app", "entry", "src", "main", "resources", "rawfile", "geoip.metadb"),
		)
	}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(wd, "geoip.metadb"),
			filepath.Join(wd, "app", "entry", "src", "main", "resources", "rawfile", "geoip.metadb"),
			filepath.Join(wd, "..", "app", "entry", "src", "main", "resources", "rawfile", "geoip.metadb"),
		)
	}
	for _, src := range candidates {
		info, err := os.Stat(src)
		if err != nil || info.Size() <= 10240 {
			continue
		}
		in, err := os.Open(src)
		if err != nil {
			continue
		}
		out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			_ = in.Close()
			continue
		}
		_, copyErr := io.Copy(out, in)
		_ = in.Close()
		_ = out.Close()
		if copyErr == nil {
			return
		}
	}
}
