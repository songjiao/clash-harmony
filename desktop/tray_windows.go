//go:build windows

package main

import (
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	wsOverlappedWindow = 0x00CF0000

	wmDestroy         = 0x0002
	wmCommand         = 0x0111
	wmClose           = 0x0010
	wmNull            = 0x0000
	wmPowerBroadcast  = 0x0218
	pbtApmResumeSusp  = 0x0007
	pbtApmResumeAuto  = 0x0012
	wmLButtonUp       = 0x0202
	wmLButtonDblClk = 0x0203
	wmRButtonUp     = 0x0205
	wmTrayCallback  = 0x0400 + 1 // WM_USER + 1
	wmTrayRefresh   = 0x0400 + 2 // WM_USER + 2

	nimAdd    = 0x00000000
	nimModify = 0x00000001
	nimDelete = 0x00000002

	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004

	mfString    = 0x00000000
	mfSeparator = 0x00000800
	mfChecked   = 0x00000008
	mfGrayed    = 0x00000001

	tpmRightButton = 0x0002
	tpmBottomAlign = 0x0020

	cmdOpenUI    = 1001
	cmdToggleRun = 1002
	cmdToggleSys = 1003
	cmdToggleTun = 1004
	cmdAutoStart = 1005
	cmdQuit      = 1006
)

var (
	user32DLL             = windows.NewLazySystemDLL("user32.dll")
	gdi32DLL              = windows.NewLazySystemDLL("gdi32.dll")
	kernel32DLL           = windows.NewLazySystemDLL("kernel32.dll")
	procRegisterClassExW  = user32DLL.NewProc("RegisterClassExW")
	procCreateWindowExW   = user32DLL.NewProc("CreateWindowExW")
	procDefWindowProcW    = user32DLL.NewProc("DefWindowProcW")
	procDestroyWindow     = user32DLL.NewProc("DestroyWindow")
	procGetMessageW       = user32DLL.NewProc("GetMessageW")
	procTranslateMessage  = user32DLL.NewProc("TranslateMessage")
	procDispatchMessageW  = user32DLL.NewProc("DispatchMessageW")
	procPostMessageW      = user32DLL.NewProc("PostMessageW")
	procPostQuitMessage   = user32DLL.NewProc("PostQuitMessage")
	procCreatePopupMenu   = user32DLL.NewProc("CreatePopupMenu")
	procAppendMenuW       = user32DLL.NewProc("AppendMenuW")
	procDestroyMenu       = user32DLL.NewProc("DestroyMenu")
	procTrackPopupMenu    = user32DLL.NewProc("TrackPopupMenu")
	procSetForegroundWnd  = user32DLL.NewProc("SetForegroundWindow")
	procGetCursorPos      = user32DLL.NewProc("GetCursorPos")
	procCreateIconIndir   = user32DLL.NewProc("CreateIconIndirect")
	procDestroyIcon       = user32DLL.NewProc("DestroyIcon")
	procShellNotifyIconW  = shell32DLL.NewProc("Shell_NotifyIconW")
	procGetModuleHandleW  = kernel32DLL.NewProc("GetModuleHandleW")
	procCreateDIBSection  = gdi32DLL.NewProc("CreateDIBSection")
	procCreateBitmap      = gdi32DLL.NewProc("CreateBitmap")
	procDeleteObject      = gdi32DLL.NewProc("DeleteObject")
)

type wndClassExW struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type point struct {
	x int32
	y int32
}

type msgStruct struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

type notifyIconDataW struct {
	cbSize           uint32
	hWnd             uintptr
	uID              uint32
	uFlags           uint32
	uCallbackMessage uint32
	hIcon            uintptr
	szTip            [128]uint16
	dwState          uint32
	dwStateMask      uint32
	szInfo           [256]uint16
	uVersion         uint32
	szInfoTitle      [64]uint16
	dwInfoFlags      uint32
	guidItem         windows.GUID
	hBalloonIcon     uintptr
}

type bitmapInfoHeader struct {
	biSize          uint32
	biWidth         int32
	biHeight        int32
	biPlanes        uint16
	biBitCount      uint16
	biCompression   uint32
	biSizeImage     uint32
	biXPelsPerMeter int32
	biYPelsPerMeter int32
	biClrUsed       uint32
	biClrImportant  uint32
}

type iconInfo struct {
	fIcon    uint32
	xHotspot uint32
	yHotspot uint32
	hbmMask  uintptr
	hbmColor uintptr
}

type TrayApp struct {
	engine      *DesktopEngine
	store       *DataStore
	uiURL       string
	onQuit      func()
	onElevate   func(enableTun bool)

	mu          sync.Mutex
	hwnd        uintptr
	iconRunning uintptr
	iconStopped uintptr
	quitOnce    sync.Once
}

var activeTray *TrayApp

