// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build unix

package neterror

import (
	"net"
	"os"
	"testing"

	"golang.org/x/sys/unix"
)

func TestIsBadSocketError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "nil", err: nil, want: false},
		{name: "ebadf", err: unix.EBADF, want: true},
		{name: "enotsock", err: unix.ENOTSOCK, want: true},
		{
			name: "wrapped_operror_ebadf",
			err:  &net.OpError{Op: "read", Net: "udp4", Err: &os.SyscallError{Syscall: "recvfrom", Err: unix.EBADF}},
			want: true,
		},
		{
			name: "wrapped_operror_enotsock",
			err:  &net.OpError{Op: "read", Net: "udp4", Err: &os.SyscallError{Syscall: "recvmsg", Err: unix.ENOTSOCK}},
			want: true,
		},
		{
			name: "econnreset",
			err:  &net.OpError{Op: "read", Net: "udp4", Err: &os.SyscallError{Syscall: "recvfrom", Err: unix.ECONNRESET}},
			want: false,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsBadSocketError(tc.err); got != tc.want {
				t.Errorf("IsBadSocketError(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
