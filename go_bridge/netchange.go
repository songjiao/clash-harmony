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

const (
	netChangeDebounce       = 250 * time.Millisecond
	netChangeFlagRebindTS   = 1 << 0
	netChangeFlagPruneNonTS = 1 << 1
)

type NetworkChangeEvent struct {
	IfaceName         string `json:"ifaceName"`
	Reason            string `json:"reason"`
	RebindTailscale   bool   `json:"rebindTailscale"`
	PruneNonTailscale bool   `json:"pruneNonTailscale"`
}

type NetworkChangeStats struct {
	EventCount      int64  `json:"eventCount"`
	LastReason      string `json:"lastReason"`
	LastIface       string `json:"lastIface"`
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

var ohosNetCoordinator = &networkChangeCoordinator{}

func (c *networkChangeCoordinator) Trigger(ev NetworkChangeEvent) {
	ev.IfaceName = strings.TrimSpace(ev.IfaceName)
	ev.Reason = strings.TrimSpace(ev.Reason)
	if ev.Reason == "" {
		ev.Reason = "ohos-network-change"
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
		c.pending.Reason = ev.Reason
		c.pending.RebindTailscale = c.pending.RebindTailscale || ev.RebindTailscale
		c.pending.PruneNonTailscale = c.pending.PruneNonTailscale || ev.PruneNonTailscale
	}

	if c.timer != nil {
		c.timer.Reset(netChangeDebounce)
		return
	}
	c.timer = time.AfterFunc(netChangeDebounce, c.flush)
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

func applyNetworkChange(ev NetworkChangeEvent) (tsNotified int, prunedNonTS int, keptTS int) {
	netmon.UpdateLastKnownDefaultRouteInterface(ev.IfaceName)

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

	log.Infoln("[NetChange] reason=%s iface=%q rebindTS=%v pruneNonTS=%v tsNotified=%d prunedNonTS=%d keptTS=%d",
		ev.Reason, ev.IfaceName, ev.RebindTailscale, ev.PruneNonTailscale, tsNotified, prunedNonTS, keptTS)
	return tsNotified, prunedNonTS, keptTS
}

func (m *bridgeManager) notifyNetworkChange(ifaceName, reason string, flags int) int {
	m.mu.Lock()
	running := m.running
	m.mu.Unlock()
	if !running {
		return 0
	}
	ohosNetCoordinator.Trigger(NetworkChangeEvent{
		IfaceName:         ifaceName,
		Reason:            reason,
		RebindTailscale:   flags&netChangeFlagRebindTS != 0,
		PruneNonTailscale: flags&netChangeFlagPruneNonTS != 0,
	})
	return 0
}
