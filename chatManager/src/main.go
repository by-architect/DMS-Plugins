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

var errAlreadyRunning = errors.New("another chat manager is already listening")

type response struct {
	ID     int    `json:"id,omitempty"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func main() {
	socketPath := flag.String("socket", defaultSocketPath(), "unix socket to listen on")
	flag.Parse()

	if err := run(*socketPath); err != nil {
		// Another manager already serving is an ordinary outcome -- a second
		// shell, or a restart racing the old process -- and not worth a failure
		// exit that would have the caller relaunch this in a loop.
		if errors.Is(err, errAlreadyRunning) {
			fmt.Fprintln(os.Stderr, "chat-managerd: another manager is already serving this socket")
			return
		}
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

	// A clicked notification asks for a conversation without coming through
	// any connection, so it goes to all of them -- in practice, the one shell.
	shells := &writers{conns: map[*models.Conn]struct{}{}}
	manager.SetOpenHandler(func(provider, chatID string) {
		shells.broadcast(response{Result: serviceEvent{
			Service: "chat.open",
			Data:    map[string]string{"provider": provider, "chatId": chatID},
		}})
	})

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
			serve(ctx, conn, manager, shells)
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

// writers are the connections something unprompted is told to: a click on a
// notification, which belongs to no request.
type writers struct {
	mu    sync.Mutex
	conns map[*models.Conn]struct{}
}

func (w *writers) add(c *models.Conn) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.conns[c] = struct{}{}
}

func (w *writers) remove(c *models.Conn) {
	w.mu.Lock()
	defer w.mu.Unlock()
	delete(w.conns, c)
}

func (w *writers) broadcast(v any) {
	w.mu.Lock()
	targets := make([]*models.Conn, 0, len(w.conns))
	for c := range w.conns {
		targets = append(targets, c)
	}
	w.mu.Unlock()

	for _, c := range targets {
		_ = c.WriteResponse(v)
	}
}

// serve handles one client for its lifetime.
//
// Only the shell connects, but a second client (dms chat status, a test) must
// not disturb the first, so subscriptions are per connection.
func serve(ctx context.Context, rawConn net.Conn, manager *host.Manager, shells *writers) {
	defer rawConn.Close()

	conn := models.NewConn(rawConn)
	clientID := fmt.Sprintf("client-%p", rawConn)

	shells.add(conn)
	defer shells.remove(conn)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Recreated on every unsubscribe so the client can subscribe again.
	sub := &subscription{}
	defer sub.stop()
	defer manager.Unsubscribe(clientID)

	// Slow requests are answered on lanes of their own; see laneFor.
	var slow lanes

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

		if lane := laneFor(req); lane != "" {
			slow.run(lane, func() { host.HandleRequest(conn, req, manager) })
			continue
		}
		host.HandleRequest(conn, req, manager)
	}
}

// laneFor names the lane a request is answered on, or "" to answer it here.
//
// One connection carries everything the shell asks, and it used to be answered
// strictly one request at a time. Anything that waits on a provider -- sending a
// photo, fetching a video before it can be opened, signing in -- held up
// everything queued behind it for as long as the provider took: switching
// conversation, loading history, the launcher looking a name up, all frozen for
// up to a minute.
//
// So those get a lane. Requests on the same lane are still answered in the
// order they arrived, which is the order that matters: two messages sent into
// one conversation must not overtake each other, and a provider being switched
// on must not be overtaken by its own settings. Everything else is quick, reads
// the store, and keeps its place in line here.
func laneFor(req models.Request) string {
	provider := models.GetOr(req, "provider", "")
	chatID := models.GetOr(req, "chatId", "")

	switch req.Method {
	case "chat.send", "chat.revoke", "chat.acceptInvite", "chat.declineInvite":
		return "chat\x00" + provider + "\x00" + chatID
	case "chat.setEnabled", "chat.setProviderSettings", "chat.login", "chat.logout",
		"chat.authSubmit", "chat.purge":
		return "provider\x00" + provider
	case "chat.fetchMedia":
		// Each download is independent of every other; one lane apiece.
		return fmt.Sprintf("fetch\x00%d", req.ID)
	case "chat.search":
		return "search"
	case "chat.tap":
		// Streams until the client hangs up, so it cannot be answered in line.
		return fmt.Sprintf("tap\x00%d", req.ID)
	}
	return ""
}

// lanes runs work in arrival order per lane, and lanes alongside each other.
type lanes struct {
	mu    sync.Mutex
	queue map[string][]func()
}

func (l *lanes) run(lane string, fn func()) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.queue == nil {
		l.queue = map[string][]func(){}
	}
	pending, busy := l.queue[lane]
	l.queue[lane] = append(pending, fn)
	if !busy {
		go l.drain(lane)
	}
}

// drain works through one lane until it is empty, then lets it go.
func (l *lanes) drain(lane string) {
	for {
		l.mu.Lock()
		pending := l.queue[lane]
		if len(pending) == 0 {
			delete(l.queue, lane)
			l.mu.Unlock()
			return
		}
		fn := pending[0]
		l.queue[lane] = pending[1:]
		l.mu.Unlock()

		fn()
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

	// Registered here, before the stream starts, rather than inside it. The
	// requests on a connection are handled in order, and an unsubscribe right
	// behind this one has to find the subscription it is ending -- registering
	// from the goroutine let it run after the unsubscribe, leaving a stream
	// registered that nothing would ever stop.
	states := manager.Subscribe(clientID)

	streamCtx, cancel := context.WithCancel(ctx)
	s.cancel = cancel
	go pushState(streamCtx, conn, manager, clientID, states)
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
func pushState(ctx context.Context, conn *models.Conn, manager *host.Manager, clientID string, states chan host.State) {
	// Only this stream's own channel: if the client has already subscribed
	// again, the new subscription is not this one's to remove.
	defer manager.UnsubscribeChannel(clientID, states)

	if err := conn.WriteResponse(response{Result: serviceEvent{Service: "chat", Data: manager.GetState()}}); err != nil {
		return
	}

	for {
		select {
		case <-ctx.Done():
			return
		case state := <-states:
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
		return errAlreadyRunning
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
