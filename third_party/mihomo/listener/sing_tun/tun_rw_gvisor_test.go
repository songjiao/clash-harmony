//go:build with_gvisor && unix

package sing_tun

import (
	"context"
	"encoding/binary"
	"net"
	"net/netip"
	"testing"
	"time"

	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common/buf"
	"github.com/metacubex/sing/common/logger"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	"golang.org/x/sys/unix"
)

type testTunHandler struct {
	pktCh chan M.Metadata
}

func (h *testTunHandler) PrepareConnection(string, M.Socksaddr, M.Socksaddr, tun.DirectRouteContext, time.Duration) (tun.DirectRouteDestination, error) {
	return nil, nil
}

func (h *testTunHandler) NewConnection(context.Context, net.Conn, M.Metadata) error {
	return nil
}

func (h *testTunHandler) NewPacket(_ context.Context, _ netip.AddrPort, buffer *buf.Buffer, metadata M.Metadata, _ func(N.PacketConn) N.PacketWriter) {
	if buffer != nil {
		buffer.Release()
	}
	select {
	case h.pktCh <- metadata:
	default:
	}
}

func (h *testTunHandler) NewError(context.Context, error) {}

func buildTestIPv4UDP(srcIP, dstIP [4]byte, srcPort, dstPort uint16, payload []byte) []byte {
	totalLen := header.IPv4MinimumSize + header.UDPMinimumSize + len(payload)
	pkt := make([]byte, totalLen)
	ipHdr := header.IPv4(pkt)
	ipHdr.Encode(&header.IPv4Fields{
		TotalLength: uint16(totalLen),
		TTL:         64,
		Protocol:    uint8(header.UDPProtocolNumber),
		SrcAddr:     header.IPv4(pkt).SourceAddress(), // overwritten below
	})
	copy(pkt[12:16], srcIP[:])
	copy(pkt[16:20], dstIP[:])
	ipHdr.SetChecksum(0)
	ipHdr.SetChecksum(^ipHdr.CalculateChecksum())

	udpHdr := header.UDP(pkt[header.IPv4MinimumSize:])
	binary.BigEndian.PutUint16(udpHdr[0:2], srcPort)
	binary.BigEndian.PutUint16(udpHdr[2:4], dstPort)
	binary.BigEndian.PutUint16(udpHdr[4:6], uint16(header.UDPMinimumSize+len(payload)))
	copy(pkt[header.IPv4MinimumSize+header.UDPMinimumSize:], payload)
	xsum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, ipHdr.SourceAddress(), ipHdr.DestinationAddress(), uint16(header.UDPMinimumSize+len(payload)))
	udpHdr.SetChecksum(^udpHdr.CalculateChecksum(xsum))
	return pkt
}

func TestFDGVisorTunStartsReceivesAndClosesCleanly(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatalf("Socketpair: %v", err)
	}
	defer unix.Close(fds[1])

	opts := tun.Options{
		Name:           "vpn-tun",
		MTU:            1500,
		Inet4Address:   []netip.Prefix{netip.MustParsePrefix("198.18.0.1/16")},
		AutoRoute:      false,
		FileDescriptor: fds[0],
	}
	tunIf, err := newFDGVisorTun(opts)
	if err != nil {
		_ = unix.Close(fds[0])
		t.Fatalf("newFDGVisorTun: %v", err)
	}

	handler := &testTunHandler{pktCh: make(chan M.Metadata, 4)}
	gStack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:                context.Background(),
		Tun:                    tunIf,
		TunOptions:             opts,
		EndpointIndependentNat: true,
		UDPTimeout:             5 * time.Minute,
		ICMPTimeout:            10 * time.Second,
		Handler:                handler,
		Logger:                 logger.NOP(),
	})
	if err != nil {
		_ = tunIf.Close()
		t.Fatalf("tun.NewStack: %v", err)
	}
	if err := gStack.Start(); err != nil {
		_ = tunIf.Close()
		t.Fatalf("gStack.Start: %v", err)
	}

	// Send an IPv4 UDP packet into peer fd and verify gVisor delivers it to handler.
	pkt := buildTestIPv4UDP([4]byte{198, 18, 0, 1}, [4]byte{10, 0, 0, 1}, 12345, 5353, []byte("hi"))
	if _, err := unix.Write(fds[1], pkt); err != nil {
		t.Fatalf("peer write: %v", err)
	}
	select {
	case meta := <-handler.pktCh:
		if meta.Destination.Port != 5353 {
			t.Fatalf("unexpected destination: %v", meta.Destination)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for packet via fdGVisorTun")
	}

	// Verify outbound Write delivers a complete packet back to the peer socket.
	reply := buildTestIPv4UDP([4]byte{10, 0, 0, 1}, [4]byte{198, 18, 0, 1}, 5353, 12345, []byte("ok"))
	if n, err := tunIf.Write(reply); err != nil || n != len(reply) {
		t.Fatalf("tunIf.Write = (%d, %v), want (%d, nil)", n, err, len(reply))
	}
	readBuf := make([]byte, 256)
	rn, err := unix.Read(fds[1], readBuf)
	if err != nil || rn != len(reply) {
		t.Fatalf("peer read = (%d, %v), want (%d, nil)", rn, err, len(reply))
	}

	// Verify shutdown completes quickly without blocking on netpoller read.
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = gStack.Close()
		_ = tunIf.Close()
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out closing fdGVisorTun stack")
	}
}

var _ stack.LinkEndpoint = (*fdGVisorEndpoint)(nil)
