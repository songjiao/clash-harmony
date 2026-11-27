//go:build !android

package main

import "github.com/metacubex/mihomo/config"

func isAndroidPlatform() bool { return false }

func defaultPlatformHostname() string { return "" }

func dupTunFD(fd int) (int, error) { return fd, nil }

func closeFD(fd int) {}

func applyAndroidTunConfig(cfg *config.Config, tunFD int) error { return nil }

func startAndroidTunReceiver(socketName string, engine *DesktopEngine) error { return nil }
