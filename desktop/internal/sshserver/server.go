package sshserver

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/novashang/bento/desktop/internal/relay"
	"golang.org/x/crypto/ssh"
)

// Server is the embedded SSH server. It accepts net.Conn-like relay streams
// (one per iOS connection) and serves an interactive shell on each.
type Server struct {
	log    *slog.Logger
	keys   *AuthorizedKeys
	signer ssh.Signer

	mu    sync.Mutex
	relay *relay.Client
}

// Options for New.
type Options struct {
	Log        *slog.Logger
	Keys       *AuthorizedKeys
	HostSigner ssh.Signer
}

// New constructs a server. The caller must call RebindRelay before any
// stream arrives so OnOpen knows where to write outbound bytes.
func New(opts Options) *Server {
	if opts.Log == nil {
		opts.Log = slog.Default()
	}
	return &Server{
		log:    opts.Log,
		keys:   opts.Keys,
		signer: opts.HostSigner,
	}
}

// RebindRelay sets the relay reference used to obtain per-stream writers.
// Lives as a setter (rather than a constructor arg) because the daemon
// builds the relay client with the SSH server as its StreamHandler — a
// chicken-and-egg cycle resolved by wiring the relay in after construction.
func (s *Server) RebindRelay(c *relay.Client) {
	s.mu.Lock()
	s.relay = c
	s.mu.Unlock()
}

// OnOpen implements relay.StreamHandler. It returns a sink that the relay
// client will forward incoming FrameData payloads into.
func (s *Server) OnOpen(streamID uint32) (relay.StreamSink, error) {
	s.mu.Lock()
	r := s.relay
	s.mu.Unlock()
	conn := newStreamConn(r.WriterFor(streamID))
	go s.serveOne(streamID, conn)
	return &sshSink{conn: conn}, nil
}

// sshSink adapts streamConn to relay.StreamSink. Writes from the relay go
// into the inbound side of the pipe; Close shuts the stream down.
type sshSink struct{ conn *streamConn }

func (s *sshSink) Write(p []byte) (int, error) { return len(p), s.conn.FeedFromRelay(p) }
func (s *sshSink) Close() error                { return s.conn.Close() }

func (s *Server) serveOne(streamID uint32, c *streamConn) {
	defer c.Close()
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: s.publicKeyCallback,
		ServerVersion:     "SSH-2.0-Bento-daemon",
	}
	cfg.AddHostKey(s.signer)

	sconn, chans, reqs, err := ssh.NewServerConn(c, cfg)
	if err != nil {
		s.log.Warn("ssh handshake failed", "stream", streamID, "err", err)
		return
	}
	dev := sconn.Permissions.Extensions["device_id"]
	started := time.Now()
	s.log.Info("ssh session established", "stream", streamID, "device", dev, "user", sconn.User())
	defer sconn.Close()

	// The daemon logged every session's BIRTH and none of its deaths, so a
	// client stuck in a reconnect loop showed up here as a healthy-looking
	// column of "established" lines with no hint of what kept ending them —
	// diagnosing it meant guessing from the phone's side alone. The lifetime
	// is the diagnostic: sub-second means something tore the stream down
	// immediately, minutes means an ordinary drop.
	//
	// `sconn.Wait()` carries WHY the connection ended — clean EOF (the client
	// or tunnel went away) versus an SSH protocol error (corrupt or misordered
	// packets), which are opposite bugs with opposite fixes. Ranging over
	// `chans` and returning threw that away, so the daemon could only ever say
	// "a session ended".
	waitErr := make(chan error, 1)
	go func() { waitErr <- sconn.Wait() }()
	defer func() {
		var reason string
		select {
		case err := <-waitErr:
			reason = "clean eof"
			if err != nil && err != io.EOF {
				reason = err.Error()
			}
		default:
			reason = "channels closed"
		}
		s.log.Info("ssh session ended", "stream", streamID, "device", dev,
			"lifetime", time.Since(started).Round(time.Millisecond).String(),
			"reason", reason)
	}()

	go ssh.DiscardRequests(reqs)
	for newCh := range chans {
		switch newCh.ChannelType() {
		case "session":
			go s.handleSession(newCh)
		default:
			_ = newCh.Reject(ssh.UnknownChannelType, "only session is supported")
		}
	}
}

