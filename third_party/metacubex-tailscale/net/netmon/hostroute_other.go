// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build !openharmony && !android

package netmon

const isHarmonyOS = false

// UpdateLastKnownDefaultRouteInterface is a no-op off OpenHarmony/HarmonyOS.
func UpdateLastKnownDefaultRouteInterface(string) {}

func hostDefaultRoute() (DefaultRouteDetails, bool) {
	return DefaultRouteDetails{}, false
}
