package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel"
)

func freeTCPAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate ephemeral port: %v", err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	return addr
}

func TestParseTailscaleConfigAndDnsPolicy(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	C.SetHomeDir(dir)
	C.SetConfig(cfgPath)

	yamlContent := `
mixed-port: 0
mode: rule
log-level: debug
external-controller: 127.0.0.1:0

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
  nameserver-policy:
    "+.ts.net": "tailscale://Tailscale"

proxies:
  - name: "Tailscale"
    type: tailscale
    hostname: "ohos-phone"
    accept-routes: true
    udp: true

rules:
  - DOMAIN-SUFFIX,ts.net,Tailscale
  - MATCH,DIRECT
`
	if err := os.WriteFile(cfgPath, []byte(yamlContent), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := executor.ParseWithPath(cfgPath)
	if err != nil {
		t.Fatalf("ParseWithPath failed: %v", err)
	}
	p, ok := cfg.Proxies["Tailscale"]
	if !ok {
		t.Fatal("Tailscale proxy not registered in parsed config")
	}
	if p.Type() != C.Tailscale {
		t.Fatalf("got proxy type %v, want %v", p.Type(), C.Tailscale)
	}
	if !strings.EqualFold(cfg.DNS.EnhancedMode.String(), "fake-ip") {
		t.Fatalf("expected DNS enhanced-mode fake-ip, got %v", cfg.DNS.EnhancedMode)
	}
}

func TestConfigureRuntimeConfigTunAndControllerOnly(t *testing.T) {
	cfg := &config.Config{
		General: &config.General{},
	}

	// Controller-only path
	dupFd, err := configureRuntimeConfig(cfg, -1)
	if err != nil {
		t.Fatalf("configureRuntimeConfig(-1) error: %v", err)
	}
	if dupFd != -1 || cfg.General.Tun.Enable || cfg.General.Tun.FileDescriptor != 0 {
		t.Fatalf("unexpected controller-only tun config: dupFd=%d enable=%v fd=%d",
			dupFd, cfg.General.Tun.Enable, cfg.General.Tun.FileDescriptor)
	}
	if cfg.Controller.ExternalController != defaultControllerAddr {
		t.Fatalf("got controller %q, want %q", cfg.Controller.ExternalController, defaultControllerAddr)
	}

	// TUN path with valid readable FD (pipe read end)
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()

	dupFd, err = configureRuntimeConfig(cfg, int(r.Fd()))
	if err != nil {
		t.Fatalf("configureRuntimeConfig(tunFd) error: %v", err)
	}
	defer os.NewFile(uintptr(dupFd), "dup-tun").Close()

	if !cfg.General.Tun.Enable || cfg.General.Tun.Stack != C.TunGvisor {
		t.Fatalf("unexpected tun enable/stack: enable=%v stack=%v", cfg.General.Tun.Enable, cfg.General.Tun.Stack)
	}
	if cfg.General.Tun.FileDescriptor != dupFd || dupFd == int(r.Fd()) {
		t.Fatalf("expected distinct dupFd, got %d (orig %d)", cfg.General.Tun.FileDescriptor, r.Fd())
	}
	if cfg.General.Tun.AutoRoute || cfg.General.Tun.AutoRedirect || cfg.General.Tun.AutoDetectInterface {
		t.Fatal("AutoRoute/AutoRedirect/AutoDetectInterface must be false on HarmonyOS sandbox")
	}
	if len(cfg.General.Tun.DNSHijack) != 1 || cfg.General.Tun.DNSHijack[0] != "any:53" {
		t.Fatalf("unexpected DNSHijack: %v", cfg.General.Tun.DNSHijack)
	}
}

func TestBridgeStartCoreLogAndStopReleasesPort(t *testing.T) {
	dir := t.TempDir()
	ctlAddr := freeTCPAddr(t)
	cfgPath := filepath.Join(dir, "current.yaml")
	yamlContent := fmt.Sprintf(`
mixed-port: 0
allow-lan: false
mode: rule
log-level: info
external-controller: %s
secret: ""
rules:
  - MATCH,DIRECT
`, ctlAddr)
	if err := os.WriteFile(cfgPath, []byte(yamlContent), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := bridge.startEngine(cfgPath, -1); err != nil {
		t.Fatalf("startEngine failed: %v", err)
	}
	t.Cleanup(func() {
		_ = bridge.stopEngine()
	})

	if _, ok := tunnel.Proxies()["DIRECT"]; !ok {
		t.Fatal("expected DIRECT proxy in active tunnel")
	}
	logPath := filepath.Join(dir, "mihomo-core.log")
	var logBytes []byte
	var err error
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		logBytes, err = os.ReadFile(logPath)
		if err == nil && strings.Contains(string(logBytes), "[Bridge] Mihomo core started") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("expected mihomo-core.log to be created: %v", err)
	}
	if !strings.Contains(string(logBytes), "[Bridge] Mihomo core started") {
		t.Fatalf("expected startup marker in mihomo-core.log, got:\n%s", string(logBytes))
	}

	if err := bridge.stopEngine(); err != nil {
		t.Fatalf("stopEngine failed: %v", err)
	}

	// Confirm the controller port is freed cleanly for subsequent VPN start.
	ln, err := net.Listen("tcp", ctlAddr)
	if err != nil {
		t.Fatalf("expected controller address %s to be released after stopEngine: %v", ctlAddr, err)
	}
	_ = ln.Close()
}

func TestBridgeEagerStartTailscaleWritesStatusAndFiltersDebugLog(t *testing.T) {
	dir := t.TempDir()
	ctlAddr := freeTCPAddr(t)
	cfgPath := filepath.Join(dir, "current.yaml")
	yamlContent := fmt.Sprintf(`
mixed-port: 0
allow-lan: false
mode: rule
log-level: info
external-controller: %s
secret: ""

dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - 223.5.5.5
    - 119.29.29.29

proxies:
  - name: "Tailscale"
    type: tailscale
    hostname: "test-ohos"
    state-dir: "tailscale"
    accept-routes: true
    udp: true

rules:
  - DOMAIN-SUFFIX,ts.net,Tailscale
  - MATCH,DIRECT
`, ctlAddr)
	if err := os.WriteFile(cfgPath, []byte(yamlContent), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := bridge.startEngine(cfgPath, -1); err != nil {
		t.Fatalf("startEngine failed: %v", err)
	}
	t.Cleanup(func() {
		_ = bridge.stopEngine()
	})

	statusPath := filepath.Join(dir, "tailscale-status.json")
	logPath := filepath.Join(dir, "mihomo-core.log")

	var status outbound.TailscaleStatus
	var rawStatus []byte
	var logBytes []byte
	deadline := time.Now().Add(12 * time.Second)
	for time.Now().Before(deadline) {
		rawStatus, _ = os.ReadFile(statusPath)
		logBytes, _ = os.ReadFile(logPath)
		if len(rawStatus) > 0 && json.Unmarshal(rawStatus, &status) == nil {
			if status.Name == "Tailscale" &&
				status.BackendState != "" &&
				status.BackendState != "Idle" &&
				strings.HasPrefix(status.AuthURL, "https://") &&
				strings.Contains(string(logBytes), "[Bridge] Tailscale outbound started: Tailscale") {
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Logf("tailscale-status.json:\n%s", string(rawStatus))
	if err := json.Unmarshal(rawStatus, &status); err != nil {
		t.Fatalf("expected valid tailscale-status.json at %s: %v (raw=%q)", statusPath, err, string(rawStatus))
	}
	if status.Name != "Tailscale" {
		t.Fatalf("expected status.Name=Tailscale, got %q", status.Name)
	}
	if status.BackendState == "" || status.BackendState == "Idle" {
		t.Fatalf("expected started backendState, got %q", status.BackendState)
	}
	if !strings.HasPrefix(status.AuthURL, "https://") {
		t.Fatalf("expected interactive login AuthURL starting with https://, got %q (state=%q lastErr=%q logs=%v)",
			status.AuthURL, status.BackendState, status.LastError, status.RecentLogs)
	}

	// Give log sink a brief moment to flush remaining lines.
	logDeadline := time.Now().Add(time.Second)
	for time.Now().Before(logDeadline) {
		logBytes, _ = os.ReadFile(logPath)
		if strings.Contains(string(logBytes), "[Bridge] Tailscale outbound started: Tailscale") {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	logText := string(logBytes)
	if !strings.Contains(logText, "[Bridge] Starting Tailscale outbound: Tailscale") {
		t.Fatalf("expected starting marker in mihomo-core.log, got:\n%s", logText)
	}
	if !strings.Contains(logText, "[Bridge] Tailscale outbound started: Tailscale") {
		t.Fatalf("expected started marker in mihomo-core.log, got:\n%s", logText)
	}
	if strings.Contains(logText, "[DEBUG]") {
		t.Fatalf("expected log-level: info to filter [DEBUG] lines from mihomo-core.log, got:\n%s", logText)
	}

	if err := bridge.stopEngine(); err != nil {
		t.Fatalf("stopEngine failed: %v", err)
	}

	stoppedRaw, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("read tailscale-status.json after stop: %v", err)
	}
	var stoppedStatus outbound.TailscaleStatus
	if err := json.Unmarshal(stoppedRaw, &stoppedStatus); err != nil {
		t.Fatalf("unmarshal tailscale-status.json after stop: %v", err)
	}
	if stoppedStatus.BackendState != "Stopped" {
		t.Fatalf("expected Stopped after stopEngine, got %q", stoppedStatus.BackendState)
	}
}
