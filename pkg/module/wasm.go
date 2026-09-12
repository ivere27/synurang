//go:build js && wasm

package module

import (
	"encoding/binary"
	"os"
	"strconv"
	"syscall/js"
)

// A result is kind:u32, code:i32, size:u32, then size payload bytes. A unary
// message may be followed by its terminal result in the same owned buffer.
// This avoids constructing a JS object and crossing the bridge for each field.
func appendWasmRead(buffer []byte, kind, code int, data []byte) []byte {
	buffer = binary.LittleEndian.AppendUint32(buffer, uint32(kind))
	buffer = binary.LittleEndian.AppendUint32(buffer, uint32(code))
	buffer = binary.LittleEndian.AppendUint32(buffer, uint32(len(data)))
	return append(buffer, data...)
}

func wasmReceive(instance *Instance, id uint64) any {
	kind, code, data, status := instance.receive(id)
	if status != 0 {
		kind, code, data = 2, 13, nil
	}
	if kind == 0 {
		return nil
	}
	buffer := appendWasmRead(nil, kind, code, data)
	if call := instance.lookup(id); kind == 1 && call != nil && !call.responseStream {
		// A second unary read can only be pending or terminal: the provider
		// converts an extra response into a cardinality error. Streaming reads
		// stay single-message so this adapter does not enlarge their queues.
		kind, code, data, status = instance.receive(id)
		if status != 0 {
			kind, code, data = 2, 13, nil
		}
		if kind != 0 {
			buffer = appendWasmRead(buffer, kind, code, data)
		}
	}
	bytes := js.Global().Get("Uint8Array").New(len(buffer))
	js.CopyBytesToJS(bytes, buffer)
	return bytes
}

// Run publishes this Go runtime's module factory to the JS host and runs until
// it requests shutdown. wasm_exec.js must come from the same Go toolchain.
// Factory identification is per instantiation, so concurrent modules do not
// overwrite a shared global plugin singleton.
func Run() {
	readyName := os.Getenv("SYNURANG_READY_CALLBACK")
	ready := js.Global().Get(readyName)
	if ready.Type() != js.TypeFunction {
		panic("Use createGoWasmHost to start a Synurang Go module")
	}
	done := make(chan struct{})
	active := 0
	var bridgeFunctions []js.Func
	create := js.FuncOf(func(_ js.Value, args []js.Value) any {
		capacity := args[0].Int()
		if capacity < 1 || capacity > 65536 {
			return js.Null()
		}
		instance := createInstance(capacity, capacity)
		if instance == nil {
			return js.Null()
		}
		active++
		// The callback schedules a later JS task, never another Go ABI entry.
		wakeup := args[1]
		instance.wakeup = func() { wakeup.Invoke() }
		object := js.Global().Get("Object").New()
		var functions []js.Func
		bind := func(name string, fn func([]js.Value) any) {
			function := js.FuncOf(func(_ js.Value, args []js.Value) any { return fn(args) })
			functions = append(functions, function)
			object.Set(name, function)
		}
		id := func(value js.Value) uint64 { result, _ := strconv.ParseUint(value.String(), 10, 64); return result }
		open := func(args []js.Value) uint64 {
			timeout := ^uint64(0)
			if args[3].Float() >= 0 {
				timeout = uint64(args[3].Float())
			}
			return instance.open(args[0].String(), args[1].Bool(), args[2].Bool(), timeout, true)
		}
		copyRequest := func(value js.Value) []byte {
			data := make([]byte, value.Get("byteLength").Int())
			js.CopyBytesToGo(data, value)
			return data
		}
		bind("open", func(args []js.Value) any {
			return strconv.FormatUint(open(args), 10)
		})
		bind("openWithRequest", func(args []js.Value) any {
			call := open(args)
			status := instance.send(call, copyRequest(args[4]))
			if status == 0 {
				status = instance.halfClose(call)
			}
			return []any{strconv.FormatUint(call, 10), status}
		})
		bind("send", func(args []js.Value) any {
			return instance.send(id(args[0]), copyRequest(args[1]))
		})
		bind("halfClose", func(args []js.Value) any { return instance.halfClose(id(args[0])) })
		bind("receive", func(args []js.Value) any {
			return wasmReceive(instance, id(args[0]))
		})
		bind("cancel", func(args []js.Value) any { return instance.cancel(id(args[0]), args[1].Int()) })
		bind("release", func(args []js.Value) any { instance.release(id(args[0])); return nil })
		bind("poll", func(args []js.Value) any { instance.poll(); return 0 })
		bind("destroy", func(args []js.Value) any {
			status := instance.destroy()
			if status == 0 {
				active--
				for _, function := range functions {
					function.Release()
				}
			}
			return status
		})
		return object
	})
	shutdown := js.FuncOf(func(_ js.Value, _ []js.Value) any {
		if active != 0 {
			return false
		}
		close(done)
		return true
	})
	bridgeFunctions = append(bridgeFunctions, create, shutdown)
	ready.Invoke(map[string]any{"create": create, "shutdown": shutdown})
	<-done
	for _, function := range bridgeFunctions {
		function.Release()
	}
}
