// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package health

import (
	"testing"

	"github.com/metacubex/tailscale/util/eventbus"
)

func TestReceiveFuncStatsBrokenMarksMissing(t *testing.T) {
	bus := eventbus.New()
	defer bus.Close()
	ht := NewTracker(bus)
	stats := ht.ReceiveFuncStats(ReceiveIPv4)
	if stats == nil {
		t.Fatal("expected non-nil ReceiveFuncStats")
	}

	stats.Enter()
	defer stats.Exit()

	stats.SetBroken(true)
	ht.mu.Lock()
	ht.checkReceiveFuncsLocked()
	ht.mu.Unlock()
	if !stats.missing {
		t.Fatal("expected missing=true when ReceiveFuncStats.broken=true even with inCall=true")
	}

	stats.SetBroken(false)
	ht.mu.Lock()
	ht.checkReceiveFuncsLocked()
	ht.mu.Unlock()
	if stats.missing {
		t.Fatal("expected missing=false after ReceiveFuncStats.SetBroken(false)")
	}
}
