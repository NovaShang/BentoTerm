package relay

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// StatusWireVersionUnsupported is the WS close code the relay sends when a
// frame carries a version byte it cannot parse. Mirrors CLOSE_WIRE_VERSION
// in relay/src/daemon-do.ts — keep the two in sync.
const StatusWireVersionUnsupported websocket.StatusCode = 4002

// StreamHandler reacts to relay-initiated streams. The daemon's SSH server
// plugs in here: on Open it spawns an SSH session and returns a sink bound
// to that stream's frames.
type StreamHandler interface {
	OnOpen(streamID uint32) (StreamSink, error)
}

// StreamSink is what the relay client gives to the SSH server: bytes flowing
// from iOS end up in Write; bytes the SSH server emits go through the
// returned io.Writer (obtained from Client.WriterFor).
type StreamSink interface {
	io.Writer
	Close() error
}

// ControlHandler reacts to daemon-targeted control frames (pair.opened,
// pair.attach, pong). The daemon's pairing manager subscribes here.
type ControlHandler interface {
	OnControl(msg map[string]any)
}

// Options configures the daemon-side WSS client.
type Options struct {
	BaseURL  string // e.g. https://relay.bento.novashang.com
	DaemonID string
	// HostSigner is the daemon's SSH host key. We use its raw Ed25519 form
	// to sign a per-connect challenge so the relay can verify that the
	// daemon owns its claimed daemon_id. Required.
	HostSigner Ed25519HostSigner
	Logger     *slog.Logger
	// PingEvery is how often we send control "ping" so the relay knows we're alive.
	PingEvery time.Duration
	// MinBackoff/MaxBackoff bound the reconnect delay.
	MinBackoff time.Duration
	MaxBackoff time.Duration
}

// Ed25519HostSigner exposes just what the relay client needs from the SSH
// host key: the raw 32-byte public key and a function to produce a raw
// 64-byte Ed25519 signature over arbitrary bytes. The sshserver package
// implements this; tests can supply a fake.
type Ed25519HostSigner interface {
	RawPublicKey() []byte
	SignRaw(msg []byte) ([]byte, error)
}

// Client maintains a long-lived WSS to the relay. Run blocks until ctx is
// canceled, reconnecting on error with exponential backoff.
type Client struct {
	opts       Options
	streams    StreamHandler
	control    ControlHandler
	mu         sync.Mutex
	conn       *websocket.Conn
	connected  bool
	lastError  string
	sinkMu     sync.Mutex
	activeSink map[uint32]StreamSink

	// pong mailbox: a single in-flight app-level ping at a time. When the
	// reader sees a {type:"pong",nonce:X} matching `pongExpect`, it closes
	// `pongCh`. See appPingLoop.
	pongMu     sync.Mutex
	pongExpect string
	pongCh     chan struct{}

	// lastWriteOK is the UnixNano of the most recent successful WS write on
	// the current session (0 = none yet). The liveness loops consult it to
	// tell "probe starved behind bulk data on a busy link" apart from "link
	// is dead" — see livenessGate.
	lastWriteOK atomic.Int64

	// epoch identifies the live session. Bumped on every dial and on every
	// abandonment, so a stale serve loop can tell it has been superseded.
	epoch uint64

	// reconnectRequested is the UnixNano at which a liveness loop gave up on
	// this session (0 = nobody has). Run's watchdog reads it: if the serve
	// loop hasn't returned a while after that, it is wedged and gets dropped.
	reconnectRequested atomic.Int64
}

// New constructs a Client. streams may be nil if the caller only needs the
// control plane; in that case incoming stream-open frames are immediately
// reflected closed.
func New(opts Options, streams StreamHandler, control ControlHandler) *Client {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.PingEvery == 0 {
		opts.PingEvery = 30 * time.Second
	}
	if opts.MinBackoff == 0 {
		opts.MinBackoff = 1 * time.Second
	}
	if opts.MaxBackoff == 0 {
		opts.MaxBackoff = 30 * time.Second
	}
	return &Client{
		opts:       opts,
		streams:    streams,
		control:    control,
		activeSink: make(map[uint32]StreamSink),
	}
}

// Connected reports the current connection state for /v1/status.
func (c *Client) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connected
}

