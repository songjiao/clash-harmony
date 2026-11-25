package main

import (
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
)

func TestBuildRuntimeYAML_TailscaleAndSplitDNS(t *testing.T) {
	input := `mixed-port: 7899
mode: rule
ipv6: false
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
  nameserver:
    - 223.5.5.5
  nameserver-policy:
    +.ts.net: tailscale://Tailscale
  fake-ip-filter:
    - '*.lan'

proxies:
  - name: AWS-Tokyo
    type: vless
    server: node.in.sjfarm.cc
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - AWS-Tokyo
      - DIRECT

rules:
  - DOMAIN,derp.in.sjfarm.cc,DIRECT
  - DOMAIN-SUFFIX,google.com,Proxy
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - MATCH,Proxy
`

	prefs := TailscaleNativePrefs{
		ManagedByApp:       true,
		Enabled:            true,
		ProxyName:          "Tailscale",
		Hostname:           "huawei16s-clash",
		AcceptRoutes:       true,
		AutoInjectMagicDNS: true,
		TailnetSuffix:      "tail1234.ts.net",
		AutoSyncSplitDNS:   true,
		SplitDNSDomains:    []string{"in.sjfarm.cc", "q.sjfarm.cc"},
	}

	settings := defaultAppSettings()
	settings.MixedPort = 7890
	settings.TunMode = true

	out := BuildRuntimeYAML(input, prefs, settings)

	// 1. Generated YAML must parse cleanly in Mihomo's own UnmarshalRawConfig
	rawCfg, err := config.UnmarshalRawConfig([]byte(out))
	if err != nil {
		t.Fatalf("generated runtime YAML failed to parse: %v\n---\n%s", err, out)
	}

	// 2. Tailscale proxy must be injected with requested hostname
	foundTS := false
	for _, p := range rawCfg.Proxy {
		if p["name"] == "Tailscale" && p["type"] == "tailscale" && p["hostname"] == "huawei16s-clash" {
			foundTS = true
		}
	}
	if !foundTS {
		t.Fatalf("expected Tailscale proxy to be injected, got proxies: %#v", rawCfg.Proxy)
	}

	// 3. SplitDNS nameserver-policy & protected direct hosts
	for _, want := range []string{
		"+.in.sjfarm.cc: tailscale://Tailscale",
		"+.q.sjfarm.cc: tailscale://Tailscale",
		"+.tail1234.ts.net: tailscale://Tailscale",
		"node.in.sjfarm.cc: 223.5.5.5",
		"derp.in.sjfarm.cc: 223.5.5.5",
		"- +.in.sjfarm.cc",
		"- +.q.sjfarm.cc",
		"- DOMAIN-SUFFIX,in.sjfarm.cc,Tailscale",
		"- DOMAIN-SUFFIX,q.sjfarm.cc,Tailscale",
		"- IP-CIDR,100.64.0.0/10,Tailscale,no-resolve",
		"device: ClashHarmony",
		"stack: mixed",
		"strict-route: true",
		"inet6-address: []",
		"  ipv6: false",
		"auto-route: true",
		"mixed-port: 7890",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected output to contain %q\n---\n%s", want, out)
		}
	}

	// 4. Exact DOMAIN rule must stay ABOVE DOMAIN-SUFFIX rule, and QUIC REJECT must be ABOVE google.com and deduplicated
	idxExact := strings.Index(out, "DOMAIN,derp.in.sjfarm.cc,DIRECT")
	idxSuffix := strings.Index(out, "DOMAIN-SUFFIX,in.sjfarm.cc,Tailscale")
	if idxExact < 0 || idxSuffix < 0 || idxExact > idxSuffix {
		t.Errorf("expected exact DOMAIN rule (%d) before DOMAIN-SUFFIX (%d)", idxExact, idxSuffix)
	}
	idxQuic := strings.Index(out, "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT")
	idxGoogle := strings.Index(out, "DOMAIN-SUFFIX,google.com,Proxy")
	if idxQuic < 0 || idxGoogle < 0 || idxQuic > idxGoogle {
		t.Errorf("expected QUIC REJECT (%d) before google.com (%d)\n---\n%s", idxQuic, idxGoogle, out)
	}
	if strings.Count(out, "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT") != 1 {
		t.Errorf("expected exactly 1 deduplicated QUIC REJECT rule")
	}

	// 5. TunMode=false disables tun
	settings.TunMode = false
	outNoTun := BuildRuntimeYAML(input, prefs, settings)
	if !strings.Contains(outNoTun, "tun:\n  enable: false") {
		t.Errorf("expected tun disabled when TunMode=false")
	}
}

