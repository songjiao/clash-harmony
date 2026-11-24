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

//export MihomoFreeCString
func MihomoFreeCString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

func main() {}
