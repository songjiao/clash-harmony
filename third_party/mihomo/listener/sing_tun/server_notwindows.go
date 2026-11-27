//go:build !windows && !openharmony && !android

package sing_tun

import (
	tun "github.com/metacubex/sing-tun"
)

func tunNew(options tun.Options) (tun.Tun, error) {
	return tun.New(options)
}
