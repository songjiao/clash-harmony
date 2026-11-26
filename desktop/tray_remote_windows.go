//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	cmdRemoteOpenUI  = 2001
	cmdRemoteToggle  = 2002
	cmdRemoteRestart = 2003
	cmdRemoteHide    = 2004
)

type RemoteTrayApp struct {
	uiURL  string
	client *http.Client

	mu          sync.Mutex
	hwnd        uintptr
	iconRunning uintptr
	iconStopped uintptr
	state       DesktopEngineState
	serviceUp   bool
	stopCh      chan struct{}
}

var activeRemoteTray *RemoteTrayApp

func acquireTrayCompanionSingleton() (func(), bool) {
	name, err := windows.UTF16PtrFromString(`Local\ClashHarmonyTrayCompanion`)
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

func RunRemoteTray(uiURL string) error {
	release, ok := acquireTrayCompanionSingleton()
	if !ok {
		_ = OpenBrowser(uiURL)
		return nil
	}
	defer release()

	app := &RemoteTrayApp{
		uiURL: strings.TrimRight(uiURL, "/"),
		client: &http.Client{
			Timeout: 3 * time.Second,
			Transport: &http.Transport{
				Proxy: nil, // Always talk directly to loopback Windows Service
			},
		},
		stopCh: make(chan struct{}),
	}
	return app.Run()
}

func (t *RemoteTrayApp) pollOnce() {
	resp, err := t.client.Get(t.uiURL + "/api/state")
	if err != nil {
		t.mu.Lock()
		changed := t.serviceUp
		t.serviceUp = false
		t.state = DesktopEngineState{}
		hwnd := t.hwnd
		t.mu.Unlock()
		if changed && hwnd != 0 {
			_, _, _ = procPostMessageW.Call(hwnd, wmTrayRefresh, 0, 0)
		}
		return
	}
	defer resp.Body.Close()

	var st DesktopEngineState
	if decErr := json.NewDecoder(resp.Body).Decode(&st); decErr != nil {
		return
	}
	t.mu.Lock()
	changed := !t.serviceUp || t.state.Running != st.Running || t.state.TunActive != st.TunActive
	t.serviceUp = true
	t.state = st
	hwnd := t.hwnd
	t.mu.Unlock()
	if changed && hwnd != 0 {
		_, _, _ = procPostMessageW.Call(hwnd, wmTrayRefresh, 0, 0)
	}
}

func (t *RemoteTrayApp) postAction(path string) {
	req, err := http.NewRequest(http.MethodPost, t.uiURL+path, nil)
	if err != nil {
		return
	}
	resp, err := t.client.Do(req)
	if err == nil && resp != nil {
		_ = resp.Body.Close()
	}
	time.Sleep(400 * time.Millisecond)
	t.pollOnce()
}

func (t *RemoteTrayApp) updateNotifyIcon(action uint32) {
	t.mu.Lock()
	up := t.serviceUp
	st := t.state
	hwnd := t.hwnd
	icon := t.iconStopped
	if up && st.Running {
		icon = t.iconRunning
	}
	t.mu.Unlock()

	statusText := "服务未响应"
	if up {
		if st.Running {
			if st.TunActive {
				statusText = "服务运行中 (TUN)"
			} else {
				statusText = "服务运行中"
			}
		} else {
			statusText = "核心已停止"
		}
	}
	tip := fmt.Sprintf("Clash Harmony — %s", statusText)

	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = hwnd
	nid.uID = 2
	nid.uFlags = nifMessage | nifIcon | nifTip
	nid.uCallbackMessage = wmTrayCallback
	nid.hIcon = icon
	u16, _ := syscall.UTF16FromString(tip)
	copy(nid.szTip[:len(nid.szTip)-1], u16)

	ret, _, _ := procShellNotifyIconW.Call(uintptr(action), uintptr(unsafe.Pointer(&nid)))
	if ret == 0 && action == nimModify {
		// If explorer restarted or initial NIM_ADD raced, re-add the icon cleanly.
		_, _, _ = procShellNotifyIconW.Call(uintptr(nimAdd), uintptr(unsafe.Pointer(&nid)))
	}
}

func (t *RemoteTrayApp) deleteNotifyIcon() {
	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = t.hwnd
	nid.uID = 2
	_, _, _ = procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
}

func (t *RemoteTrayApp) showContextMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)

	t.mu.Lock()
	up := t.serviceUp
	running := t.state.Running
	t.mu.Unlock()

	appendMenuItem(menu, mfString, cmdRemoteOpenUI, "打开控制台 (Web UI)")
	appendMenuItem(menu, mfSeparator, 0, "")
	if up && running {
		appendMenuItem(menu, mfString, cmdRemoteToggle, "停止核心")
	} else {
		appendMenuItem(menu, mfString, cmdRemoteToggle, "启动核心")
	}
	appendMenuItem(menu, mfString, cmdRemoteRestart, "重启核心")
	appendMenuItem(menu, mfSeparator, 0, "")
	appendMenuItem(menu, mfString, cmdRemoteHide, "隐藏托盘图标 (后台服务继续运行)")

	var pt point
	_, _, _ = procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	_, _, _ = procSetForegroundWnd.Call(t.hwnd)
	_, _, _ = procTrackPopupMenu.Call(menu, tpmRightButton|tpmBottomAlign, uintptr(pt.x), uintptr(pt.y), 0, t.hwnd, 0)
	_, _, _ = procPostMessageW.Call(t.hwnd, wmNull, 0, 0)
}