// LastError returns the last connect/read error, empty if currently happy.
func (c *Client) LastError() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastError
}

// Run dials and serves until ctx is canceled.
func (c *Client) Run(ctx context.Context) {
	backoff := c.opts.MinBackoff
	for ctx.Err() == nil {
		start := time.Now()
		err := c.serveWithWatchdog(ctx)
		if ctx.Err() != nil {
			return
		}
		// A session that stayed up past MaxBackoff was a real connection, not
		// a dial-failure loop — reset so one long-lived session followed by a
		// drop doesn't wait the accumulated MaxBackoff to reconnect.
		if time.Since(start) >= c.opts.MaxBackoff {
			backoff = c.opts.MinBackoff
		}
		if err != nil {
			c.opts.Logger.Warn("relay disconnected", "err", err, "retry_in", backoff.String())
			c.setError(err.Error())
		}
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return
		}
		backoff *= 2
		if backoff > c.opts.MaxBackoff {
			backoff = c.opts.MaxBackoff
		}
	}
}

const (
	// dialTimeout bounds one WSS dial.
	dialTimeout = 20 * time.Second
	// wedgeGrace is how long we let connectAndServe unwind after a liveness
	// loop has already given up on the session. Past it we assume the serve
	// goroutine is stuck somewhere that neither the session-context cancel
	// nor the socket close can reach, and dial a replacement without it.
	wedgeGrace = 20 * time.Second
	// wedgeCheckEvery is the watchdog's polling period.
	wedgeCheckEvery = 2 * time.Second
)

// serveWithWatchdog runs one session and guarantees Run gets control back.
//
// connectAndServe is supposed to return once a liveness loop cancels the
// session context and closes the socket, but its read loop dispatches inbound
// frames INLINE — so a handler that blocks (a stalled stream write, say)
// parks the whole thing somewhere no cancel can reach. That happened in
// production: the daemon logged "forcing reconnect" and then went quiet for
// hours, still advertising relay_connected=true because the deferred cleanup
// never ran, while the relay had long since dropped it and every iOS attach
// got 503. Whatever blocks next, this bounds the damage to wedgeGrace.
func (c *Client) serveWithWatchdog(ctx context.Context) error {
	done := make(chan error, 1)
	go func() { done <- c.connectAndServe(ctx) }()

	tick := time.NewTicker(wedgeCheckEvery)
	defer tick.Stop()
	for {
		select {
		case err := <-done:
			return err
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
			req := c.reconnectRequested.Load()
			if req == 0 || time.Since(time.Unix(0, req)) < wedgeGrace {
				continue
			}
			c.opts.Logger.Error(
				"relay: serve loop did not unwind after a forced reconnect; abandoning the session",
				"grace", wedgeGrace.String())
			// The goroutine stays parked (it holds no reconnect-critical
			// state once disowned); epoch guarding keeps its eventual
			// cleanup from touching the replacement session.
			c.abandonSession()
			return errors.New("relay: serve loop wedged after forced reconnect")
		}
	}
}

