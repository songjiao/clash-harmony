package main

import (
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func TestIsTailscaleConnectionChainOHOS(t *testing.T) {
	tsNames := map[string]bool{"office-ts": true}

	if !isTailscaleConnectionChain(C.Chain{"office-ts"}, tsNames) {
		t.Fatalf("expected Tailscale outbound chain to be preserved")
	}
	if !isTailscaleConnectionChain(C.Chain{"Tailscale"}, tsNames) {
		t.Fatalf("expected built-in Tailscale name to be preserved")
	}
	if isTailscaleConnectionChain(C.Chain{"SG-Trojan-02", "Proxy"}, tsNames) {
		t.Fatalf("expected non-Tailscale proxy chain to be pruned")
	}
}

func TestOHOSNetworkChangeCoordinator(t *testing.T) {
	coord := &networkChangeCoordinator{}
	coord.Trigger(NetworkChangeEvent{
		IfaceName:         "wlan0",
		Reason:            "switch-cellular-to-wifi",
		RebindTailscale:   true,
		PruneNonTailscale: true,
	})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		st := coord.Stats()
		if st.EventCount >= 1 {
			if st.LastIface != "wlan0" || st.LastReason != "switch-cellular-to-wifi" {
				t.Fatalf("unexpected stats: %+v", st)
			}
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for OHOS network change event")
}
