package main

import (
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/metacubex/tailscale/net/netmon"
)

const networkChangeDebounce = 250 * time.Millisecond

type NetworkChangeEvent struct {
	IfaceName         string `json:"ifaceName"`
	Gateway           string `json:"gateway"`
	Reason            string `json:"reason"`
	RebindTailscale   bool   `json:"rebindTailscale"`
	PruneNonTailscale bool   `json:"pruneNonTailscale"`
}

type NetworkChangeStats struct {
	EventCount      int64  `json:"eventCount"`
	LastReason      string `json:"lastReason"`
	LastIface       string `json:"lastIface"`
	LastGateway     string `json:"lastGateway"`
	LastAt          string `json:"lastAt,omitempty"`
	LastTSNotified  int    `json:"lastTsNotified"`
	LastPrunedNonTS int    `json:"lastPrunedNonTs"`
	LastKeptTS      int    `json:"lastKeptTs"`
}

type networkChangeCoordinator struct {
	mu      sync.Mutex
	pending *NetworkChangeEvent
	timer   *time.Timer
	stats   NetworkChangeStats
}

var mobileNetCoordinator = &networkChangeCoordinator{}

func (c *networkChangeCoordinator) Trigger(ev NetworkChangeEvent) {
	ev.IfaceName = strings.TrimSpace(ev.IfaceName)
	ev.Gateway = strings.TrimSpace(ev.Gateway)
	ev.Reason = strings.TrimSpace(ev.Reason)
	if ev.Reason == "" {
		ev.Reason = "host-network-change"
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.pending == nil {
		copied := ev
		c.pending = &copied
	} else {
		if ev.IfaceName != "" || ev.Reason == "net-lost" {
			c.pending.IfaceName = ev.IfaceName
		}
		if ev.Gateway != "" || ev.Reason == "net-lost" {
			c.pending.Gateway = ev.Gateway
		}
		c.pending.Reason = ev.Reason
		c.pending.RebindTailscale = c.pending.RebindTailscale || ev.RebindTailscale
		c.pending.PruneNonTailscale = c.pending.PruneNonTailscale || ev.PruneNonTailscale
	}

	if c.timer != nil {
		c.timer.Reset(networkChangeDebounce)
		return
	}
	c.timer = time.AfterFunc(networkChangeDebounce, c.flush)
}

func (c *networkChangeCoordinator) Stats() NetworkChangeStats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stats
}

func (c *networkChangeCoordinator) flush() {
	c.mu.Lock()
	ev := c.pending
	c.pending = nil
	c.timer = nil
	c.mu.Unlock()

	if ev == nil {
		return
	}
	tsNotified, prunedNonTS, keptTS := applyNetworkChange(*ev)

	c.mu.Lock()
	c.stats.EventCount++
	c.stats.LastReason = ev.Reason
	c.stats.LastIface = ev.IfaceName
	c.stats.LastGateway = ev.Gateway
	c.stats.LastAt = time.Now().Format(time.RFC3339)
	c.stats.LastTSNotified = tsNotified
	c.stats.LastPrunedNonTS = prunedNonTS
	c.stats.LastKeptTS = keptTS
	c.mu.Unlock()
}

func collectTailscaleOutbounds() ([]*outbound.Tailscale, map[string]bool) {
	var list []*outbound.Tailscale
	names := make(map[string]bool)
	for _, proxy := range tunnel.Proxies() {
		if proxy == nil || proxy.Type() != C.Tailscale {
			continue
		}
		names[strings.ToLower(proxy.Name())] = true
		adapter := proxy.Adapter()
		for {
			unwrapper, ok := adapter.(adapterUnwrapper)
			if !ok {
				break
			}
			adapter = unwrapper.UnwrapAdapter()
		}
		if tsProxy, ok := adapter.(*outbound.Tailscale); ok {
			list = append(list, tsProxy)
		}
	}
	return list, names
}

func isTailscaleConnectionChain(chain C.Chain, tsNames map[string]bool) bool {
	for _, hop := range chain {
		lower := strings.ToLower(strings.TrimSpace(hop))
		if lower == "" {
			continue
		}
		if tsNames[lower] || lower == "tailscale" {
			return true
		}
	}
	return false
}

// applyNetworkChange coordinates a Mosh-like fast roaming recovery:
//   - Updates Tailscale netmon default route/gateway hints and triggers MagicSock Rebind/ReSTUN
//     so WireGuard + inner Tailscale TCP sessions roam across Wi-Fi <-> 5G seamlessly.
//   - Flushes Mihomo interface cache and resets stale upstream DNS sockets.
//   - Selectively closes only non-Tailscale (public proxy / direct) stale connections on real
//     bearer switches so apps fail fast and reconnect immediately instead of hanging 60-120s,
//     while preserving all active Tailscale TCP/UDP sessions untouched.
func applyNetworkChange(ev NetworkChangeEvent) (tsNotified int, prunedNonTS int, keptTS int) {
	netmon.UpdateLastKnownDefaultRouteInterface(ev.IfaceName)
	netmon.UpdateLastKnownDefaultGateway(ev.Gateway)

	iface.FlushCache()
	resolver.ClearCache()
	resolver.ResetConnection()

	tsOutbounds, tsNames := collectTailscaleOutbounds()
	for _, tsProxy := range tsOutbounds {
		tsProxy.NotifyNetworkChange(ev.RebindTailscale, ev.Reason)
		tsNotified++
	}

	if ev.PruneNonTailscale && statistic.DefaultManager != nil {
		var toClose []statistic.Tracker
		statistic.DefaultManager.Range(func(tr statistic.Tracker) bool {
			if tr == nil {
				return true
			}
			info := tr.Info()
			if info != nil && isTailscaleConnectionChain(info.Chain, tsNames) {
				keptTS++
				return true
			}
			toClose = append(toClose, tr)
			return true
		})
		for _, tr := range toClose {
			_ = tr.Close()
			prunedNonTS++
		}
	}

	log.Infoln("[NetChange] reason=%s iface=%q gw=%q rebindTS=%v pruneNonTS=%v tsNotified=%d prunedNonTS=%d keptTS=%d",
		ev.Reason, ev.IfaceName, ev.Gateway, ev.RebindTailscale, ev.PruneNonTailscale, tsNotified, prunedNonTS, keptTS)
	return tsNotified, prunedNonTS, keptTS
}

// NotifyNetworkChange queues a debounced mobile/desktop network-change recovery.
func (e *DesktopEngine) NotifyNetworkChange(ifaceName, gateway, reason string, rebindTailscale, pruneNonTailscale bool) {
	e.mu.Lock()
	running := e.running
	e.mu.Unlock()
	if !running {
		return
	}
	mobileNetCoordinator.Trigger(NetworkChangeEvent{
		IfaceName:         ifaceName,
		Gateway:           gateway,
		Reason:            reason,
		RebindTailscale:   rebindTailscale,
		PruneNonTailscale: pruneNonTailscale,
	})
}
