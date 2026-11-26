//go:build windows

package main

import (
	"fmt"
	"net"
	"time"

	"golang.org/x/sys/windows/svc"
)

const windowsServiceName = "ClashHarmony"

func isRunningAsWindowsService() bool {
	inService, err := svc.IsWindowsService()
	return err == nil && inService
}

func isAddrAlreadyListening(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

type clashWindowsService struct {
	startFn func() error
	stopFn  func()
}

func (s *clashWindowsService) Execute(args []string, r <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	const cmdsAccepted = svc.AcceptStop | svc.AcceptShutdown
	changes <- svc.Status{State: svc.StartPending, WaitHint: 15000}

	if err := s.startFn(); err != nil {
		return false, 1
	}

	changes <- svc.Status{State: svc.Running, Accepts: cmdsAccepted}

	for c := range r {
		switch c.Cmd {
		case svc.Interrogate:
			changes <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			changes <- svc.Status{State: svc.StopPending, WaitHint: 10000}
			s.stopFn()
			return false, 0
		}
	}
	return false, 0
}

func runWindowsService(startFn func() error, stopFn func()) error {
	if err := svc.Run(windowsServiceName, &clashWindowsService{
		startFn: startFn,
		stopFn:  stopFn,
	}); err != nil {
		return fmt.Errorf("run windows service %s: %w", windowsServiceName, err)
	}
	return nil
}