func TestValidateConfigYAML_AllowsAppManagedTailscale(t *testing.T) {
	yamlText := `proxies:
  - name: Demo
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: Home
    type: select
    proxies:
      - Tailscale
      - DIRECT
rules:
  - DOMAIN-SUFFIX,in.sjfarm.cc,Tailscale
  - MATCH,Home
`
	res := validateConfigYAML(yamlText)
	if !res.OK {
		t.Fatalf("expected validation OK, got error: %s", res.Error)
	}
	if res.ProxyCount != 1 || res.GroupCount != 1 || res.RuleCount != 2 {
		t.Fatalf("unexpected counts: %+v", res)
	}
}

func TestBuildRuntimeYAML_FourSpaceIndentWithoutNameserverPolicy(t *testing.T) {
	// Mirrors BitzNet subscription formatting: 4-space indent under dns:, no nameserver-policy key.
	input := `allow-lan: true
dns:
    default-nameserver:
        - 223.5.5.5
    enable: true
    enhanced-mode: fake-ip
    fake-ip-filter:
        - +.example.com
    fake-ip-range: 198.18.0.0/15
    ipv6: false
    listen: 127.0.0.1:7874
    nameserver:
        - tls://119.29.29.29
    use-hosts: true
    use-system-hosts: false
mode: rule
proxies:
    - name: NodeA
      type: socks5
      server: 1.2.3.4
      port: 1080
proxy-groups:
    - name: Proxy
      type: select
      proxies:
          - NodeA
rules:
    - MATCH,Proxy
`

	prefs := TailscaleNativePrefs{
		ManagedByApp:       true,
		Enabled:            true,
		ProxyName:          "Tailscale",
		Hostname:           "huawei16s-clash",
		AcceptRoutes:       true,
		AutoInjectMagicDNS: true,
		TailnetSuffix:      "tail2694c0.ts.net",
		AutoSyncSplitDNS:   true,
		SplitDNSDomains:    []string{"in.sjfarm.cc", "q.sjfarm.cc"},
	}
	settings := defaultAppSettings()
	settings.TunMode = true

	out := BuildRuntimeYAML(input, prefs, settings)
	if _, err := config.UnmarshalRawConfig([]byte(out)); err != nil {
		t.Fatalf("4-space YAML failed to parse after injection: %v\n---\n%s", err, out)
	}
	if !strings.Contains(out, "\n    nameserver-policy:\n      +.ts.net: tailscale://Tailscale") {
		t.Errorf("expected 4-space nameserver-policy with 6-space children\n---\n%s", out)
	}
}

