// Package ipc serves the CLI and the macOS app over a per-user Unix socket.
// It is purely a control plane — no SSH traffic flows through here.
package ipc

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/novashang/bento/desktop/internal/rpc"
	"github.com/novashang/bento/desktop/internal/state"
)

// Daemon is the subset of the daemon's internals that handlers need. Keeping
// this as an interface lets us swap mocks in tests.
type Daemon interface {
	StatusSnapshot() rpc.StatusResp
	BeginPairing(ctx context.Context, ttl time.Duration) (rpc.PairBeginResp, error)
	CancelPairing(ctx context.Context) error
	ListDevices() []rpc.DeviceSummary
	RevokeDevice(deviceID string) error
}

// Server is the HTTP-over-Unix RPC server.
type Server struct {
	d      Daemon
	log    *slog.Logger
	mux    *http.ServeMux
	srv    *http.Server
	mu     sync.Mutex
	sock   string
	closed bool
}

// New returns a not-yet-listening Server.
func New(d Daemon, log *slog.Logger) *Server {
	s := &Server{d: d, log: log, mux: http.NewServeMux()}
	s.routes()
	return s
}

func (s *Server) routes() {
	s.mux.HandleFunc(rpc.PathStatus, s.handleStatus)
	s.mux.HandleFunc(rpc.PathRelayStatus, s.handleRelayStatus)
	s.mux.HandleFunc(rpc.PathPairBegin, s.handlePairBegin)
	s.mux.HandleFunc(rpc.PathPairCancel, s.handlePairCancel)
	s.mux.HandleFunc(rpc.PathDeviceList, s.handleDeviceList)
	s.mux.HandleFunc(rpc.PathDeviceRevoke, s.handleDeviceRevoke)
}

// Listen binds the Unix socket and serves until Close is called.
func (s *Server) Listen(ctx context.Context) error {
	sock, err := state.SocketPath()
	if err != nil {
		return err
	}
	s.sock = sock

	// Stale socket from a crashed prior run? Remove if no one is listening.
	if err := removeIfStale(sock); err != nil {
		return err
	}

	ln, err := net.Listen("unix", sock)
	if err != nil {
		return err
	}
	if err := os.Chmod(sock, 0o600); err != nil {
		_ = ln.Close()
		return err
	}
	s.srv = &http.Server{Handler: s.mux, ReadHeaderTimeout: 5 * time.Second}

	errCh := make(chan error, 1)
	go func() { errCh <- s.srv.Serve(ln) }()

	select {
	case <-ctx.Done():
		_ = s.Close()
		return ctx.Err()
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// Close stops the server and removes the socket file.
func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	if s.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = s.srv.Shutdown(ctx)
	}
	if s.sock != "" {
		_ = os.Remove(s.sock)
	}
	return nil
}

// ---- handlers ----

func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.d.StatusSnapshot())
}

func (s *Server) handleRelayStatus(w http.ResponseWriter, _ *http.Request) {
	snap := s.d.StatusSnapshot()
	writeJSON(w, http.StatusOK, rpc.RelayStatusResp{
		Connected: snap.RelayConn,
		URL:       snap.RelayURL,
		DaemonID:  snap.DaemonID,
	})
}

func (s *Server) handlePairBegin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	resp, err := s.d.BeginPairing(r.Context(), 60*time.Second)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handlePairCancel(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	if err := s.d.CancelPairing(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeviceList(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, rpc.DeviceListResp{Devices: s.d.ListDevices()})
}

func (s *Server) handleDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	var req rpc.DeviceRevokeReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad json")
		return
	}
	if err := s.d.RevokeDevice(req.DeviceID); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, rpc.ErrorResp{Error: msg})
}

// removeIfStale unlinks the socket only if dialing it fails — otherwise we'd
// step on a live daemon.
func removeIfStale(path string) error {
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	c, err := net.DialTimeout("unix", path, 200*time.Millisecond)
	if err == nil {
		_ = c.Close()
		return errors.New("ipc: another bento-daemon appears to be running")
	}
	return os.Remove(path)
}
