//go:build !debug

package main

// Production stub: debug RPCs are not compiled in. Builds without the `debug`
// build tag never recognize /core.v1.DebugService/* and fall through to the
// normal "unknown method" path.
func tryDebugHang(method string, data []byte) (handled bool, response []byte, err error) {
	return false, nil, nil
}