func (c *Client) connectAndServe(ctx context.Context) error {
	if c.opts.HostSigner == nil {
		return errors.New("relay: HostSigner is required for daemon auth")
	}
	// Build the WSS URL with a per-connect host-key challenge so the relay
	// can pin our identity. Format: ?daemon_id=...&ts=<unix>&pubkey=<b64>&sig=<b64>
	wsURL, err := authedSocketURL(c.opts.BaseURL, c.opts.DaemonID, c.opts.HostSigner)
	if err != nil {
		return err
	}
	// /register is idempotent and exists so the DO is materialized in case
	// this is the very first contact. The real auth happens on the WSS.
	if err := c.register(ctx); err != nil {
		return fmt.Errorf("register: %w", err)
	}
	// Bound the dial for the same reason register() is bounded: ctx is
	// daemon-lifetime, and a middlebox that completes the TCP handshake but
	// never answers the HTTP upgrade would park the reconnect loop here
	// forever — silently, since "relay connected" only logs on success.
	dialCtx, cancelDial := context.WithTimeout(ctx, dialTimeout)
	conn, _, err := websocket.Dial(dialCtx, wsURL, &websocket.DialOptions{
		HTTPHeader: http.Header{"x-bento-daemon-id": []string{c.opts.DaemonID}},
	})
	cancelDial()
	if err != nil {
		return fmt.Errorf("dial %s: %w", wsURL, err)
	}
	// Large messages are fine; SSH packets are bounded by SSH itself but we
	// don't want to clip them at the relay layer.
	conn.SetReadLimit(8 * 1024 * 1024)

	epoch := c.beginSession(conn)
	defer c.endSession(epoch)
	defer conn.Close(websocket.StatusNormalClosure, "shutdown")

	// Session-scoped context. pingLoop cancels this on pong timeout to
	// unblock conn.Read below — coder/websocket's Close alone doesn't
	// abort an in-flight Read, so without this the daemon would log
	// "forcing reconnect" and then hang forever instead of looping in Run.
	sessionCtx, cancelSession := context.WithCancel(ctx)
	defer cancelSession()
	go c.pingLoop(sessionCtx, conn, cancelSession)
	go c.appPingLoop(sessionCtx, conn, cancelSession)

	c.opts.Logger.Info("relay connected", "url", wsURL)

	for {
		typ, data, err := conn.Read(sessionCtx)
		if err != nil {
			if websocket.CloseStatus(err) == StatusWireVersionUnsupported {
				return fmt.Errorf("relay rejected wire version 0x%02x — daemon/relay version skew, update bento-daemon: %w", Version, err)
			}
			return err
		}
		if typ != websocket.MessageBinary {
			continue
		}
		fr, err := ParseFrame(data)
		if err != nil {
			if errors.Is(err, ErrVersionMismatch) {
				// Deterministic deployment skew: every following frame will
				// fail identically, so surface it in LastError and let Run's
				// backoff loop retry instead of silently dropping traffic.
				return fmt.Errorf("relay speaks a wire version we don't — update bento-daemon: %w", err)
			}
			c.opts.Logger.Debug("bad frame", "err", err, "len", len(data))
			continue
		}
		c.handle(fr)
	}
}

func (c *Client) handle(fr Frame) {
	switch fr.Type {
	case FrameControl:
		if fr.StreamID != ControlStream {
			return
		}
		var msg map[string]any
		if err := json.Unmarshal(fr.Payload, &msg); err != nil {
			c.opts.Logger.Debug("bad control json", "err", err)
			return
		}
		// Intercept pongs for the app-level liveness check before forwarding.
		// The pairing manager has no interest in them.
		if t, _ := msg["type"].(string); t == "pong" {
			if nonce, _ := msg["nonce"].(string); nonce != "" {
				c.deliverPong(nonce)
			}
			return
		}
		c.opts.Logger.Debug("control", "msg", msg)
		if c.control != nil {
			c.control.OnControl(msg)
		}
	case FrameOpen:
		if c.streams == nil {
			// No stream handler attached; reflect close so iOS isn't hung.
			c.sendFrame(Frame{Type: FrameClose, StreamID: fr.StreamID})
			return
		}
		sink, err := c.streams.OnOpen(fr.StreamID)
		if err != nil {
			c.opts.Logger.Warn("stream open failed", "id", fr.StreamID, "err", err)
			c.sendFrame(Frame{Type: FrameClose, StreamID: fr.StreamID})
			return
		}
		c.sinkMu.Lock()
		c.activeSink[fr.StreamID] = sink
		c.sinkMu.Unlock()
	case FrameData:
		c.sinkMu.Lock()
		sink := c.activeSink[fr.StreamID]
		c.sinkMu.Unlock()
		if sink == nil {
			return
		}
		if _, err := sink.Write(fr.Payload); err != nil {
			c.closeStream(fr.StreamID, "sink write failed")
		}
	case FrameClose:
		c.closeStream(fr.StreamID, "remote close")
	}
}

// WriterFor returns an io.Writer that the SSH server writes outbound bytes
// to. Writes are coalesced into one FrameData per ~batchWindow so that one
// PTY-output burst doesn't translate into hundreds of tiny WS messages — at
// CF Workers pricing each WS message is 1/20 of a request, so a chatty
// terminal session can burn the daily free quota inside an hour.
func (c *Client) WriterFor(streamID uint32) io.Writer {
	return &streamWriter{client: c, streamID: streamID}
}

