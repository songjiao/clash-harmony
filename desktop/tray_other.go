//go:build !windows

package main

type TrayApp struct {
	done chan struct{}
}

func NewTrayApp(engine *DesktopEngine, store *DataStore, uiURL string, onQuit func(), onElevate func(enableTun bool)) *TrayApp {
	return &TrayApp{done: make(chan struct{})}
}

func (t *TrayApp) Refresh() {}

func (t *TrayApp) Close() {
	select {
	case <-t.done:
	default:
		close(t.done)
	}
}

func (t *TrayApp) Run() error {
	<-t.done
	return nil
}