func (t *RemoteTrayApp) handleCommand(cmdID uintptr) {
	switch cmdID {
	case cmdRemoteOpenUI:
		go func() { _ = OpenBrowser(t.uiURL) }()
	case cmdRemoteToggle:
		go func() {
			t.mu.Lock()
			running := t.serviceUp && t.state.Running
			t.mu.Unlock()
			if running {
				t.postAction("/api/core/stop")
			} else {
				t.postAction("/api/core/start")
			}
		}()
	case cmdRemoteRestart:
		go t.postAction("/api/core/restart")
	case cmdRemoteHide:
		_, _, _ = procPostMessageW.Call(t.hwnd, wmClose, 0, 0)
	}
}

func remoteTrayWndProc(hwnd uintptr, msg uint32, wParam, lParam uintptr) uintptr {
	t := activeRemoteTray
	if t != nil {
		switch msg {
		case wmTrayCallback:
			switch lParam {
			case wmLButtonUp, wmLButtonDblClk:
				go func() { _ = OpenBrowser(t.uiURL) }()
				return 0
			case wmRButtonUp:
				t.showContextMenu()
				return 0
			}
		case wmTrayRefresh:
			t.updateNotifyIcon(nimModify)
			return 0
		case wmCommand:
			t.handleCommand(wParam & 0xffff)
			return 0
		case wmClose:
			t.deleteNotifyIcon()
			_, _, _ = procDestroyWindow.Call(hwnd)
			return 0
		case wmDestroy:
			_, _, _ = procPostQuitMessage.Call(0)
			return 0
		}
	}
	ret, _, _ := procDefWindowProcW.Call(hwnd, uintptr(msg), wParam, lParam)
	return ret
}

func (t *RemoteTrayApp) Run() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	activeRemoteTray = t
	t.iconRunning = createStatusIcon(16, 185, 129) // emerald green
	t.iconStopped = createStatusIcon(100, 116, 139) // slate gray
	defer func() {
		close(t.stopCh)
		if t.iconRunning != 0 {
			_, _, _ = procDestroyIcon.Call(t.iconRunning)
		}
		if t.iconStopped != 0 {
			_, _, _ = procDestroyIcon.Call(t.iconStopped)
		}
	}()

	hInst, _, _ := procGetModuleHandleW.Call(0)
	className, _ := syscall.UTF16PtrFromString("ClashHarmonyRemoteTrayClass")
	title, _ := syscall.UTF16PtrFromString("Clash Harmony Tray")

	wc := wndClassExW{
		cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		lpfnWndProc:   syscall.NewCallback(remoteTrayWndProc),
		hInstance:     hInst,
		lpszClassName: className,
	}
	_, _, _ = procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	hwnd, _, err := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		wsOverlappedWindow,
		0, 0, 0, 0,
		0, 0, hInst, 0,
	)
	if hwnd == 0 {
		return fmt.Errorf("CreateWindowExW failed: %v", err)
	}

	t.mu.Lock()
	t.hwnd = hwnd
	t.mu.Unlock()

	t.pollOnce()
	t.updateNotifyIcon(nimAdd)

	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-t.stopCh:
				return
			case <-ticker.C:
				t.pollOnce()
			}
		}
	}()

	var m msgStruct
	for {
		ret, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		_, _, _ = procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		_, _, _ = procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	return nil
}