const (
	// Time we'll hold bytes before flushing. Output-direction only, so this
	// shows up as terminal-render latency, not input echo latency. 25ms is
	// below the typical perceptual threshold for command output yet long
	// enough to coalesce most PTY bursts into single frames.
	batchWindow = 25 * time.Millisecond
	// Force a flush at this byte threshold even if the window hasn't
	// elapsed. Keeps backlog bounded for large outputs (e.g. `cat` of a
	// long file) and stays well under SSH's per-packet ceiling.
	batchMaxBytes = 16 * 1024
)

type streamWriter struct {
	client   *Client
	streamID uint32

	mu    sync.Mutex
	buf   []byte
	timer *time.Timer
}

// Write appends p to the per-stream buffer. If the buffer reaches
// batchMaxBytes we flush immediately; otherwise a timer flushes after
// batchWindow. The contract io.Writer-side stays unchanged: success means
// the bytes are owned by us (in the buffer or already on the wire).
func (w *streamWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	if w.buf == nil {
		// Reserve the frame header at the front so flushing can fill it in
		// place and hand the whole buffer to the websocket without another
		// payload-sized copy.
		w.buf = make([]byte, headerLen, headerLen+len(p))
	}
	w.buf = append(w.buf, p...)
	var toSend []byte
	if len(w.buf)-headerLen >= batchMaxBytes {
		if w.timer != nil {
			w.timer.Stop()
			w.timer = nil
		}
		toSend = w.buf
		w.buf = nil
	} else if w.timer == nil {
		w.timer = time.AfterFunc(batchWindow, w.flush)
	}
	w.mu.Unlock()

	if toSend != nil {
		if err := w.client.sendEncoded(fillHeader(toSend, FrameData, w.streamID)); err != nil {
			return 0, err
		}
	}
	return len(p), nil
}

// flush is invoked by the AfterFunc timer when batchWindow elapses with
// data still pending. We swap out the buffer under lock then send outside
// the lock so a slow wire doesn't pile up Writes behind us.
func (w *streamWriter) flush() {
	w.mu.Lock()
	data := w.buf
	w.buf = nil
	w.timer = nil
	w.mu.Unlock()
	if len(data) <= headerLen { // nil (len 0) or header-only: nothing to send
		return
	}
	_ = w.client.sendEncoded(fillHeader(data, FrameData, w.streamID))
}

// SendControl emits a daemon→relay JSON control frame (e.g. pair.open).
func (c *Client) SendControl(msg any) error {
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return c.sendFrame(Frame{Type: FrameControl, StreamID: ControlStream, Payload: b})
}

func (c *Client) sendFrame(fr Frame) error { return c.sendEncoded(fr.Encode()) }

