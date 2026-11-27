// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build android

package netmon

const isHarmonyOS = false

func hostDefaultRoute() (DefaultRouteDetails, bool) {
	return DefaultRouteDetails{}, false
}
