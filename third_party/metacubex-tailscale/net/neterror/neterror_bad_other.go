// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build !unix && !windows

package neterror

// IsBadSocketError reports whether err indicates an invalid or unrecoverable
// socket descriptor.
func IsBadSocketError(err error) bool {
	return false
}