// sendEncoded writes an already-encoded frame (header + payload) to the
// current websocket. The output hot path uses this directly with a buffer
// whose header was reserved up front (see streamWriter), avoiding the
// full-payload copy that Frame.Encode would incur per flush.
func (c *Client) sendEncoded(encoded []byte) error {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return errors.New("relay: not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	err := conn.Write(ctx, websocket.MessageBinary, encoded)
	if err == nil {
		c.lastWriteOK.Store(time.Now().UnixNano())
	}
	return err
}

// sinceLastWrite reports how long ago the last WS write completed on this
// session. Returns a large duration when nothing has been written yet, so a
// probe failure on an idle session is never forgiven.
func (c *Client) sinceLastWrite() time.Duration {
	ns := c.lastWriteOK.Load()
	if ns == 0 {
		return time.Hour
	}
	return time.Since(time.Unix(0, ns))
}

func (c *Client) closeStream(id uint32, reason string) {
	c.sinkMu.Lock()
	sink := c.activeSink[id]
	delete(c.activeSink, id)
	c.sinkMu.Unlock()
	if sink != nil {
		_ = sink.Close()
	}
	_ = c.sendFrame(Frame{Type: FrameClose, StreamID: id})
	c.opts.Logger.Debug("stream closed", "id", id, "reason", reason)
}

// pingLoop drives liveness checking with WebSocket-protocol PING frames.
//
// We used to send an app-level JSON {"type":"ping"} via SendControl, but
// websocket.Conn.Write only confirms the bytes were buffered for the kernel.
// On a half-open socket (Cloudflare silently dropped the WS but the TCP RST
// got eaten by a middlebox / NAT) the write keeps "succeeding" and the
// daemon believes it's connected for hours while iOS clients can't reach it.
//
// conn.Ping sends an RFC 6455 PING control frame and blocks until it sees
// the corresponding PONG. On timeout we both cancel `sessionCtx` (so the
// concurrent conn.Read returns) and close the WS — without the cancel, the
// reader sits forever and Run() never gets a chance to reconnect.
func (c *Client) pingLoop(ctx context.Context, conn *websocket.Conn, cancelSession context.CancelFunc) {
	gate := livenessGate{maxGraced: maxGracedProbes}
	t := time.NewTicker(c.opts.PingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pingCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				if !gate.shouldReconnect(c.sinceLastWrite(), c.opts.PingEvery) {
					c.opts.Logger.Warn("relay ping timed out but writes are progressing; tolerating (bulk transfer?)",
						"err", err, "graced", gate.graced)
					continue
				}
				c.opts.Logger.Warn("relay ping failed; forcing reconnect", "err", err)
				c.noteReconnectRequested()
				cancelSession()
				_ = conn.Close(websocket.StatusGoingAway, "ping timeout")
				return
			}
			gate.probeSucceeded()
		}
	}
}

// appPingLoop runs alongside pingLoop and catches the half-death case where
// WS PING/PONG (protocol-level control frames) still round-trip but the
// app-layer binary frames are silently dropped — we hit this when a CF Worker
// deploy left a daemon WS in a stuck state. The trip is end-to-end through
// the DO's handleDaemonControl, so anything that broke the data path also
// breaks this and forces reconnect.
func (c *Client) appPingLoop(ctx context.Context, conn *websocket.Conn, cancelSession context.CancelFunc) {
	gate := livenessGate{maxGraced: maxGracedProbes}
	t := time.NewTicker(c.opts.PingEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := c.sendAppPing(ctx, 8*time.Second); err != nil {
				if ctx.Err() != nil {
					return
				}
				if !gate.shouldReconnect(c.sinceLastWrite(), c.opts.PingEvery) {
					c.opts.Logger.Warn("relay app ping timed out but writes are progressing; tolerating (bulk transfer?)",
						"err", err, "graced", gate.graced)
					continue
				}
				c.opts.Logger.Warn("relay app ping failed; forcing reconnect", "err", err)
				c.noteReconnectRequested()
				cancelSession()
				_ = conn.Close(websocket.StatusGoingAway, "app ping timeout")
				return
			}
			gate.probeSucceeded()
		}
	}
}

// sendAppPing emits a {type:"ping",nonce:X} and waits for the matching
// {type:"pong",nonce:X}. Returns nil on round-trip, error on timeout or
// send failure.
func (c *Client) sendAppPing(ctx context.Context, timeout time.Duration) error {
	var nb [12]byte
	if _, err := rand.Read(nb[:]); err != nil {
		return err
	}
	nonce := hex.EncodeToString(nb[:])

	ch := make(chan struct{})
	c.pongMu.Lock()
	c.pongExpect = nonce
	c.pongCh = ch
	c.pongMu.Unlock()

	defer func() {
		c.pongMu.Lock()
		if c.pongExpect == nonce {
			c.pongExpect = ""
			c.pongCh = nil
		}
		c.pongMu.Unlock()
	}()

	if err := c.SendControl(map[string]any{"type": "ping", "nonce": nonce}); err != nil {
		return err
	}
	select {
	case <-ch:
		return nil
	case <-time.After(timeout):
		return errors.New("app pong timeout")
	case <-ctx.Done():
		return ctx.Err()
	}
}

// deliverPong is called by handle() when a {type:"pong"} arrives. Matches
// against the currently expected nonce and signals the waiter.
func (c *Client) deliverPong(nonce string) {
	c.pongMu.Lock()
	defer c.pongMu.Unlock()
	if c.pongExpect == "" || nonce != c.pongExpect {
		return
	}
	if c.pongCh != nil {
		close(c.pongCh)
		c.pongCh = nil
	}
	c.pongExpect = ""
}

