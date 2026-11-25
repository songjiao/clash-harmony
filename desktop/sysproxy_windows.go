//go:build windows

package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	internetSettingsKeyPath = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	runAutoStartKeyPath     = `Software\Microsoft\Windows\CurrentVersion\Run`
	autoStartValueName      = `ClashHarmony`

	internetOptionSettingsChanged = 39
	internetOptionRefresh         = 37
	swShowNormal                  = 1
)

var (
	wininetDLL          = windows.NewLazySystemDLL("wininet.dll")
	procInternetSetOptW = wininetDLL.NewProc("InternetSetOptionW")

	shell32DLL         = windows.NewLazySystemDLL("shell32.dll")
	procShellExecuteW  = shell32DLL.NewProc("ShellExecuteW")
)

type proxySnapshot struct {
	captured bool
	enable   uint32
	server   string
	override string
	hasSrv   bool
	hasOvr   bool
}

type SystemProxyManager struct {
	mu       sync.Mutex
	active   bool
	myServer string
	prev     proxySnapshot
}

func NewSystemProxyManager() *SystemProxyManager {
	return &SystemProxyManager{}
}

func (m *SystemProxyManager) IsActive() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.active
}

func notifyWinInetProxyChanged() {
	_, _, _ = procInternetSetOptW.Call(0, internetOptionSettingsChanged, 0, 0)
	_, _, _ = procInternetSetOptW.Call(0, internetOptionRefresh, 0, 0)
}

func (m *SystemProxyManager) Enable(serverAddr, bypass string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	k, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsKeyPath, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("open Internet Settings registry: %w", err)
	}
	defer k.Close()

	if !m.prev.captured {
		en, _, _ := k.GetIntegerValue("ProxyEnable")
		srv, _, sErr := k.GetStringValue("ProxyServer")
		ovr, _, oErr := k.GetStringValue("ProxyOverride")
		// Do not snapshot our own previous crash leftover as "original" proxy.
		if strings.EqualFold(strings.TrimSpace(srv), strings.TrimSpace(serverAddr)) {
			en = 0
		}
		m.prev = proxySnapshot{
			captured: true,
			enable:   uint32(en),
			server:   srv,
			override: ovr,
			hasSrv:   sErr == nil,
			hasOvr:   oErr == nil,
		}
	}

	if err := k.SetDWordValue("ProxyEnable", 1); err != nil {
		return err
	}
	if err := k.SetStringValue("ProxyServer", serverAddr); err != nil {
		return err
	}
	cleanBypass := strings.TrimSpace(bypass)
	if cleanBypass == "" {
		cleanBypass = defaultProxyBypassRules
	}
	if err := k.SetStringValue("ProxyOverride", cleanBypass); err != nil {
		return err
	}

	m.active = true
	m.myServer = serverAddr
	notifyWinInetProxyChanged()
	return nil
}

func (m *SystemProxyManager) Restore() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if !m.active {
		return nil
	}

	k, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsKeyPath, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		m.active = false
		return err
	}
	defer k.Close()

	curSrv, _, _ := k.GetStringValue("ProxyServer")
	// Only restore if another app hasn't taken over the proxy while we were running.
	if m.myServer == "" || strings.EqualFold(strings.TrimSpace(curSrv), strings.TrimSpace(m.myServer)) {
		if m.prev.captured {
			_ = k.SetDWordValue("ProxyEnable", m.prev.enable)
			if m.prev.hasSrv {
				_ = k.SetStringValue("ProxyServer", m.prev.server)
			} else {
				_ = k.DeleteValue("ProxyServer")
			}
			if m.prev.hasOvr {
				_ = k.SetStringValue("ProxyOverride", m.prev.override)
			} else {
				_ = k.DeleteValue("ProxyOverride")
			}
		} else {
			_ = k.SetDWordValue("ProxyEnable", 0)
		}
		notifyWinInetProxyChanged()
	}

	m.active = false
	m.myServer = ""
	m.prev = proxySnapshot{}
	return nil
}

func IsElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

func OpenBrowser(targetURL string) error {
	verb, _ := syscall.UTF16PtrFromString("open")
	file, _ := syscall.UTF16PtrFromString(targetURL)
	r, _, err := procShellExecuteW.Call(
		0,
		uintptr(unsafe.Pointer(verb)),
		uintptr(unsafe.Pointer(file)),
		0,
		0,
		swShowNormal,
	)
	if r <= 32 {
		return fmt.Errorf("ShellExecuteW failed (code=%d): %v", r, err)
	}
	return nil
}

func RelaunchElevated(extraArgs ...string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	wd, _ := os.Getwd()
	quotedArgs := make([]string, 0, len(extraArgs))
	for _, a := range extraArgs {
		if strings.ContainsAny(a, " \t\"") {
			quotedArgs = append(quotedArgs, `"`+strings.ReplaceAll(a, `"`, `\"`)+`"`)
		} else {
			quotedArgs = append(quotedArgs, a)
		}
	}
	verbPtr, _ := syscall.UTF16PtrFromString("runas")
	exePtr, _ := syscall.UTF16PtrFromString(exe)
	paramsPtr, _ := syscall.UTF16PtrFromString(strings.Join(quotedArgs, " "))
	dirPtr, _ := syscall.UTF16PtrFromString(wd)

	r, _, callErr := procShellExecuteW.Call(
		0,
		uintptr(unsafe.Pointer(verbPtr)),
		uintptr(unsafe.Pointer(exePtr)),
		uintptr(unsafe.Pointer(paramsPtr)),
		uintptr(unsafe.Pointer(dirPtr)),
		swShowNormal,
	)
	if r <= 32 {
		return fmt.Errorf("管理员提权启动被取消或失败 (code=%d): %v", r, callErr)
	}
	return nil
}

func IsAutoStartEnabled() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runAutoStartKeyPath, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	val, _, err := k.GetStringValue(autoStartValueName)
	return err == nil && strings.TrimSpace(val) != ""
}

func SetAutoStart(enable bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, runAutoStartKeyPath, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !enable {
		err := k.DeleteValue(autoStartValueName)
		if err == registry.ErrNotExist {
			return nil
		}
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := fmt.Sprintf(`"%s" -no-browser`, exe)
	return k.SetStringValue(autoStartValueName, cmd)
}

func AcquireSingleInstance() (func(), bool) {
	name, err := windows.UTF16PtrFromString(`Local\ClashHarmonyDesktopSingleton`)
	if err != nil {
		return func() {}, true
	}
	h, err := windows.CreateMutex(nil, false, name)
	if err == windows.ERROR_ALREADY_EXISTS {
		if h != 0 {
			_ = windows.CloseHandle(h)
		}
		return func() {}, false
	}
	if err != nil || h == 0 {
		return func() {}, true
	}
	return func() {
		_ = windows.CloseHandle(h)
	}, true
}