func NewTrayApp(engine *DesktopEngine, store *DataStore, uiURL string, onQuit func(), onElevate func(enableTun bool)) *TrayApp {
	return &TrayApp{
		engine:    engine,
		store:     store,
		uiURL:     uiURL,
		onQuit:    onQuit,
		onElevate: onElevate,
	}
}

func (t *TrayApp) Refresh() {
	t.mu.Lock()
	hwnd := t.hwnd
	t.mu.Unlock()
	if hwnd != 0 {
		_, _, _ = procPostMessageW.Call(hwnd, wmTrayRefresh, 0, 0)
	}
}

func (t *TrayApp) Close() {
	t.mu.Lock()
	hwnd := t.hwnd
	t.mu.Unlock()
	if hwnd != 0 {
		_, _, _ = procPostMessageW.Call(hwnd, wmClose, 0, 0)
	}
}

func createStatusIcon(r, g, b byte) uintptr {
	const size = 16
	var bih bitmapInfoHeader
	bih.biSize = uint32(unsafe.Sizeof(bih))
	bih.biWidth = size
	bih.biHeight = -size // top-down DIB
	bih.biPlanes = 1
	bih.biBitCount = 32
	bih.biCompression = 0 // BI_RGB

	var bits unsafe.Pointer
	hColor, _, _ := procCreateDIBSection.Call(
		0,
		uintptr(unsafe.Pointer(&bih)),
		0,
		uintptr(unsafe.Pointer(&bits)),
		0,
		0,
	)
	if hColor == 0 || bits == nil {
		return 0
	}
	defer procDeleteObject.Call(hColor)

	buf := unsafe.Slice((*byte)(bits), size*size*4)
	cx, cy := 7.5, 7.5
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			dx := float64(x) - cx
			dy := float64(y) - cy
			dist2 := dx*dx + dy*dy
			off := (y*size + x) * 4
			if dist2 <= 52.0 {
				// Outer crisp ring + inner bright core
				if dist2 >= 34.0 {
					buf[off+0] = byte(int(b) * 3 / 4)
					buf[off+1] = byte(int(g) * 3 / 4)
					buf[off+2] = byte(int(r) * 3 / 4)
					buf[off+3] = 255
				} else if (x >= 6 && x <= 9 && y >= 4 && y <= 11) || (y >= 6 && y <= 9 && x >= 4 && x <= 11) {
					// Small crisp white cross/hub center symbolizing proxy+mesh
					buf[off+0] = 255
					buf[off+1] = 255
					buf[off+2] = 255
					buf[off+3] = 255
				} else {
					buf[off+0] = b
					buf[off+1] = g
					buf[off+2] = r
					buf[off+3] = 255
				}
			} else {
				buf[off+0] = 0
				buf[off+1] = 0
				buf[off+2] = 0
				buf[off+3] = 0
			}
		}
	}

	maskBytes := make([]byte, size*2)
	hMask, _, _ := procCreateBitmap.Call(size, size, 1, 1, uintptr(unsafe.Pointer(&maskBytes[0])))
	if hMask == 0 {
		return 0
	}
	defer procDeleteObject.Call(hMask)

	ii := iconInfo{
		fIcon:    1,
		hbmMask:  hMask,
		hbmColor: hColor,
	}
	hIcon, _, _ := procCreateIconIndir.Call(uintptr(unsafe.Pointer(&ii)))
	return hIcon
}

func (t *TrayApp) updateNotifyIcon(action uint32) {
	st := t.engine.State()
	icon := t.iconStopped
	statusText := "已停止"
	if st.Running {
		icon = t.iconRunning
		if st.TunActive {
			statusText = "运行中 (TUN)"
		} else if st.SystemProxyActive {
			statusText = "运行中 (系统代理)"
		} else {
			statusText = "运行中"
		}
	}
	tip := fmt.Sprintf("Clash Harmony %s — %s", appVersion, statusText)

	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = t.hwnd
	nid.uID = 1
	nid.uFlags = nifMessage | nifIcon | nifTip
	nid.uCallbackMessage = wmTrayCallback
	nid.hIcon = icon
	u16, _ := syscall.UTF16FromString(tip)
	copy(nid.szTip[:len(nid.szTip)-1], u16)

	_, _, _ = procShellNotifyIconW.Call(uintptr(action), uintptr(unsafe.Pointer(&nid)))
}

func (t *TrayApp) deleteNotifyIcon() {
	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = t.hwnd
	nid.uID = 1
	_, _, _ = procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
}

func appendMenuItem(menu uintptr, flags uint32, id uintptr, text string) {
	if flags&mfSeparator != 0 {
		_, _, _ = procAppendMenuW.Call(menu, uintptr(flags), 0, 0)
		return
	}
	ptr, _ := syscall.UTF16PtrFromString(text)
	_, _, _ = procAppendMenuW.Call(menu, uintptr(flags), id, uintptr(unsafe.Pointer(ptr)))
}

