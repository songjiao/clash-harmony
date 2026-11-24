// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build openharmony

package netmon

import (
	"net"
	"sync/atomic"
)

// OpenHarmony reports runtime.GOOS=linux; use build tags for this platform.
// The official host API hint is authoritative even if /proc contains a stale
// route after a bearer switch.
var hostDefaultInterface atomic.Pointer[string]

const isHarmonyOS = true

// UpdateLastKnownDefaultRouteInterface records the host-reported default
// network interface name on OpenHarmony/HarmonyOS. An empty string means offline.
func UpdateLastKnownDefaultRouteInterface(name string) {
	hostDefaultInterface.Store(&name)
}

func hostDefaultRoute() (DefaultRouteDetails, bool) {
	name := hostDefaultInterface.Load()
	if name == nil {
		return DefaultRouteDetails{}, false
	}
	d := DefaultRouteDetails{InterfaceName: *name}
	if *name != "" {
		if iface, err := net.InterfaceByName(*name); err == nil {
			d.InterfaceIndex = iface.Index
		}
	}
	return d, true
}
