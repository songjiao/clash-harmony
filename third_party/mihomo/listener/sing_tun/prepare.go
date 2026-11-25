package sing_tun

import (
	"context"
	"net/netip"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"

	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing-tun/ping"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
)

type proxyResolver interface {
	ResolveProxy(metadata *C.Metadata) (C.Proxy, C.Rule, error)
}

type adapterUnwrapper interface {
	UnwrapAdapter() C.ProxyAdapter
}

type icmpDirectConnector interface {
	ConnectICMP(ctx context.Context, source, destination netip.Addr, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error)
}

func (h *ListenerHandler) resolveICMPConnector(source, destination netip.Addr) (icmpDirectConnector, string, string) {
	pr, ok := h.Tunnel.(proxyResolver)
	if !ok {
		return nil, "", ""
	}
	md := &C.Metadata{
		NetWork: C.TCP,
		Type:    C.TUN,
		SrcIP:   source,
		DstIP:   destination,
	}
	proxy, rule, err := pr.ResolveProxy(md)
	if err != nil || proxy == nil {
		return nil, "", ""
	}
	chainName := proxy.Name()
	for cur := proxy; cur != nil; cur = cur.Unwrap(md, false) {
		proxy = cur
		if cur.Name() != "" && cur.Name() != chainName {
			chainName = chainName + "[" + cur.Name() + "]"
		}
	}
	adapter := proxy.Adapter()
	for {
		unwrapper, ok := adapter.(adapterUnwrapper)
		if !ok {
			break
		}
		adapter = unwrapper.UnwrapAdapter()
	}
	conn, ok := adapter.(icmpDirectConnector)
	if !ok {
		return nil, "", ""
	}
	ruleDesc := "Match"
	if rule != nil {
		ruleDesc = rule.RuleType().String() + "(" + rule.Payload() + ")"
	}
	return conn, chainName, ruleDesc
}

func (h *ListenerHandler) PrepareConnection(network string, source M.Socksaddr, destination M.Socksaddr, routeContext tun.DirectRouteContext, timeout time.Duration) (tun.DirectRouteDestination, error) {
	switch network {
	case N.NetworkICMP: // our fork only send those type to PrepareConnection now
		if h.DisableICMPForwarding || h.skipPingForwardingByAddr(destination.Addr) { // skip if ICMP handling is disabled or other condition
			log.Infoln("[ICMP] %s %s --> %s using fake ping echo", network, source, destination)
			return nil, nil
		}
		if icmpConn, proxyName, ruleDesc := h.resolveICMPConnector(source.Addr, destination.Addr); icmpConn != nil {
			log.Infoln("[ICMP] %s %s --> %s match %s using %s", network, source, destination, ruleDesc, proxyName)
			dest, err := icmpConn.ConnectICMP(context.TODO(), source.Addr, destination.Addr, routeContext, timeout)
			if err != nil {
				log.Warnln("[ICMP] failed to connect to %s via %s: %v", destination, proxyName, err)
				return nil, err
			}
			return dest, nil
		}
		log.Infoln("[ICMP] %s %s --> %s using DIRECT", network, source, destination)
		directRouteDestination, err := ping.ConnectDestination(context.TODO(), log.SingLogger, dialer.ICMPControl(destination.Addr), destination.Addr, routeContext, timeout)
		if err != nil {
			log.Warnln("[ICMP] failed to connect to %s", destination)
			return nil, err
		}
		log.Debugln("[ICMP] success connect to %s", destination)
		return directRouteDestination, nil
	}
	return nil, nil
}

func (h *ListenerHandler) skipPingForwardingByAddr(addr netip.Addr) bool {
	for _, prefix := range h.Inet4Address { // skip in interface ipv4 range
		if prefix.Contains(addr) {
			return true
		}
	}
	for _, prefix := range h.Inet6Address { // skip in interface ipv6 range
		if prefix.Contains(addr) {
			return true
		}
	}
	if resolver.IsFakeIP(addr) { // skip in fakeIp pool
		return true
	}
	return false
}
