package synurang

import (
	"context"
	"errors"
	"net"
	"os/exec"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	// EnvVarIPC is the environment variable for IPC (FD on Unix, pipe name on Windows).
	EnvVarIPC = "SYNURANG_IPC"
)

// ErrDialerExhausted is returned when the one-shot dialer has already provided its connection.
var ErrDialerExhausted = errors.New("synurang: dialer exhausted, connection already provided")

// StartProcess starts cmd as a child process and returns a gRPC connection over IPC.
func StartProcess(ctx context.Context, cmd *exec.Cmd, opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	return startProcess(ctx, cmd, opts...)
}

// NewIPCListener creates a listener for the child side of the IPC channel.
func NewIPCListener() (net.Listener, error) {
	return newIPCListener()
}

func dialWithOptions(ctx context.Context, dialer func(context.Context, string) (net.Conn, error), opts ...grpc.DialOption) (*grpc.ClientConn, error) {
	defaultOpts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(dialer),
	}
	finalOpts := append(defaultOpts, opts...)
	return grpc.DialContext(ctx, "passthrough:///ipc", finalOpts...)
}

// oneShotDialer returns its connection only once; subsequent calls return ErrDialerExhausted.
type oneShotDialer struct {
	conn net.Conn
	once sync.Once
	used bool
	mu   sync.Mutex
}

func newOneShotDialer(conn net.Conn) *oneShotDialer {
	return &oneShotDialer{conn: conn}
}

func (d *oneShotDialer) Dial(ctx context.Context, addr string) (net.Conn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.used {
		return nil, ErrDialerExhausted
	}
	d.used = true
	return d.conn, nil
}

// singleConnListener serves a single pre-established connection.
type singleConnListener struct {
	conn     net.Conn
	once     sync.Once
	c        chan net.Conn
	done     chan struct{}
	accepted bool
	mu       sync.Mutex
}

func newSingleConnListener(conn net.Conn) *singleConnListener {
	l := &singleConnListener{
		conn: conn,
		c:    make(chan net.Conn, 1),
		done: make(chan struct{}),
	}
	l.c <- conn
	return l
}

func (l *singleConnListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.c:
		l.mu.Lock()
		l.accepted = true
		l.mu.Unlock()
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *singleConnListener) Close() error {
	l.once.Do(func() {
		close(l.done)
		l.mu.Lock()
		accepted := l.accepted
		l.mu.Unlock()
		if !accepted {
			select {
			case c := <-l.c:
				c.Close()
			default:
			}
		}
	})
	return nil
}

func (l *singleConnListener) Addr() net.Addr {
	return l.conn.LocalAddr()
}
