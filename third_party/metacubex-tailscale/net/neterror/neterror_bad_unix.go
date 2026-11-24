// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build unix

package neterror

import (
	"errors"

	"golang.org/x/sys/unix"
)

// IsBadSocketError reports whether err indicates an invalid or unrecoverable
// socket file descriptor (EBADF or ENOTSOCK), which requires rebinding the socket.
func IsBadSocketError(err error) bool {
	return errors.Is(err, unix.EBADF) || errors.Is(err, unix.ENOTSOCK)
}
