//go:build !windows

package synurang

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"syscall"

	"google.golang.org/grpc"
)

func startProcess(ctx context.Context, cmd *exec.Cmd, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("socketpair failed: %w", err)
	}

	parentFile := os.NewFile(uintptr(fds[0]), "parent_ipc")
	childFile := os.NewFile(uintptr(fds[1]), "child_ipc")
	defer childFile.Close()

	fdNum := 3 + len(cmd.ExtraFiles)
	cmd.ExtraFiles = append(cmd.ExtraFiles, childFile)
	cmd.Env = append(cmd.Env, EnvVarIPC+"="+strconv.Itoa(fdNum))

	if err := cmd.Start(); err != nil {
		parentFile.Close()
		return nil, fmt.Errorf("cmd.Start failed: %w", err)
	}

	conn, err := net.FileConn(parentFile)
	parentFile.Close()
	if err != nil {
		return nil, fmt.Errorf("FileConn failed: %w", err)
	}

	dialer := newOneShotDialer(conn)
	return dialWithOptions(ctx, dialer.Dial, opts...)
}

func newIPCListener() (net.Listener, error) {
	fdStr := os.Getenv(EnvVarIPC)
	if fdStr == "" {
		return nil, fmt.Errorf("%s environment variable not set", EnvVarIPC)
	}

	fd, err := strconv.Atoi(fdStr)
	if err != nil {
		return nil, fmt.Errorf("invalid FD in %s: %w", EnvVarIPC, err)
	}

	file := os.NewFile(uintptr(fd), "child_ipc")
	if file == nil {
		return nil, fmt.Errorf("failed to create file from FD %d", fd)
	}
	defer file.Close()

	conn, err := net.FileConn(file)
	if err != nil {
		return nil, fmt.Errorf("FileConn failed: %w", err)
	}

	return newSingleConnListener(conn), nil
}
