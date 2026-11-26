package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func main() {
	dataDirFlag := flag.String("data", "", "自定义数据目录（默认 %APPDATA%\\ClashHarmony）")
	uiAddrFlag := flag.String("ui", "", "Web 控制台监听地址（默认 127.0.0.1:9091）")
	headlessFlag := flag.Bool("headless", false, "无系统托盘模式运行（适合命令行/调试）")
	noBrowserFlag := flag.Bool("no-browser", false, "启动后不自动打开浏览器控制台")
	enableTunFlag := flag.Bool("enable-tun", false, "启动时开启 TUN 全局接管（配合管理员提权使用）")
	trayOnlyFlag := flag.Bool("tray-only", false, "仅启动系统托盘伴侣图标并连接后台系统服务")
	flag.Parse()

	if *trayOnlyFlag {
		uiAddr := strings.TrimSpace(*uiAddrFlag)
		if uiAddr == "" {
			uiAddr = defaultUIAddr
		}
		_ = RunRemoteTray("http://" + uiAddr)
		return
	}

	store, err := NewDataStore(*dataDirFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "init data store failed: %v\n", err)
		os.Exit(1)
	}

	settings := store.LoadSettings()
	uiAddr := settings.UIAddr
	if strings.TrimSpace(*uiAddrFlag) != "" {
		uiAddr = strings.TrimSpace(*uiAddrFlag)
		settings.UIAddr = uiAddr
		_ = store.SaveSettings(settings)
	}
	if uiAddr == "" {
		uiAddr = defaultUIAddr
	}
	uiURL := "http://" + uiAddr

	inService := isRunningAsWindowsService()
	if inService {
		*headlessFlag = true
		*noBrowserFlag = true
	}

	// Single-instance check: if already running (including as Windows Service), open the Web Console and exit.
	if !inService {
		if isAddrAlreadyListening(uiAddr) {
			if !*noBrowserFlag {
				_ = OpenBrowser(uiURL)
			}
			return
		}
	}
	releaseLock, isPrimary := AcquireSingleInstance()
	if !isPrimary {
		if !inService && !*noBrowserFlag {
			_ = OpenBrowser(uiURL)
		}
		return
	}
	defer releaseLock()

	if *enableTunFlag {
		if IsElevated() {
			settings.TunMode = true
			_ = store.SaveSettings(settings)
		}
	}

	engine := NewDesktopEngine(store)
	if inService {
		engine.SetServiceMode(true)
	}
	var tray *TrayApp
	var server *DesktopServer

	shutdown := func() {
		_ = engine.Stop()
		if server != nil {
			server.Stop()
		}
	}

	relaunchAdmin := func(enableTun bool) {
		if inService {
			return
		}
		args := []string{}
		if strings.TrimSpace(*dataDirFlag) != "" {
			args = append(args, "-data", *dataDirFlag)
		}
		if strings.TrimSpace(*uiAddrFlag) != "" {
			args = append(args, "-ui", *uiAddrFlag)
		}
		if enableTun {
			args = append(args, "-enable-tun")
		}
		// Release mutex & clean up current instance only after ShellExecuteW succeeds.
		if err := RelaunchElevated(args...); err != nil {
			return
		}
		shutdown()
		releaseLock()
		if tray != nil {
			tray.Close()
		}
		os.Exit(0)
	}

	startCoreAndServer := func() error {
		server = NewDesktopServer(store, engine, relaunchAdmin)
		boundAddr, err := server.Start(uiAddr)
		if err != nil {
			return fmt.Errorf("start UI server failed: %w", err)
		}
		uiURL = "http://" + boundAddr

		// Auto-start core if enabled and a profile already exists.
		if settings.AutoStartCore && (settings.ActiveProfileID != "" || len(store.ListProfiles()) > 0) {
			if err := engine.Start(); err != nil {
				fmt.Fprintf(os.Stderr, "auto-start core warning: %v\n", err)
			}
		}
		return nil
	}

	if inService {
		if err := runWindowsService(startCoreAndServer, shutdown); err != nil {
			fmt.Fprintf(os.Stderr, "windows service error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := startCoreAndServer(); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}

	if !*noBrowserFlag {
		go func() {
			time.Sleep(300 * time.Millisecond)
			_ = OpenBrowser(uiURL)
		}()
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	if *headlessFlag {
		fmt.Printf("Clash Harmony Desktop %s running at %s (data: %s)\n", appVersion, uiURL, store.BaseDir())
		<-sigCh
		shutdown()
		return
	}

	tray = NewTrayApp(engine, store, uiURL, shutdown, relaunchAdmin)
	engine.SetOnChange(func() {
		tray.Refresh()
	})
	go func() {
		<-sigCh
		tray.Close()
	}()

	if err := tray.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "tray exited with error: %v\n", err)
	}
	shutdown()
}
