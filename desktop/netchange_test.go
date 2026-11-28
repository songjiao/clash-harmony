package main

import (
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func TestIsTailscaleConnectionChain(t *testing.T) {
	tsNames := map[string]bool{"my-ts": true}

	if !isTailscaleConnectionChain(C.Chain{"Tailscale", "GLOBAL"}, tsNames) {
		t.Fatalf("expected default Tailscale chain to be preserved")
	}
	if !isTailscaleConnectionChain(C.Chain{"my-ts"}, tsNames) {
		t.Fatalf("expected custom Tailscale outbound name to be preserved")
	}
	if isTailscaleConnectionChain(C.Chain{"DIRECT"}, tsNames) {
		t.Fatalf("expected DIRECT chain to be pruned on network switch")
	}
	if isTailscaleConnectionChain(C.Chain{"HK-VLESS-01", "Proxy"}, tsNames) {
		t.Fatalf("expected public proxy chain to be pruned on network switch")
	}
}

func TestNetworkChangeCoordinatorCoalescesFlags(t *testing.T) {
	coord := &networkChangeCoordinator{}
	coord.Trigger(NetworkChangeEvent{
		IfaceName:         "",
		Reason:            "net-lost",
		RebindTailscale:   false,
		PruneNonTailscale: false,
	})
	coord.Trigger(NetworkChangeEvent{
		IfaceName:         "rmnet0",
		Gateway:           "10.0.0.1",
		Reason:            "switch-wifi-to-cellular",
		RebindTailscale:   true,
		PruneNonTailscale: true,
	})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		st := coord.Stats()
		if st.EventCount >= 1 {
			if st.LastIface != "rmnet0" {
				t.Fatalf("expected last iface rmnet0, got %q", st.LastIface)
			}
			if st.LastGateway != "10.0.0.1" {
				t.Fatalf("expected last gateway 10.0.0.1, got %q", st.LastGateway)
			}
			if st.LastReason != "switch-wifi-to-cellular" {
				t.Fatalf("expected last reason switch-wifi-to-cellular, got %q", st.LastReason)
			}
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for coalesced network change event")
}