func (s *Server) publicKeyCallback(meta ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
	ak := s.keys.Lookup(key)
	if ak == nil {
		return nil, fmt.Errorf("unknown key: %s", ssh.FingerprintSHA256(key))
	}
	return &ssh.Permissions{
		Extensions: map[string]string{
			"device_id":       ak.DeviceID,
			"device_label":    ak.Label,
			"key_fingerprint": ak.Fingerprint(),
		},
	}, nil
}

// handleSession serves one session channel: process env/pty/shell requests,
// then bridge the channel to a PTY-spawned $SHELL.
func (s *Server) handleSession(newCh ssh.NewChannel) {
	ch, reqs, err := newCh.Accept()
	if err != nil {
		return
	}
	defer ch.Close()

	var (
		ptyReq    *ptyRequest
		shellOnce sync.Once
	)
	envv := os.Environ()

	for req := range reqs {
		switch req.Type {
		case "pty-req":
			p, err := parsePTYReq(req.Payload)
			if err != nil {
				_ = req.Reply(false, nil)
				continue
			}
			ptyReq = p
			_ = req.Reply(true, nil)
		case "env":
			if name, val, ok := parseEnv(req.Payload); ok {
				envv = append(envv, name+"="+val)
			}
			_ = req.Reply(true, nil)
		case "shell":
			_ = req.Reply(true, nil)
			// Spawn in a goroutine: spawnShell blocks on cmd.Wait(), so running
			// it inline would freeze this request loop and later requests
			// (notably window-change) would never be processed — leaving the PTY
			// stuck at the initial pty-req size while the client renders a
			// different grid.
			shellOnce.Do(func() { go s.spawnShell(ch, ptyReq, envv) })
		case "exec":
			_ = req.Reply(false, nil) // interactive shells only
		case "subsystem":
			// "bento-file": one-shot read-only file fetch for tap-to-preview
			// (see filefetch.go). Anything else (incl. real sftp) is refused.
			if name, ok := parseSubsystem(req.Payload); ok && name == "bento-file" {
				_ = req.Reply(true, nil)
				go s.serveFileFetch(ch)
			} else {
				_ = req.Reply(false, nil)
			}
		case "window-change":
			if ptyReq != nil {
				if cols, rows, ok := parseWindowChange(req.Payload); ok {
					ptyReq.mu.Lock()
					ptyReq.cols, ptyReq.rows = cols, rows
					if ptyReq.tty != nil {
						_ = pty.Setsize(ptyReq.tty, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
					}
					ptyReq.mu.Unlock()
				}
			}
			_ = req.Reply(true, nil)
		default:
			_ = req.Reply(false, nil)
		}
	}
}

func (s *Server) spawnShell(ch ssh.Channel, p *ptyRequest, envv []string) {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	cmd := exec.Command(shell, "-l")
	cmd.Env = envv
	if p != nil && p.term != "" {
		cmd.Env = append(cmd.Env, "TERM="+p.term)
	}

	tty, err := pty.Start(cmd)
	if err != nil {
		fmt.Fprintln(ch.Stderr(), "bento: failed to start shell:", err)
		_, _ = ch.SendRequest("exit-status", false, marshalExitStatus(127))
		_ = ch.Close()
		return
	}
	if p != nil {
		p.mu.Lock()
		_ = pty.Setsize(tty, &pty.Winsize{Cols: uint16(p.cols), Rows: uint16(p.rows)})
		p.tty = tty
		p.mu.Unlock()
	}

	// Pipe SSH ↔ PTY in both directions. Both goroutines exit when either
	// side closes; we wait for the process and then signal SSH with the
	// exit status.
	go func() { _, _ = io.Copy(ch, tty) }()
	go func() {
		_, _ = io.Copy(tty, ch)
		// This copy returning means the channel side is gone (client vanished,
		// tunnel dropped) or the tty already closed. If the shell is still
		// running, no client can ever reach it again — reap it, or its tmux
		// -CC client lingers attached to the session forever. Harmless no-op
		// when the process already exited (the normal path below).
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}()

	state, _ := cmd.Process.Wait()
	_ = tty.Close()

	code := 0
	if state != nil && !state.Success() {
		if w, ok := state.Sys().(interface{ ExitStatus() int }); ok {
			code = w.ExitStatus()
		} else {
			code = 1
		}
	}
	_, _ = ch.SendRequest("exit-status", false, marshalExitStatus(uint32(code)))
	// Close the channel so the client's SSH layer sees the session end
	// (channelInactive) — exit-status alone is easy for clients to miss, and
	// leaving the channel open kept handleSession's request loop (and this
	// goroutine's parent resources) alive until the whole connection died.
	_ = ch.Close()
}