func (t *TrayApp) showContextMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)

	st := t.engine.State()
	appendMenuItem(menu, mfString, cmdOpenUI, "打开控制台 (Web UI)")
	appendMenuItem(menu, mfSeparator, 0, "")

	if st.Running {
		appendMenuItem(menu, mfString, cmdToggleRun, "停止核心")
	} else {
		appendMenuItem(menu, mfString, cmdToggleRun, "启动核心")
	}

	sysFlags := uint32(mfString)
	if st.SystemProxyWanted {
		sysFlags |= mfChecked
	}
	appendMenuItem(menu, sysFlags, cmdToggleSys, "系统代理")

	tunFlags := uint32(mfString)
	if st.TunWanted {
		tunFlags |= mfChecked
	}
	tunLabel := "TUN 全局接管"
	if !st.Elevated && !st.TunWanted {
		tunLabel = "TUN 全局接管 (需管理员提权)"
	}
	appendMenuItem(menu, tunFlags, cmdToggleTun, tunLabel)

	autoFlags := uint32(mfString)
	if st.StartWithWindows {
		autoFlags |= mfChecked
	}
	appendMenuItem(menu, autoFlags, cmdAutoStart, "开机自启")

	appendMenuItem(menu, mfSeparator, 0, "")
	appendMenuItem(menu, mfString, cmdQuit, "退出 Clash Harmony")

	var pt point
	_, _, _ = procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	_, _, _ = procSetForegroundWnd.Call(t.hwnd)
	_, _, _ = procTrackPopupMenu.Call(menu, tpmRightButton|tpmBottomAlign, uintptr(pt.x), uintptr(pt.y), 0, t.hwnd, 0)
	_, _, _ = procPostMessageW.Call(t.hwnd, wmNull, 0, 0)
}

func (t *TrayApp) handleCommand(cmdID uintptr) {
	switch cmdID {
	case cmdOpenUI:
		go func() { _ = OpenBrowser(t.uiURL) }()
	case cmdToggleRun:
		go func() {
			if t.engine.State().Running {
				_ = t.engine.Stop()
			} else {
				_ = t.engine.Start()
			}
		}()
	case cmdToggleSys:
		go func() {
			cfg := t.store.LoadSettings()
			cfg.SystemProxy = !cfg.SystemProxy
			_ = t.store.SaveSettings(cfg)
			_ = t.engine.UpdateSystemProxyState()
		}()
	case cmdToggleTun:
		go func() {
			cfg := t.store.LoadSettings()
			nextTun := !cfg.TunMode
			if nextTun && !IsElevated() {
				if t.onElevate != nil {
					t.onElevate(true)
				}
				return
			}
			cfg.TunMode = nextTun
			_ = t.store.SaveSettings(cfg)
			if t.engine.State().Running {
				_ = t.engine.Restart()
			} else {
				t.Refresh()
			}
		}()
	case cmdAutoStart:
		go func() {
			next := !IsAutoStartEnabled()
			_ = SetAutoStart(next)
			cfg := t.store.LoadSettings()
			cfg.StartWithWindows = next
			_ = t.store.SaveSettings(cfg)
			t.Refresh()
		}()
	case cmdQuit:
		t.Close()
	}
}

func trayWndProc(hwnd uintptr, msg uint32, wParam, lParam uintptr) uintptr {
	t := activeTray
	if t != nil {
		switch msg {
		case wmTrayCallback:
			switch uint32(lParam) {
			case wmLButtonDblClk, wmLButtonUp:
				go func() { _ = OpenBrowser(t.uiURL) }()
				return 0
			case wmRButtonUp:
				t.showContextMenu()
				return 0
			}
		case wmTrayRefresh:
			t.updateNotifyIcon(nimModify)
			return 0
		case wmPowerBroadcast:
			if wParam == pbtApmResumeAuto || wParam == pbtApmResumeSusp {
				t.engine.RecoverAfterResume()
			}
			return 1
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

// Run starts the Win32 message loop and blocks until the user exits from the tray or Close() is called.
func (t *TrayApp) Run() error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	activeTray = t
	t.iconRunning = createStatusIcon(16, 185, 129) // emerald green
	t.iconStopped = createStatusIcon(100, 116, 139) // slate gray
	defer func() {
		if t.iconRunning != 0 {
			_, _, _ = procDestroyIcon.Call(t.iconRunning)
		}
		if t.iconStopped != 0 {
			_, _, _ = procDestroyIcon.Call(t.iconStopped)
		}
		t.quitOnce.Do(func() {
			if t.onQuit != nil {
				t.onQuit()
			}
		})
	}()

	hInst, _, _ := procGetModuleHandleW.Call(0)
	className, _ := syscall.UTF16PtrFromString("ClashHarmonyTrayClass")
	title, _ := syscall.UTF16PtrFromString("Clash Harmony")

	wc := wndClassExW{
		cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		lpfnWndProc:   syscall.NewCallback(trayWndProc),
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

	t.updateNotifyIcon(nimAdd)

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