func TestApplyCustomOverlay_FailClosedAIStrictAndBitzNetMerge(t *testing.T) {
	bitznetYAML := `allow-lan: true
dns:
    default-nameserver:
        - 223.5.5.5
    enable: true
    enhanced-mode: fake-ip
    fake-ip-filter:
        - +.bntennode.com
    nameserver:
        - tls://119.29.29.29
proxies:
    - name: Bitz-US
      type: trojan
      server: us.bntennode.com
      port: 443
      password: secret
proxy-groups:
    - name: Bitz Net
      type: select
      proxies:
          - Bitz-US
rules:
    - DOMAIN-SUFFIX,google.com,Bitz Net
    - GEOIP,CN,DIRECT
    - MATCH,Bitz Net
`
	overlay := CustomOverlay{
		Enabled:             true,
		SelfHostedGroupName: "🛡️ AI严格自建",
		FailClosed:          true,
		AIStrictEnabled:     true,
		AIDomains:           []string{"claude.ai", "anthropic.com", "google.com"},
		AIKeywords:          []string{"claude"},
		CustomProxiesYAML: `- name: 东京落地
  type: vless
  server: node.sjfarm.cc
  port: 443
  uuid: 00000000-0000-0000-0000-000000000000`,
		CustomRules:   []string{"IP-CIDR,192.168.1.0/24,Tailscale,no-resolve"},
		DirectDomains: []string{"derp.sjfarm.cc"},
	}
	tsPrefs := TailscaleNativePrefs{
		ManagedByApp:       true,
		Enabled:            true,
		ProxyName:          "Tailscale",
		Hostname:           "huawei16s-clash",
		AcceptRoutes:       true,
		AutoInjectMagicDNS: true,
		AutoSyncSplitDNS:   true,
		SplitDNSDomains:    []string{"in.sjfarm.cc", "q.sjfarm.cc"},
	}
	settings := defaultAppSettings()
	settings.TunMode = true

	merged, err := BuildRuntimeYAMLWithOverlay(bitznetYAML, overlay, tsPrefs, settings)
	if err != nil {
		t.Fatalf("BuildRuntimeYAMLWithOverlay failed: %v", err)
	}
	rawCfg, err := config.UnmarshalRawConfig([]byte(merged))
	if err != nil {
		t.Fatalf("merged YAML failed Mihomo UnmarshalRawConfig: %v\n---\n%s", err, merged)
	}

	// Verify Fail-Closed AI group contains ONLY 东京落地 (NEVER DIRECT, NEVER Bitz-US!)
	foundAIGroup := false
	for _, g := range rawCfg.ProxyGroup {
		if g["name"] == "🛡️ AI严格自建" {
			foundAIGroup = true
			plist, _ := g["proxies"].([]any)
			if len(plist) != 1 || plist[0] != "东京落地" {
				t.Fatalf("expected Fail-Closed AI group to contain ONLY [东京落地], got %#v", plist)
			}
		}
	}
	if !foundAIGroup {
		t.Fatalf("expected 🛡️ AI严格自建 group in merged config")
	}

	// Verify AI rule sits ABOVE BitzNet's google.com rule!
	idxStrict := strings.Index(merged, "DOMAIN-SUFFIX,google.com,🛡️ AI严格自建")
	idxBitz := strings.Index(merged, "DOMAIN-SUFFIX,google.com,Bitz Net")
	if idxStrict < 0 || idxBitz < 0 || idxStrict > idxBitz {
		t.Fatalf("expected AI strict google.com (%d) BEFORE Bitz Net google.com (%d)", idxStrict, idxBitz)
	}

	// Verify self-hosted server & direct domain are DIRECT and in fake-ip-filter
	for _, want := range []string{
		"DOMAIN,node.sjfarm.cc,DIRECT",
		"DOMAIN,derp.sjfarm.cc,DIRECT",
		"- node.sjfarm.cc",
		"- derp.sjfarm.cc",
		"IP-CIDR,192.168.1.0/24,Tailscale,no-resolve",
	} {
		if !strings.Contains(merged, want) {
			t.Errorf("expected merged YAML to contain %q", want)
		}
	}

	// Verify empty self-hosted proxies with FailClosed=true produces REJECT kill-switch
	overlayEmpty := overlay
	overlayEmpty.CustomProxiesYAML = ""
	mergedEmpty, err := BuildRuntimeYAMLWithOverlay(bitznetYAML, overlayEmpty, tsPrefs, settings)
	if err != nil {
		t.Fatalf("empty custom proxies merge failed: %v", err)
	}
	rawEmpty, err := config.UnmarshalRawConfig([]byte(mergedEmpty))
	if err != nil {
		t.Fatalf("empty custom proxies YAML failed parse: %v", err)
	}
	for _, g := range rawEmpty.ProxyGroup {
		if g["name"] == "🛡️ AI严格自建" {
			plist, _ := g["proxies"].([]any)
			if len(plist) != 1 || plist[0] != "REJECT" {
				t.Fatalf("expected Fail-Closed empty AI group to fall back to [REJECT], got %#v", plist)
			}
		}
	}
}

