package main

/*
#include <stdlib.h>
*/
import "C"
import "unsafe"

//export MihomoStart
func MihomoStart(configPath *C.char, tunFd C.int) C.int {
	goPath := ""
	if configPath != nil {
		goPath = C.GoString(configPath)
	}
	if err := bridge.startEngine(goPath, int(tunFd)); err != nil {
		return -1
	}
	return 0
}

//export MihomoStartCore
func MihomoStartCore(configPath *C.char) C.int {
	return MihomoStart(configPath, -1)
}

//export MihomoStop
func MihomoStop() C.int {
	if err := bridge.stopEngine(); err != nil {
		return -1
	}
	return 0
}

//export MihomoVersion
func MihomoVersion() *C.char {
	return C.CString(bridge.versionString())
}

//export MihomoLastError
func MihomoLastError() *C.char {
	return C.CString(bridge.lastError())
}

//export MihomoAdapterInfo
func MihomoAdapterInfo() *C.char {
	return C.CString(bridge.adapterInfoJSON())
}

//export MihomoValidateConfig
func MihomoValidateConfig(yamlText *C.char) *C.char {
	text := ""
	if yamlText != nil {
		text = C.GoString(yamlText)
	}
	return C.CString(validateConfigJSON(text))
}

//export MihomoNotifyNetworkChange
func MihomoNotifyNetworkChange(ifaceName *C.char, reason *C.char, flags C.int) C.int {
	goIface := ""
	if ifaceName != nil {
		goIface = C.GoString(ifaceName)
	}
	goReason := ""
	if reason != nil {
		goReason = C.GoString(reason)
	}
	return C.int(bridge.notifyNetworkChange(goIface, goReason, int(flags)))
}

//export MihomoFreeCString
func MihomoFreeCString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

func main() {}
