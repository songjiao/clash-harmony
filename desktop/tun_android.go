//go:build android

package main

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/tailscale/net/netns"
	"golang.org/x/sys/unix"
)

func init() {
	// Android unprivileged app sandboxes cannot use Linux SO_MARK / SO_BINDTODEVICE.
	netns.SetEnabled(false)

	// Android has no /etc/resolv.conf; force Go's pure-Go resolver with public DNS fallback
	// when the default resolver attempts to dial 127.0.0.1:53 or [::1]:53.
	if net.DefaultResolver != nil {
		net.DefaultResolver.PreferGo = true
		net.DefaultResolver.Dial = func(ctx context.Context, network, address string) (net.Conn, error) {
			target := address
			if strings.HasPrefix(address, "127.0.0.1:") || strings.HasPrefix(address, "[::1]:") {
				target = "223.5.5.5:53"
			}
			d := net.Dialer{Timeout: 5 * time.Second}
			conn, err := d.DialContext(ctx, network, target)
			if err != nil && target == "223.5.5.5:53" {
				return d.DialContext(ctx, network, "119.29.29.29:53")
			}
			return conn, err
		}
	}
}

func isAndroidPlatform() bool { return true }

func defaultPlatformHostname() string {
	out, err := exec.Command("/system/bin/getprop", "ro.product.model").Output()
	if err == nil {
		raw := strings.ToLower(strings.TrimSpace(string(out)))
		var b strings.Builder
		for _, r := range raw {
			if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
				b.WriteRune(r)
			} else if r == '_' || r == ' ' {
				b.WriteRune('-')
			}
		}
		if clean := strings.Trim(b.String(), "-"); clean != "" {
			return clean + "-clash"
		}
	}
	return "android-clash"
}

func dupTunFD(fd int) (int, error) {
	if fd < 0 {
		return -1, fmt.Errorf("invalid tun fd %d", fd)
	}
	return unix.Dup(fd)
}

func closeFD(fd int) {
	if fd >= 0 {
		_ = unix.Close(fd)
	}
}

func applyAndroidTunConfig(cfg *config.Config, tunFD int) error {
	if tunFD < 0 {
		cfg.General.Tun.Enable = false
		return nil
	}
	dupFD, err := unix.Dup(tunFD)
	if err != nil {
		return fmt.Errorf("dup android tun fd %d: %w", tunFD, err)
	}
	cfg.General.Tun.Enable = true
	cfg.General.Tun.Device = "tun0"
	cfg.General.Tun.Stack = C.TunGvisor
	cfg.General.Tun.FileDescriptor = dupFD
	cfg.General.Tun.AutoRoute = false
	cfg.General.Tun.AutoRedirect = false
	cfg.General.Tun.AutoDetectInterface = false
	cfg.General.Tun.StrictRoute = false
	cfg.General.Tun.MTU = 1500
	cfg.General.Tun.Inet4Address = []netip.Prefix{netip.MustParsePrefix("198.18.0.1/16")}
	cfg.General.Tun.Inet6Address = nil
	cfg.General.Tun.DNSHijack = []string{"any:53", "tcp://any:53"}
	cfg.General.Tun.IncludePackage = nil
	cfg.General.Tun.ExcludePackage = nil
	cfg.General.Tun.IncludeAndroidUser = nil
	cfg.General.Tun.IncludeUID = nil
	cfg.General.Tun.ExcludeUID = nil
	return nil
}

// startAndroidTunReceiver listens on an abstract Unix domain socket (@<name>) for
// Android VpnService to send the established TUN file descriptor via SCM_RIGHTS
// or a "STOP" command when the user turns off the VPN.
func startAndroidTunReceiver(socketName string, engine *DesktopEngine) error {
	name := strings.TrimSpace(socketName)
	if name == "" {
		return nil
	}
	if !strings.HasPrefix(name, "@") {
		name = "@" + name
	}
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: name, Net: "unix"})
	if err != nil {
		return fmt.Errorf("listen android tun socket %s: %w", name, err)
	}
	go func() {
		defer ln.Close()
		for {
			conn, err := ln.AcceptUnix()
			if err != nil {
				return
			}
			go handleAndroidTunConn(conn, engine)
		}
	}()
	return nil
}

func handleAndroidTunConn(conn *net.UnixConn, engine *DesktopEngine) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(15 * time.Second))

	f, err := conn.File()
	if err != nil {
		_, _ = conn.Write([]byte("ERR:conn file failed\n"))
		return
	}
	defer f.Close()

	buf := make([]byte, 256)
	oob := make([]byte, unix.CmsgSpace(4*4))
	n, oobn, _, _, err := unix.Recvmsg(int(f.Fd()), buf, oob, 0)
	if err != nil {
		_, _ = conn.Write([]byte("ERR:" + err.Error() + "\n"))
		return
	}
	cmd := strings.TrimSpace(string(buf[:n]))

	var receivedFD = -1
	if oobn > 0 {
		scms, parseErr := unix.ParseSocketControlMessage(oob[:oobn])
		if parseErr == nil {
			for _, scm := range scms {
				fds, fdErr := unix.ParseUnixRights(&scm)
				if fdErr == nil && len(fds) > 0 {
					receivedFD = fds[0]
					for _, extra := range fds[1:] {
						_ = unix.Close(extra)
					}
					break
				}
			}
		}
	}

	if strings.EqualFold(cmd, "STOP") || receivedFD < 0 {
		if receivedFD >= 0 {
			_ = unix.Close(receivedFD)
		}
		log.Infoln("[Android] Received VPN STOP command")
		_ = engine.SetAndroidTunFD(-1)
		_, _ = conn.Write([]byte("OK\n"))
		return
	}

	log.Infoln("[Android] Received VPN TUN fd=%d via SCM_RIGHTS", receivedFD)
	if err := engine.SetAndroidTunFD(receivedFD); err != nil {
		log.Errorln("[Android] Start core with TUN fd failed: %v", err)
		_, _ = conn.Write([]byte("ERR:" + err.Error() + "\n"))
		return
	}
	_, _ = conn.Write([]byte("OK\n"))
}

// Keep os import used across builds if needed
var _ = os.ErrInvalid
