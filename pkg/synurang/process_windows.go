//go:build windows

package synurang

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"google.golang.org/grpc"
)

var (
	modkernel32          = syscall.NewLazyDLL("kernel32.dll")
	procCreateNamedPipeW = modkernel32.NewProc("CreateNamedPipeW")
	procConnectNamedPipe = modkernel32.NewProc("ConnectNamedPipe")
)

const (
	pipeAccessDuplex = 0x00000003
	pipeTypeByte     = 0x00000000
	pipeWait         = 0x00000000
)

func createNamedPipe(name string) (syscall.Handle, error) {
	pName, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return 0, err
	}
	h, _, err := procCreateNamedPipeW.Call(
		uintptr(unsafe.Pointer(pName)),
		uintptr(pipeAccessDuplex),
		uintptr(pipeTypeByte|pipeWait),
		1, 4096, 4096, 0, 0,
	)
	if h == uintptr(syscall.InvalidHandle) {
		return 0, err
	}
	return syscall.Handle(h), nil
}

func connectNamedPipe(h syscall.Handle) error {
	r, _, err := procConnectNamedPipe.Call(uintptr(h), 0)
	if r != 0 || err == syscall.ERROR_PIPE_CONNECTED {
		return nil
	}
	return err
}

type pipeConn struct{ *os.File }

func (p pipeConn) LocalAddr() net.Addr                { return pipeAddr(p.Name()) }
func (p pipeConn) RemoteAddr() net.Addr               { return pipeAddr(p.Name()) }
func (p pipeConn) SetDeadline(t time.Time) error      { return nil }
func (p pipeConn) SetReadDeadline(t time.Time) error  { return nil }
func (p pipeConn) SetWriteDeadline(t time.Time) error { return nil }

type pipeAddr string

func (a pipeAddr) Network() string { return "pipe" }
func (a pipeAddr) String() string  { return string(a) }

func startProcess(ctx context.Context, cmd *exec.Cmd, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("failed to generate pipe name: %w", err)
	}
	pipeName := fmt.Sprintf(`\\.\pipe\synurang-%s`, hex.EncodeToString(b))

	handle, err := createNamedPipe(pipeName)
	if err != nil {
		return nil, fmt.Errorf("CreateNamedPipe failed: %w", err)
	}

	cmd.Env = append(cmd.Env, EnvVarIPC+"="+pipeName)

	if err := cmd.Start(); err != nil {
		syscall.CloseHandle(handle)
		return nil, fmt.Errorf("cmd.Start failed: %w", err)
	}


	var (
		dialOnce sync.Once
		dialConn net.Conn
		dialErr  error
	)

	dialer := func(ctx context.Context, _ string) (net.Conn, error) {
		var firstCall bool
		dialOnce.Do(func() {
			firstCall = true
			type result struct {
				conn net.Conn
				err  error
			}

			ch := make(chan result, 1)
			go func() {
				err := connectNamedPipe(handle)
				if err != nil {
					syscall.CloseHandle(handle)
					ch <- result{nil, fmt.Errorf("ConnectNamedPipe failed: %w", err)}
					return
				}
				f := os.NewFile(uintptr(handle), pipeName)
				ch <- result{pipeConn{f}, nil}
			}()

			select {
			case <-ctx.Done():
				syscall.CloseHandle(handle)
				dialErr = ctx.Err()
			case res := <-ch:
				dialConn, dialErr = res.conn, res.err
			}
		})

		if !firstCall {
			return nil, ErrDialerExhausted
		}
		return dialConn, dialErr
	}

	return dialWithOptions(ctx, dialer, opts...)
}

func newIPCListener() (net.Listener, error) {
	pipeName := os.Getenv(EnvVarIPC)
	if pipeName == "" {
		return nil, fmt.Errorf("%s environment variable not set", EnvVarIPC)
	}

	f, err := os.OpenFile(pipeName, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to parent pipe %s: %w", pipeName, err)
	}

	return newSingleConnListener(pipeConn{f}), nil
}
