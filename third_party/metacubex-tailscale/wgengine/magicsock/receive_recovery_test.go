// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package magicsock

import (
	"errors"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/tailscale-wireguard-go/conn"
	"github.com/metacubex/tailscale/types/key"
)

type scriptedReadResult struct {
	payload []byte
	addr    netip.AddrPort
	err     error
}

type scriptedPacketConn struct {
	mu      sync.Mutex
	results []scriptedReadResult
	idx     int
	closed  atomic.Bool
	block   chan struct{}
}

func newScriptedPacketConn(results ...scriptedReadResult) *scriptedPacketConn {
	return &scriptedPacketConn{
		results: results,
		block:   make(chan struct{}),
	}
}

func (s *scriptedPacketConn) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 41641}
}

func (s *scriptedPacketConn) ReadFromUDPAddrPort(b []byte) (int, netip.AddrPort, error) {
	s.mu.Lock()
	var res scriptedReadResult
	hasRes := s.idx < len(s.results)
	if hasRes {
		res = s.results[s.idx]
		s.idx++
	}
	s.mu.Unlock()
	if hasRes {
		if res.err != nil {
			return 0, netip.AddrPort{}, res.err
		}
		n := copy(b, res.payload)
		return n, res.addr, nil
	}
	<-s.block
	return 0, netip.AddrPort{}, net.ErrClosed
}

func (s *scriptedPacketConn) WriteToUDPAddrPort(b []byte, addr netip.AddrPort) (int, error) {
	return len(b), nil
}

func (s *scriptedPacketConn) Close() error {
	if s.closed.CompareAndSwap(false, true) {
		close(s.block)
	}
	return nil
}

func (s *scriptedPacketConn) SetDeadline(time.Time) error      { return nil }
func (s *scriptedPacketConn) SetReadDeadline(time.Time) error  { return nil }
func (s *scriptedPacketConn) SetWriteDeadline(time.Time) error { return nil }

func opReadErr(errno syscall.Errno) error {
	return &net.OpError{
		Op:  "read",
		Net: "udp4",
		Err: &os.SyscallError{Syscall: "recvfrom", Err: errno},
	}
}

func TestMkReceiveFuncRecoversNonTemporaryErrorsAndClearsBroken(t *testing.T) {
	c := newTestConn(t)
	c.SetPrivateKey(key.NewNode())

	// Force >0 errors and ensure pacing (~100ms per error), health broken marking
	// when marked broken, and automatic clearing once a packet is read.
	wantPkt := []byte{4, 0, 0, 0, 1, 2, 3, 4}
	srcAddr := netip.MustParseAddrPort("127.0.0.1:51820")
	pc := newScriptedPacketConn(
		scriptedReadResult{err: opReadErr(syscall.ECONNRESET)},
		scriptedReadResult{err: opReadErr(syscall.ECONNRESET)},
		scriptedReadResult{payload: wantPkt, addr: srcAddr},
	)
	c.pconn4.mu.Lock()
	_ = c.pconn4.closeLocked()
	c.pconn4.setConnLocked(pc, "udp4", 1, c.controlKnobs)
	c.pconn4.mu.Unlock()

	healthItem := c.health.ReceiveFuncStats(0) // health.ReceiveIPv4
	healthItem.SetBroken(true)

	recvFn := c.receiveIPv4()
	bufs := [][]byte{make([]byte, 2048)}
	sizes := make([]int, 1)
	eps := make([]conn.Endpoint, 1)

	start := time.Now()
	n, err := recvFn(bufs, sizes, eps)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("recvFn returned unexpected error: %v", err)
	}
	if n != 1 || sizes[0] != len(wantPkt) {
		t.Fatalf("got (n=%d, size=%d), want (1, %d)", n, sizes[0], len(wantPkt))
	}
	if elapsed < 150*time.Millisecond {
		t.Fatalf("expected paced retries across 2 errors (>=150ms), got %v", elapsed)
	}
	if healthItem.Broken() {
		t.Fatal("expected healthItem.Broken() to clear after successful read")
	}
}

