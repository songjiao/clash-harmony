//go:build with_gvisor && unix

package sing_tun

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"syscall"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

// fdGVisorTun adapts a pre-opened HarmonyOS VPN TUN descriptor to tun.GVisorTun
// using standard Go os.File poller I/O instead of gVisor fdbased raw syscalls.
type fdGVisorTun struct {
	file      *os.File
	mtu       uint32
	closeOnce sync.Once
	closeErr  error
	writeMu   sync.Mutex
	writeBuf  []byte
}

var _ tun.GVisorTun = (*fdGVisorTun)(nil)

func newFDGVisorTun(options tun.Options) (*fdGVisorTun, error) {
	if options.FileDescriptor <= 0 {
		return nil, fmt.Errorf("invalid tun file descriptor: %d", options.FileDescriptor)
	}
	if err := unix.SetNonblock(options.FileDescriptor, true); err != nil {
		return nil, fmt.Errorf("set nonblock on tun fd %d: %w", options.FileDescriptor, err)
	}
	mtu := options.MTU
	if mtu == 0 {
		mtu = 1500
	}
	return &fdGVisorTun{
		file: os.NewFile(uintptr(options.FileDescriptor), "vpn-tun"),
		mtu:  mtu,
	}, nil
}

func isRetriableFDError(err error) bool {
	return errors.Is(err, unix.EINTR) ||
		errors.Is(err, unix.EAGAIN) ||
		errors.Is(err, unix.EWOULDBLOCK) ||
		errors.Is(err, syscall.EAGAIN) ||
		errors.Is(err, syscall.EWOULDBLOCK)
}

func (t *fdGVisorTun) Read(p []byte) (int, error) {
	return t.readPacket(p)
}

func (t *fdGVisorTun) readPacket(p []byte) (int, error) {
	for {
		n, err := t.file.Read(p)
		if n > 0 {
			return n, nil
		}
		if err != nil && isRetriableFDError(err) {
			continue
		}
		if err == nil && len(p) > 0 {
			continue
		}
		return n, err
	}
}

func (t *fdGVisorTun) Write(p []byte) (int, error) {
	return t.writeSinglePacket(p)
}

func (t *fdGVisorTun) writeSinglePacket(packet []byte) (int, error) {
	if len(packet) == 0 {
		return 0, nil
	}
	for {
		n, err := t.file.Write(packet)
		if n == 0 && err != nil && isRetriableFDError(err) {
			continue
		}
		if n == len(packet) {
			if err != nil && !isRetriableFDError(err) {
				return n, err
			}
			return n, nil
		}
		if n > 0 {
			if err != nil && !isRetriableFDError(err) {
				return n, err
			}
			return n, io.ErrShortWrite
		}
		if err != nil {
			return 0, err
		}
		return 0, io.ErrNoProgress
	}
}

func (t *fdGVisorTun) writeSlices(slices [][]byte) (int, error) {
	totalLen := 0
	for _, s := range slices {
		totalLen += len(s)
	}
	if totalLen == 0 {
		return 0, nil
	}
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	if cap(t.writeBuf) < totalLen {
		t.writeBuf = make([]byte, totalLen)
	}
	pkt := t.writeBuf[:totalLen]
	off := 0
	for _, s := range slices {
		off += copy(pkt[off:], s)
	}
	return t.writeSinglePacket(pkt)
}

func (t *fdGVisorTun) WritePacket(pkt *stack.PacketBuffer) (int, error) {
	if pkt == nil {
		return 0, nil
	}
	return t.writeSlices(pkt.AsSlices())
}

func (t *fdGVisorTun) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	return &fdGVisorEndpoint{tun: t}, stack.NICOptions{}, nil
}

func (t *fdGVisorTun) Close() error {
	t.closeOnce.Do(func() {
		if t.file != nil {
			t.closeErr = t.file.Close()
		}
	})
	return t.closeErr
}

type fdGVisorEndpoint struct {
	tun        *fdGVisorTun
	mu         sync.RWMutex
	dispatcher stack.NetworkDispatcher
	wg         sync.WaitGroup
	onClose    func()
}

var _ stack.LinkEndpoint = (*fdGVisorEndpoint)(nil)

func (e *fdGVisorEndpoint) MTU() uint32 {
	return e.tun.mtu
}

func (e *fdGVisorEndpoint) SetMTU(mtu uint32) {
	if mtu > 0 {
		e.tun.mtu = mtu
	}
}

func (e *fdGVisorEndpoint) MaxHeaderLength() uint16 {
	return 0
}

func (e *fdGVisorEndpoint) LinkAddress() tcpip.LinkAddress {
	return ""
}

func (e *fdGVisorEndpoint) SetLinkAddress(addr tcpip.LinkAddress) {}

func (e *fdGVisorEndpoint) Capabilities() stack.LinkEndpointCapabilities {
	return stack.CapabilityRXChecksumOffload
}

func (e *fdGVisorEndpoint) Attach(dispatcher stack.NetworkDispatcher) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if dispatcher == nil && e.dispatcher != nil {
		e.dispatcher = nil
		return
	}
	if dispatcher != nil && e.dispatcher == nil {
		e.dispatcher = dispatcher
		e.wg.Add(1)
		go e.dispatchLoop()
	}
}

func (e *fdGVisorEndpoint) dispatchLoop() {
	defer e.wg.Done()
	buf := make([]byte, 65536)
	for {
		n, err := e.tun.readPacket(buf)
		if err != nil {
			break
		}
		if n <= 0 {
			continue
		}
		var networkProtocol tcpip.NetworkProtocolNumber
		switch header.IPVersion(buf[:n]) {
		case header.IPv4Version:
			networkProtocol = header.IPv4ProtocolNumber
		case header.IPv6Version:
			networkProtocol = header.IPv6ProtocolNumber
		default:
			continue
		}
		e.mu.RLock()
		dispatcher := e.dispatcher
		e.mu.RUnlock()
		if dispatcher == nil {
			return
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
			Payload:           buffer.MakeWithData(buf[:n]),
			IsForwardedPacket: true,
		})
		dispatcher.DeliverNetworkPacket(networkProtocol, pkt)
		pkt.DecRef()
	}
	e.mu.RLock()
	onClose := e.onClose
	e.mu.RUnlock()
	if onClose != nil {
		onClose()
	}
}

func (e *fdGVisorEndpoint) IsAttached() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.dispatcher != nil
}

func (e *fdGVisorEndpoint) Wait() {
	e.wg.Wait()
}

func (e *fdGVisorEndpoint) ARPHardwareType() header.ARPHardwareType {
	return header.ARPHardwareNone
}

func (e *fdGVisorEndpoint) AddHeader(buffer *stack.PacketBuffer) {}

func (e *fdGVisorEndpoint) ParseHeader(ptr *stack.PacketBuffer) bool {
	return true
}

func (e *fdGVisorEndpoint) WritePackets(packetBufferList stack.PacketBufferList) (int, tcpip.Error) {
	var n int
	for _, packet := range packetBufferList.AsSlice() {
		if _, err := e.tun.writeSlices(packet.AsSlices()); err != nil {
			return n, &tcpip.ErrAborted{}
		}
		n++
	}
	return n, nil
}

func (e *fdGVisorEndpoint) Close() {
	_ = e.tun.Close()
}

func (e *fdGVisorEndpoint) SetOnCloseAction(f func()) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.onClose = f
}
