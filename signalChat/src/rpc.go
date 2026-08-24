package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// This file speaks signal-cli's JSON-RPC dialect and nothing else. It knows
// about requests, responses and notifications; it does not know what a
// conversation is.
//
// signal-cli is a separate process we own: `signal-cli jsonRpc` reads JSON-RPC
// 2.0 requests on stdin and writes responses and notifications on stdout, one
// object per line -- the same shape as the DMS contract, one layer down.

// rpcTimeout bounds a call to signal-cli.
//
// Generous because the first call after linking contacts the server, and a
// stalled request must eventually free its waiter rather than leak it.
const rpcTimeout = 90 * time.Second

// linkTimeout bounds finishLink, which blocks until the phone scans the code.
// Signal expires a linking URI well before this.
const linkTimeout = 10 * time.Minute

type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
	ID      string `json:"id"`
}

type rpcError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *rpcError) Error() string {
	return fmt.Sprintf("signal-cli: %s (code %d)", e.Message, e.Code)
}

// rpcFrame is one line from signal-cli. A line is a response when it carries an
// id, and a notification when it carries a method instead.
type rpcFrame struct {
	ID     *json.RawMessage `json:"id"`
	Result json.RawMessage  `json:"result"`
	Error  *rpcError        `json:"error"`
	Method string           `json:"method"`
	Params json.RawMessage  `json:"params"`
}

type rpcResult struct {
	result json.RawMessage
	err    error
}

// rpcClient owns the signal-cli child process.
type rpcClient struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	stdin   *bufio.Writer
	pending map[string]chan rpcResult
	closed  bool

	nextID atomic.Int64

	// onNotify receives every notification signal-cli pushes. Set before start.
	onNotify func(method string, params json.RawMessage)
	// onExit fires once if signal-cli stops on its own.
	onExit func(error)
}

func newRPCClient() *rpcClient {
	return &rpcClient{pending: map[string]chan rpcResult{}}
}

// start launches signal-cli and begins reading its output.
func (c *rpcClient) start(binary string, args []string) error {
	cmd := exec.Command(binary, args...)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("signal-cli stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("signal-cli stdout: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("signal-cli stderr: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start signal-cli: %w", err)
	}

	c.mu.Lock()
	c.cmd = cmd
	c.stdin = bufio.NewWriter(stdin)
	c.closed = false
	c.mu.Unlock()

	go c.readLoop(stdout)

	// signal-cli is a JVM program and is chatty on stderr even when healthy, so
	// this is forwarded at debug level rather than surfaced as an error.
	go func() {
		s := bufio.NewScanner(stderr)
		s.Buffer(make([]byte, 0, 64*1024), 4<<20)
		for s.Scan() {
			if line := s.Text(); line != "" {
				logf("debug", "signal-cli: %s", line)
			}
		}
	}()

	go func() {
		err := cmd.Wait()
		c.failAll(fmt.Errorf("signal-cli exited: %w", err))
		if c.onExit != nil {
			c.onExit(err)
		}
	}()

	return nil
}

// readLoop turns each line into either a response or a notification.
func (c *rpcClient) readLoop(stdout interface{ Read([]byte) (int, error) }) {
	s := bufio.NewScanner(stdout)
	// A receive notification can carry a large group roster or a long message;
	// the default 64 KiB limit would truncate it and desync nothing but lose it.
	s.Buffer(make([]byte, 0, 64*1024), 32<<20)

	for s.Scan() {
		line := s.Bytes()
		if len(line) == 0 {
			continue
		}

		var f rpcFrame
		if err := json.Unmarshal(line, &f); err != nil {
			logf("debug", "unparseable signal-cli line: %v", err)
			continue
		}

		if f.ID != nil && f.Method == "" {
			c.deliver(string(*f.ID), f)
			continue
		}
		if f.Method != "" && c.onNotify != nil {
			c.onNotify(f.Method, f.Params)
		}
	}
}

// deliver hands a response to whoever is waiting on that id.
//
// Responses do not arrive in the order the requests were sent -- signal-cli
// answers whatever finishes first -- so waiters are matched by id and never by
// position.
func (c *rpcClient) deliver(rawID string, f rpcFrame) {
	id, err := strconv.Unquote(rawID)
	if err != nil {
		id = rawID
	}

	c.mu.Lock()
	ch, waiting := c.pending[id]
	delete(c.pending, id)
	c.mu.Unlock()

	if !waiting {
		return
	}

	if f.Error != nil {
		ch <- rpcResult{err: f.Error}
		return
	}
	ch <- rpcResult{result: f.Result}
}

// call sends a request and waits for its answer.
func (c *rpcClient) call(method string, params any, timeout time.Duration) (json.RawMessage, error) {
	id := strconv.FormatInt(c.nextID.Add(1), 10)
	ch := make(chan rpcResult, 1)

	c.mu.Lock()
	if c.closed || c.stdin == nil {
		c.mu.Unlock()
		return nil, fmt.Errorf("signal-cli is not running")
	}
	c.pending[id] = ch

	data, err := json.Marshal(rpcRequest{JSONRPC: "2.0", Method: method, Params: params, ID: id})
	if err != nil {
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("encode %s: %w", method, err)
	}

	// Written under the same lock that registered the waiter, so a reply can
	// never be delivered before the waiter exists.
	_, werr := c.stdin.Write(append(data, '\n'))
	if werr == nil {
		werr = c.stdin.Flush()
	}
	c.mu.Unlock()

	if werr != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("write %s: %w", method, werr)
	}

	select {
	case res := <-ch:
		return res.result, res.err
	case <-time.After(timeout):
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("%s timed out", method)
	}
}

// callInto unmarshals a successful result into out.
func (c *rpcClient) callInto(method string, params any, out any) error {
	res, err := c.call(method, params, rpcTimeout)
	if err != nil {
		return err
	}
	if out == nil || len(res) == 0 {
		return nil
	}
	return json.Unmarshal(res, out)
}

// failAll releases every waiter, so a signal-cli crash surfaces as an error on
// each in-flight call instead of hanging until its timeout.
func (c *rpcClient) failAll(err error) {
	c.mu.Lock()
	pending := c.pending
	c.pending = map[string]chan rpcResult{}
	c.closed = true
	c.mu.Unlock()

	for _, ch := range pending {
		select {
		case ch <- rpcResult{err: err}:
		default:
		}
	}
}

// stop ends the signal-cli process.
func (c *rpcClient) stop() {
	c.mu.Lock()
	cmd := c.cmd
	c.closed = true
	c.mu.Unlock()

	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
}

func (c *rpcClient) running() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.closed && c.cmd != nil
}
