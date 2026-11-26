//go:build !windows

package main

import (
	"fmt"
	"net"
	"time"
)

func isRunningAsWindowsService() bool {
	return false
}

func isAddrAlreadyListening(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func runWindowsService(startFn func() error, stopFn func()) error {
	return fmt.Errorf("windows service mode is only supported on Windows")
}
