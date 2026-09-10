// chat-managerd is the chat system's backend, running as its own process.
//
// It used to live inside the DMS core daemon. Moving it out is what lets the
// whole chat system ship as a plugin: nothing here needs a modified shell, and
// a user who has no chat plugins installed never runs any of it.
//
// The protocol is unchanged from when this was mounted in core -- the same
// "chat.*" methods and the same subscription events -- so the bridges on the
// other side needed no changes at all.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"

	"dmschatmanager/internal/host"
	"dmschatmanager/internal/log"
	"dmschatmanager/internal/models"
)

// serviceEvent matches what the DMS core socket used to push, so the QML side
// reads subscription traffic the same way it always did.
type serviceEvent struct {
	Service string `json:"service"`
	Data    any    `json:"data"`
}

type response struct {
	ID     int    `json:"id,omitempty"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func main() {
	socketPath := flag.String("socket", defaultSocketPath(), "unix socket to listen on")
	flag.Parse()

	if err := run(*socketPath); err != nil {
		fmt.Fprintf(os.Stderr, "chat-managerd: %v\n", err)
		os.Exit(1)
	}
}

func run(socketPath string) error {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}

	// A socket left behind by a killed manager would otherwise make every
	// later start fail with "address already in use".
	if err := removeStaleSocket(socketPath); err != nil {
		return err
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", socketPath, err)
	}
	defer listener.Close()

	// The socket carries every message the user has ever received.
	if err := os.Chmod(socketPath, 0o600); err != nil {
		return fmt.Errorf("secure the socket: %w", err)
	}

	manager, err := host.NewManager()
	if err != nil {
		return fmt.Errorf("start the chat manager: %w", err)
	}
	defer manager.Close()

	log.Infof("chat manager listening on %s", socketPath)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Clients are tracked so shutdown can close them. A connected client sits
	// blocked reading its socket, and waiting for it to send something would
	// mean the manager never exits while the shell is attached -- leaving an
	// orphan holding the socket that the next start then refuses to replace.
	live := &liveConns{conns: map[net.Conn]struct{}{}}

	go func() {
		<-ctx.Done()
		// Unblocks Accept so shutdown does not wait for the next client.
		_ = listener.Close()
		live.closeAll()
	}()

	var clients sync.WaitGroup
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			if errors.Is(err, net.ErrClosed) {
				break
			}
			log.Warnf("accept failed: %v", err)
			continue
		}

		if !live.add(conn) {
			// Shutdown began between Accept and here.
			_ = conn.Close()
			continue
		}

		clients.Add(1)
		go func() {
			defer clients.Done()
			defer live.remove(conn)
			serve(ctx, conn, manager)
		}()
	}

	clients.Wait()
	log.Infof("chat manager stopped")
	return nil
}

// liveConns tracks open client connections so they can be closed on shutdown.
type liveConns struct {
	mu      sync.Mutex
	conns   map[net.Conn]struct{}
	closing bool
}

func (l *liveConns) add(c net.Conn) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.closing {
		return false
	}
	l.conns[c] = struct{}{}
	return true
}

func (l *liveConns) remove(c net.Conn) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.conns, c)
}

func (l *liveConns) closeAll() {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.closing = true
	for c := range l.conns {
		_ = c.Close()
	}
}

// serve handles one client for its lifetime.
//
// Only the shell connects, but a second client (dms chat status, a test) must
// not disturb the first, so subscriptions are per connection.
func serve(ctx context.Context, rawConn net.Conn, manager *host.Manager) {
	defer rawConn.Close()

	conn := models.NewConn(rawConn)
	clientID := fmt.Sprintf("client-%p", rawConn)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Recreated on every unsubscribe so the client can subscribe again.
	sub := &subscription{}
	defer sub.stop()
	defer manager.Unsubscribe(clientID)

	decoder := json.NewDecoder(rawConn)
	for {
		var req models.Request
		if err := decoder.Decode(&req); err != nil {
			if err != io.EOF && ctx.Err() == nil {
				log.Debugf("client %s went away: %v", clientID, err)
			}
			return
		}

		// Subscribing is the one pair of methods the host package does not own:
		// they are about this connection rather than about chat state.
		switch req.Method {
		case "subscribe":
			sub.start(ctx, conn, manager, clientID)
			_ = conn.WriteResponse(response{ID: req.ID, Result: map[string]any{"success": true}})
			continue
		case "unsubscribe":
			// The shell stops watching whenever the chat window closes, which
			// is most of the time. Ending the stream means an arriving message
			// no longer wakes the UI for a window nobody has open.
			sub.stop()
			manager.Unsubscribe(clientID)
			_ = conn.WriteResponse(response{ID: req.ID, Result: map[string]any{"success": true}})
			continue
		}

		host.HandleRequest(conn, req, manager)
	}
}

// subscription is one client's state stream, which it may stop and start again
// as its chat window opens and closes.
type subscription struct {
	cancel context.CancelFunc
}

func (s *subscription) start(ctx context.Context, conn *models.Conn, manager *host.Manager, clientID string) {
	if s.cancel != nil {
		return
	}

	streamCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel
	go pushState(streamCtx, conn, manager, clientID)
}

func (s *subscription) stop() {
	if s.cancel == nil {
		return
	}

	s.cancel()
	s.cancel = nil
}

// pushState streams chat state to a subscribed client.
//
// The first send is the current state rather than the next change, so a client
// that connects to an already-running manager is not left with an empty window
// until something happens.
func pushState(ctx context.Context, conn *models.Conn, manager *host.Manager, clientID string) {
	states := manager.Subscribe(clientID)

	if err := conn.WriteResponse(response{Result: serviceEvent{Service: "chat", Data: manager.GetState()}}); err != nil {
		return
	}

	for {
		select {
		case <-ctx.Done():
			return
		case state, ok := <-states:
			if !ok {
				return
			}
			if err := conn.WriteResponse(response{Result: serviceEvent{Service: "chat", Data: state}}); err != nil {
				return
			}
		}
	}
}

// removeStaleSocket clears a socket file no one is listening on.
//
// Refuses to touch one that still answers, so a second manager cannot steal the
// running one's socket and leave the shell talking to a dead process.
func removeStaleSocket(path string) error {
	if _, err := os.Stat(path); err != nil {
		return nil
	}

	if conn, err := net.Dial("unix", path); err == nil {
		conn.Close()
		return fmt.Errorf("another chat manager is already listening on %s", path)
	}

	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale socket %s: %w", path, err)
	}
	return nil
}

func defaultSocketPath() string {
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "dms-chat-manager.sock")
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("dms-chat-manager-%d.sock", os.Getuid()))
}
