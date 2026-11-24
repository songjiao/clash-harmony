// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package netmon

import "testing"

func TestHarmonyProblematicInterfaces(t *testing.T) {
	for _, name := range []string{"rmnet_ims0", "rmnet_ims1", "ancormnet0", "vpn-tun"} {
		if !isHarmonyProblematicInterface(name) {
			t.Errorf("control-plane or overlay interface %q was allowed", name)
		}
	}
	for _, name := range []string{"rmnet0", "rmnet4", "rmnet_data0", "wlan0", "eth0", "usb0", "rndis0", "en0"} {
		if isHarmonyProblematicInterface(name) {
			t.Errorf("physical interface %q was excluded", name)
		}
	}
}
