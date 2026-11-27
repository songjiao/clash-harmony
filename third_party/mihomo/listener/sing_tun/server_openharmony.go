//go:build (openharmony || android) && with_gvisor

package sing_tun

import (
	tun "github.com/metacubex/sing-tun"
)

func tunNew(options tun.Options) (tun.Tun, error) {
	if options.FileDescriptor > 0 {
		return newFDGVisorTun(options)
	}
	return tun.New(options)
}