func TestApplyCustomOverlay_AIProviderPresetsAndVLESSURI(t *testing.T) {
	baseYAML := `dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
proxies:
  - name: Commercial-1
    type: socks5
    server: 1.2.3.4
    port: 1080
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Commercial-1
rules:
  - MATCH,Proxy
`
	overlay := CustomOverlay{
		Enabled:             true,
		SelfHostedGroupName: defaultSelfHostedGroupName,
		FailClosed:          true,
		AIStrictEnabled:     true,
		AIProviders:         []string{"claude", "gemini"},
		CustomProxiesYAML:   "vless://11111111-2222-3333-4444-555555555555@tokyo.example.com:443?encryption=none&security=tls&sni=tokyo.example.com&fp=chrome&type=ws&host=tokyo.example.com&path=%2Fws#东京自建",
	}
	out, err := ApplyCustomOverlayToYAML(baseYAML, overlay)
	if err != nil {
		t.Fatalf("ApplyCustomOverlayToYAML failed: %v", err)
	}
	if _, err := config.UnmarshalRawConfig([]byte(out)); err != nil {
		t.Fatalf("merged YAML invalid: %v\n---\n%s", err, out)
	}
	for _, want := range []string{
		"name: 东京自建",
		"DOMAIN,tokyo.example.com,DIRECT",
		"DOMAIN-SUFFIX,claude.ai,🛡️ AI严格自建",
		"DOMAIN-SUFFIX,gemini.google.com,🛡️ AI严格自建",
		"DOMAIN-SUFFIX,antigravity.google,🛡️ AI严格自建",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected output to contain %q\n---\n%s", want, out)
		}
	}
	if strings.Contains(out, "DOMAIN-SUFFIX,openai.com,🛡️ AI严格自建") {
		t.Errorf("did not expect unselected provider openai.com in rules\n---\n%s", out)
	}
}

func TestBuildRuntimeYAML_SanitizesBitzNetLoopbackDNS(t *testing.T) {
	input := `dns:
    default-nameserver:
        - 223.5.5.5
    enable: true
    enhanced-mode: fake-ip
    listen: 127.0.0.1:7874
    nameserver:
        - tls://119.29.29.29
    proxy-server-nameserver:
        - udp://127.0.0.1:7874
proxies:
    - name: Demo
      type: socks5
      server: 1.2.3.4
      port: 1080
proxy-groups:
    - name: Proxy
      type: select
      proxies:
          - Demo
rules:
    - IP-CIDR,100.64.0.0/10,DIRECT
    - MATCH,Proxy
`
	settings := defaultAppSettings()
	settings.TunMode = true
	out := BuildRuntimeYAML(input, defaultTailscalePrefs(), settings)
	if _, err := config.UnmarshalRawConfig([]byte(out)); err != nil {
		t.Fatalf("sanitized YAML failed to parse: %v\n---\n%s", err, out)
	}
	if strings.Contains(out, "proxy-server-nameserver:") || strings.Contains(out, "udp://127.0.0.1:7874") {
		t.Errorf("expected loopback proxy-server-nameserver to be stripped\n---\n%s", out)
	}
	for _, want := range []string{
		"listen: 127.0.0.1:17874",
		"sniffer:\n  enable: true",
		"inet4-address:\n    - 198.18.0.1/30",
		"inet6-address: []",
		"IP-CIDR,100.64.0.0/10,Tailscale,no-resolve",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("expected output to contain %q\n---\n%s", want, out)
		}
	}
	idxTS := strings.Index(out, "IP-CIDR,100.64.0.0/10,Tailscale,no-resolve")
	idxDir := strings.Index(out, "IP-CIDR,100.64.0.0/10,DIRECT")
	if idxTS < 0 || idxDir < 0 || idxTS > idxDir {
		t.Errorf("expected Tailscale 100.64.0.0/10 (%d) before BitzNet DIRECT (%d)", idxTS, idxDir)
	}
}
