package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/novashang/bento/desktop/internal/ipc"
	"github.com/novashang/bento/desktop/internal/pairing"
	"github.com/novashang/bento/desktop/internal/relay"
	"github.com/novashang/bento/desktop/internal/rpc"
	"github.com/novashang/bento/desktop/internal/sshserver"
	"github.com/novashang/bento/desktop/internal/state"
)

// daemon is the long-lived process: relay client + IPC server + pidfile +
// embedded SSH server + pairing manager.
type daemon struct {
	startedAt time.Time
	log       *slog.Logger
	cfg       state.Config

	relay     *relay.Client
	control   *controlHub
	authKeys  *sshserver.AuthorizedKeys
	hostKeyFP string
	pair      *pairing.Manager
}

func runDaemon(ctx context.Context, relayOverride string) error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg, err := state.LoadConfig()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	if relayOverride != "" {
		cfg.RelayURL = relayOverride
	}
	if cfg.RelayURL == "" {
		return errors.New("relay URL not set; pass --relay or write ~/.bento/config.json")
	}
	if cfg.DaemonID == "" {
		cfg.DaemonID = uuid.NewString()
	}
	if err := state.SaveConfig(cfg); err != nil {
		return fmt.Errorf("save config: %w", err)
	}

	if err := writePidfile(); err != nil {
		return err
	}
	defer removePidfile()

	// SSH host key + authorized devices.
	hostKeyPath, _ := state.HostKeyPath()
	signer, err := sshserver.LoadOrCreateHostKey(hostKeyPath)
	if err != nil {
		return fmt.Errorf("host key: %w", err)
	}
	authKeysPath, _ := state.AuthorizedKeysPath()
	authKeys, err := sshserver.OpenAuthorizedKeys(authKeysPath)
	if err != nil {
		return fmt.Errorf("authorized_keys: %w", err)
	}

	d := &daemon{
		startedAt: time.Now(),
		log:       logger,
		cfg:       cfg,
		control:   newControlHub(logger),
		authKeys:  authKeys,
		hostKeyFP: sshserver.Fingerprint(signer),
	}

	sshd := sshserver.New(sshserver.Options{
		Log:        logger,
		Keys:       authKeys,
		HostSigner: signer,
	})
	d.relay = relay.New(relay.Options{
		BaseURL:    cfg.RelayURL,
		DaemonID:   cfg.DaemonID,
		HostSigner: sshserver.HostSigner{Signer: signer},
		Logger:     logger,
	}, sshd, d.control)
	sshd.RebindRelay(d.relay)

	d.pair = pairing.NewManager(logger, d.relay, authKeys, d.hostKeyFP)
	d.control.attach(d.pair)

	srv := ipc.New(d, logger)

	ctx, cancel := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer cancel()

	go dumpGoroutinesOnSignal(ctx, logger)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		d.relay.Run(ctx)
	}()
	go func() {
		defer wg.Done()
		if err := srv.Listen(ctx); err != nil && !errors.Is(err, context.Canceled) {
			d.log.Error("ipc server stopped", "err", err)
		}
	}()

	logger.Info("bento-daemon started",
		"version", version,
		"daemon_id", cfg.DaemonID,
		"relay", cfg.RelayURL)

	<-ctx.Done()
	logger.Info("shutting down")
	_ = srv.Close()
	wg.Wait()
	return nil
}

// ---- Daemon interface for ipc.Server ----

func (d *daemon) StatusSnapshot() rpc.StatusResp {
	return rpc.StatusResp{
		Version:       version,
		PID:           os.Getpid(),
		UptimeSec:     int64(time.Since(d.startedAt).Seconds()),
		RelayURL:      d.cfg.RelayURL,
		RelayConn:     d.relay.Connected(),
		DaemonID:      d.cfg.DaemonID,
		PairedDevices: len(d.authKeys.List()),
	}
}

// BeginPairing / CancelPairing delegate to the pairing manager.
func (d *daemon) BeginPairing(ctx context.Context, ttl time.Duration) (rpc.PairBeginResp, error) {
	return d.pair.Begin(ctx, ttl)
}
func (d *daemon) CancelPairing(ctx context.Context) error { return d.pair.Cancel(ctx) }

func (d *daemon) ListDevices() []rpc.DeviceSummary {
	keys := d.authKeys.List()
	out := make([]rpc.DeviceSummary, 0, len(keys))
	for _, k := range keys {
		out = append(out, rpc.DeviceSummary{
			DeviceID:    k.DeviceID,
			Label:       k.Label,
			PairedAt:    k.PairedAt,
			KeyFingerSP: k.Fingerprint(),
		})
	}
	return out
}

func (d *daemon) RevokeDevice(id string) error {
	found, err := d.authKeys.Revoke(id)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("device %s not paired", id)
	}
	return nil
}

// ---- control hub ----

// controlHub receives JSON control frames from the relay and fans them out
// to subsystems that want them (pairing manager today; more in future stages).
type controlHub struct {
	log  *slog.Logger
	mu   sync.Mutex
	pair *pairing.Manager
}

func newControlHub(log *slog.Logger) *controlHub { return &controlHub{log: log} }

func (h *controlHub) attach(p *pairing.Manager) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.pair = p
}

func (h *controlHub) OnControl(msg map[string]any) {
	t, _ := msg["type"].(string)
	if t != "pong" { // pong is noisy; the rest is interesting
		h.log.Info("relay control", "msg", msg)
	}
	h.mu.Lock()
	p := h.pair
	h.mu.Unlock()
	if p != nil {
		p.OnControl(msg)
	}
}

// ---- pidfile ----

func writePidfile() error {
	p, err := state.PidPath()
	if err != nil {
		return err
	}
	return os.WriteFile(p, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o600)
}

func removePidfile() {
	if p, err := state.PidPath(); err == nil {
		_ = os.Remove(p)
	}
}

// dumpGoroutinesOnSignal writes every goroutine's stack to the log on SIGUSR1
// and keeps the daemon running.
//
// WHY: the daemon holds every attached tmux session, so the usual way to get
// stacks out of a hung Go process — SIGQUIT — costs the user all of them, and
// the restart destroys the very state the dump was taken from. A wedged daemon
// can now be inspected in place, without dropping a single session:
//
//	pkill -USR1 -f bento-daemon
//	tail -n 400 ~/.bento/daemon.log
func dumpGoroutinesOnSignal(ctx context.Context, logger *slog.Logger) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGUSR1)
	defer signal.Stop(ch)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ch:
			logger.Warn("goroutine dump requested (SIGUSR1)",
				"goroutines", runtime.NumGoroutine())
			// Straight to stderr — which the daemon log captures. Going through
			// slog would escape every newline and leave the stacks unreadable,
			// which defeats the point.
			fmt.Fprintf(os.Stderr,
				"\n=== bento-daemon goroutine dump ===\n%s\n=== end goroutine dump ===\n",
				goroutineStacks())
		}
	}
}

// goroutineStacks renders all goroutine stacks, growing the buffer until the
// dump fits (runtime.Stack silently truncates to what it is given).
func goroutineStacks() []byte {
	const maxDump = 64 << 20
	for size := 1 << 20; ; size *= 2 {
		buf := make([]byte, size)
		n := runtime.Stack(buf, true)
		if n < size || size >= maxDump {
			return buf[:n]
		}
	}
}