func TestMkReceiveFuncRebindsOnBadSocketAndRecovers(t *testing.T) {
	c := newTestConn(t)
	c.SetPrivateKey(key.NewNode())

	pc := newScriptedPacketConn(
		scriptedReadResult{err: opReadErr(syscall.EBADF)},
	)
	c.pconn4.mu.Lock()
	_ = c.pconn4.closeLocked()
	c.pconn4.setConnLocked(pc, "udp4", 1, c.controlKnobs)
	c.pconn4.mu.Unlock()

	recvFn := c.receiveIPv4()
	bufs := [][]byte{make([]byte, 2048)}
	sizes := make([]int, 1)
	eps := make([]conn.Endpoint, 1)

	type readRes struct {
		n   int
		err error
	}
	done := make(chan readRes, 1)
	go func() {
		n, err := recvFn(bufs, sizes, eps)
		done <- readRes{n, err}
	}()

	// Wait until EBADF triggers c.Rebind() and installs a fresh socket on pconn4.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if c.pconn4.currentConn() != pc && c.pconn4.Port() != 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if c.pconn4.currentConn() == pc {
		t.Fatal("expected EBADF to trigger Rebind and replace pconn4")
	}

	// Send a UDP datagram to the rebound socket and verify recvFn receives it.
	sender, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()

	want := []byte{4, 0, 0, 0, 9, 8, 7, 6}
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(c.pconn4.Port())}
	if _, err := sender.WriteToUDP(want, dst); err != nil {
		t.Fatal(err)
	}

	select {
	case res := <-done:
		if res.err != nil {
			t.Fatalf("recvFn failed after rebind: %v", res.err)
		}
		if res.n != 1 || sizes[0] != len(want) {
			t.Fatalf("got (n=%d, size=%d), want (1, %d)", res.n, sizes[0], len(want))
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for packet on rebound UDP socket")
	}
}

func TestMkReceiveFuncExitsOnNetErrClosedOrConnClose(t *testing.T) {
	t.Run("net_err_closed", func(t *testing.T) {
		c := newTestConn(t)
		pc := newScriptedPacketConn(scriptedReadResult{err: net.ErrClosed})
		c.pconn4.mu.Lock()
		_ = c.pconn4.closeLocked()
		c.pconn4.setConnLocked(pc, "udp4", 1, c.controlKnobs)
		c.pconn4.mu.Unlock()

		recvFn := c.receiveIPv4()
		bufs := [][]byte{make([]byte, 2048)}
		sizes := make([]int, 1)
		eps := make([]conn.Endpoint, 1)

		start := time.Now()
		_, err := recvFn(bufs, sizes, eps)
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("got err=%v, want net.ErrClosed", err)
		}
		if elapsed := time.Since(start); elapsed > 80*time.Millisecond {
			t.Fatalf("net.ErrClosed exit took too long: %v", elapsed)
		}
	})

	t.Run("conn_close_interrupts_retry_delay", func(t *testing.T) {
		c := newTestConn(t)
		pc := newScriptedPacketConn(scriptedReadResult{err: opReadErr(syscall.ECONNRESET)})
		c.pconn4.mu.Lock()
		_ = c.pconn4.closeLocked()
		c.pconn4.setConnLocked(pc, "udp4", 1, c.controlKnobs)
		c.pconn4.mu.Unlock()

		recvFn := c.receiveIPv4()
		bufs := [][]byte{make([]byte, 2048)}
		sizes := make([]int, 1)
		eps := make([]conn.Endpoint, 1)

		errCh := make(chan error, 1)
		go func() {
			_, err := recvFn(bufs, sizes, eps)
			errCh <- err
		}()
		time.Sleep(20 * time.Millisecond)
		_ = c.Close()

		select {
		case err := <-errCh:
			if !errors.Is(err, net.ErrClosed) {
				t.Fatalf("got err=%v, want net.ErrClosed", err)
			}
		case <-time.After(time.Second):
			t.Fatal("timed out waiting for Conn.Close to unblock recvFn")
		}
	})
}
