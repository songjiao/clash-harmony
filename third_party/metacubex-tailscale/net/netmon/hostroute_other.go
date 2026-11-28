// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build !openharmony && !android

package netmon

const isHarmonyOS = false

// UpdateLastKnownDefaultRouteInterface is a no-op off OpenHarmony/HarmonyOS/Android.
func UpdateLastKnownDefaultRouteInterface(string) {}

// UpdateLastKnownDefaultGateway is a no-op off Android.
func UpdateLastKnownDefaultGateway(string) {}

func hostDefaultRoute() (DefaultRouteDetails, bool) {
	return DefaultRouteDetails{}, false
}
