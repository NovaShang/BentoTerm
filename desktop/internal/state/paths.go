// Package state owns ~/.bento on disk: host key, authorized_keys, config,
// pid file, and the daemon Unix socket. All daemon/CLI code routes through
// here so we have one place to override paths (BENTO_HOME) in tests.
package state

import (
	"os"
	"path/filepath"
)

// Home returns the Bento config dir, creating it if necessary.
func Home() (string, error) {
	if p := os.Getenv("BENTO_HOME"); p != "" {
		return p, os.MkdirAll(p, 0o700)
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(h, ".bento")
	return dir, os.MkdirAll(dir, 0o700)
}

// File returns an absolute path inside the Bento home dir.
func File(name string) (string, error) {
	root, err := Home()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, name), nil
}

// SocketPath is where the daemon listens for CLI/Mac-app RPC.
func SocketPath() (string, error) {
	if p := os.Getenv("BENTO_SOCKET"); p != "" {
		return p, nil
	}
	return File("daemon.sock")
}

// PidPath is the daemon pidfile.
func PidPath() (string, error) { return File("daemon.pid") }

// HostKeyPath is the daemon's SSH host key (Ed25519, OpenSSH format).
func HostKeyPath() (string, error) { return File("ssh_host_ed25519_key") }

// AuthorizedKeysPath is one OpenSSH authorized_keys line per paired device.
func AuthorizedKeysPath() (string, error) { return File("authorized_keys") }

// ConfigPath holds the runtime config (relay URL, daemon_id).
func ConfigPath() (string, error) { return File("config.json") }

// LogPath is the daemon log file.
func LogPath() (string, error) { return File("daemon.log") }
