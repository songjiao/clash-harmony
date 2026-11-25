//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
)

type SystemProxyManager struct {
	active bool
}

func NewSystemProxyManager() *SystemProxyManager { return &SystemProxyManager{} }
func (m *SystemProxyManager) IsActive() bool     { return m.active }
func (m *SystemProxyManager) Enable(serverAddr, bypass string) error {
	m.active = false
	return nil
}
func (m *SystemProxyManager) Restore() error {
	m.active = false
	return nil
}

func IsElevated() bool {
	return os.Geteuid() == 0
}

func OpenBrowser(targetURL string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", targetURL).Start()
	default:
		return exec.Command("xdg-open", targetURL).Start()
	}
}

func RelaunchElevated(extraArgs ...string) error {
	return fmt.Errorf("elevation is only supported on Windows")
}

func IsAutoStartEnabled() bool { return false }
func SetAutoStart(enable bool) error {
	return fmt.Errorf("autostart is only supported on Windows")
}
func AcquireSingleInstance() (func(), bool) { return func() {}, true }
