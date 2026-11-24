// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build windows

package neterror

import (
	"errors"
	"syscall"

	"golang.org/x/sys/windows"
)

// IsBadSocketError reports whether err indicates an invalid or unrecoverable
// socket descriptor, which requires rebinding the socket.
func IsBadSocketError(err error) bool {
	return errors.Is(err, syscall.EBADF) || errors.Is(err, windows.WSAENOTSOCK)
}
