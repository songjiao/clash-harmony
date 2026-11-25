package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/metacubex/tailscale/tailcfg"
	"github.com/metacubex/tailscale/types/dnstype"
)

func TestValidateConfigYAML_Valid(t *testing.T) {
	yamlText := `
mixed-port: 7890
mode: rule
dns:
  enable: true
  enhanced-mode: fake-ip
proxies:
  - name: Tailscale
    type: tailscale
    hostname: harmony-phone
    accept-routes: true
  - name: NodeA
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - NodeA
      - Tailscale
      - DIRECT
rules:
  - DOMAIN-SUFFIX,ts.net,Tailscale
  - IP-CIDR,192.168.1.0/24,Tailscale,no-resolve
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - MATCH,Proxy
`
	res := validateConfigYAML(yamlText)
	if !res.OK {
		t.Fatalf("expected valid config, got error=%q line=%d", res.Error, res.Line)
	}
	if res.ProxyCount != 2 || res.GroupCount != 1 || res.RuleCount != 4 {
		t.Fatalf("unexpected counts: %+v", res)
	}
	if !res.HasTailscale {
		t.Fatalf("expected HasTailscale=true")
	}
	if res.DNSMode != "fake-ip" {
		t.Fatalf("expected dnsMode=fake-ip, got %q", res.DNSMode)
	}
}

func TestValidateConfigYAML_SyntaxErrorLineNumber(t *testing.T) {
	yamlText := "mode: rule\nproxies:\n- name: A\n  type: socks5\n  server: 1.1.1.1\n  port: 1080\n  - name: Broken\n    type: tailscale\n"
	res := validateConfigYAML(yamlText)
	if res.OK {
		t.Fatalf("expected syntax error for bad indentation")
	}
	if res.Line <= 0 {
		t.Fatalf("expected positive line number, got line=%d error=%q", res.Line, res.Error)
	}
}

func TestValidateConfigYAML_DuplicateProxy(t *testing.T) {
	yamlText := `
proxies:
  - name: Tailscale
    type: tailscale
  - name: Tailscale
    type: tailscale
rules:
  - MATCH,DIRECT
`
	res := validateConfigYAML(yamlText)
	if res.OK {
		t.Fatalf("expected duplicate proxy error")
	}
}

func TestValidateConfigYAML_DecoupledTailscaleReferenceAllowed(t *testing.T) {
	yamlText := `
proxies:
  - name: NodeA
    type: socks5
    server: 127.0.0.1
    port: 1080
proxy-groups:
  - name: HomeLAN
    type: select
    proxies:
      - Tailscale
      - DIRECT
rules:
  - DOMAIN-SUFFIX,ts.net,Tailscale
  - IP-CIDR,192.168.1.0/24,HomeLAN,no-resolve
  - MATCH,NodeA
`
	res := validateConfigYAML(yamlText)
	if !res.OK {
		t.Fatalf("expected decoupled Tailscale reference to validate cleanly, got error=%q", res.Error)
	}
	if res.HasTailscale {
		t.Fatalf("expected HasTailscale=false when YAML omits Tailscale proxy")
	}
}

func TestTailscaleAPIMuxEndpoints(t *testing.T) {
	mux := newTailscaleAPIMux()

	// GET /tailscale/status when no Tailscale outbound is active
	req := httptest.NewRequest(http.MethodGet, "/tailscale/status", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var st tailscaleControlStatusDTO
	if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal status failed: %v", err)
	}
	if st.Available {
		t.Fatalf("expected Available=false when no active outbound")
	}

	// POST /config/validate
	valReq := httptest.NewRequest(http.MethodPost, "/config/validate", bytes.NewBufferString("mode: rule\nrules:\n  - MATCH,DIRECT\n"))
	valRec := httptest.NewRecorder()
	mux.ServeHTTP(valRec, valReq)
	if valRec.Code != http.StatusOK {
		t.Fatalf("expected 200 for /config/validate, got %d", valRec.Code)
	}
	var vr ValidationResult
	if err := json.Unmarshal(valRec.Body.Bytes(), &vr); err != nil {
		t.Fatalf("unmarshal validate result failed: %v", err)
	}
	if !vr.OK || vr.RuleCount != 1 {
		t.Fatalf("unexpected validation result: %+v", vr)
	}

	// POST /tailscale/dns-query when no outbound is active
	dnsReq := httptest.NewRequest(http.MethodPost, "/tailscale/dns-query", bytes.NewBufferString(`{"name":"dsh-10.sjfarm.cc","type":"A"}`))
	dnsRec := httptest.NewRecorder()
	mux.ServeHTTP(dnsRec, dnsReq)
	if dnsRec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 when tailscale outbound inactive, got %d", dnsRec.Code)
	}
}

func TestExtractSplitDnsFromConfig(t *testing.T) {
	cfg := &tailcfg.DNSConfig{
		Domains: []string{"tail2694c0.ts.net", "sjfarm.cc"},
		Routes: map[string][]*dnstype.Resolver{
			"sjfarm.cc.":           {{Addr: "192.168.1.11"}, {Addr: "192.168.1.11"}},
			"corp.internal":        {{Addr: "10.0.0.53"}},
			"tail2694c0.ts.net.":   {{Addr: "100.100.100.100"}},
			"1.168.192.in-addr.arpa": {{Addr: "192.168.1.11"}},
			"ts.net":               {{Addr: "100.100.100.100"}},
		},
	}
	split, search := extractSplitDnsFromConfig(cfg, "tail2694c0.ts.net")
	if len(split) != 2 {
		t.Fatalf("expected 2 split DNS domains, got %+v", split)
	}
	if split[0].Domain != "corp.internal" || len(split[0].Nameservers) != 1 || split[0].Nameservers[0] != "10.0.0.53" {
		t.Fatalf("unexpected split[0]: %+v", split[0])
	}
	if split[1].Domain != "sjfarm.cc" || len(split[1].Nameservers) != 1 || split[1].Nameservers[0] != "192.168.1.11" {
		t.Fatalf("unexpected split[1]: %+v", split[1])
	}
	if len(search) != 2 {
		t.Fatalf("expected 2 search domains, got %+v", search)
	}
}