// ForceReconnect tears down the current WSS so Run() loops into a fresh
// dial. Called by pairing.Manager when pair.open times out — the WS may be
// app-layer half-dead and a fresh socket usually clears it.
func (c *Client) ForceReconnect(reason string) {
	c.mu.Lock()
	conn := c.conn
	c.mu.Unlock()
	if conn == nil {
		return
	}
	c.opts.Logger.Warn("relay: force reconnect", "reason", reason)
	c.noteReconnectRequested()
	_ = conn.Close(websocket.StatusGoingAway, reason)
}

// noteReconnectRequested arms Run's wedge watchdog: from here the serve loop
// is expected to unwind promptly, and failing to is a bug worth recovering
// from. First writer wins, so the grace runs from the earliest giving-up.
func (c *Client) noteReconnectRequested() {
	c.reconnectRequested.CompareAndSwap(0, time.Now().UnixNano())
}

func (c *Client) register(ctx context.Context) error {
	// Bound this call: ctx is daemon-lifetime, and an endpoint that accepts
	// TCP but never responds would otherwise wedge the reconnect loop here
	// (no ping loop is running yet at this point).
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	u, err := url.Parse(c.opts.BaseURL)
	if err != nil {
		return err
	}
	u.Path = "/v1/daemon/register"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("x-bento-daemon-id", c.opts.DaemonID)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("register status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

// beginSession publishes a freshly dialed socket and returns its epoch.
func (c *Client) beginSession(conn *websocket.Conn) uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.epoch++
	c.connected = true
	c.conn = conn
	c.lastError = ""
	// Fresh session: a write that succeeded on the previous socket must not
	// grace a probe failure on this one.
	c.lastWriteOK.Store(0)
	c.reconnectRequested.Store(0)
	return c.epoch
}

// endSession clears the live socket, but only if `epoch` is still current.
// A session Run gave up on (see the wedge watchdog) may unwind minutes later;
// its deferred cleanup must not mark the session that replaced it as dead.
func (c *Client) endSession(epoch uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.epoch != epoch {
		return
	}
	c.connected = false
	c.conn = nil
}

// abandonSession disowns the current socket without waiting for its serve
// loop to return: the epoch bump makes that goroutine's endSession a no-op,
// so Run is free to dial a replacement immediately.
func (c *Client) abandonSession() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.epoch++
	c.connected = false
	c.conn = nil
}

func (c *Client) setError(msg string) {
	c.mu.Lock()
	c.lastError = msg
	c.mu.Unlock()
}

// ChallengeMessage is the canonical string the daemon signs and the relay
// verifies. Both sides MUST produce the same byte sequence.
func ChallengeMessage(daemonID string, unixSec int64) []byte {
	return []byte(fmt.Sprintf("bento-daemon-register:%s:%d", daemonID, unixSec))
}

// authedSocketURL turns "https://host" into a wss URL carrying the host-key
// challenge. The signature covers ChallengeMessage(daemonID, ts).
func authedSocketURL(base, daemonID string, signer Ed25519HostSigner) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("relay base must be http(s), got %q", u.Scheme)
	}
	u.Path = "/v1/daemon/socket"
	ts := time.Now().Unix()
	sig, err := signer.SignRaw(ChallengeMessage(daemonID, ts))
	if err != nil {
		return "", fmt.Errorf("sign challenge: %w", err)
	}
	q := u.Query()
	q.Set("daemon_id", daemonID)
	// Announce our wire version so the relay can track the fleet's version
	// distribution (telemetry blob on daemon_socket_connected) before ever
	// planning a breaking change. Absent param = pre-proto daemon.
	q.Set("proto", strconv.Itoa(int(Version)))
	q.Set("ts", strconv.FormatInt(ts, 10))
	q.Set("pubkey", base64.RawURLEncoding.EncodeToString(signer.RawPublicKey()))
	q.Set("sig", base64.RawURLEncoding.EncodeToString(sig))
	u.RawQuery = q.Encode()
	return u.String(), nil
}
