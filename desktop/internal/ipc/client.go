package ipc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/novashang/bento/desktop/internal/rpc"
	"github.com/novashang/bento/desktop/internal/state"
)

// Client speaks HTTP-over-Unix to the running daemon. Used by `bento` CLI
// and by the Mac app.
type Client struct {
	http *http.Client
}

// NewClient resolves the socket path via state.SocketPath().
func NewClient() (*Client, error) {
	sock, err := state.SocketPath()
	if err != nil {
		return nil, err
	}
	return &Client{
		http: &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _ string, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", sock)
				},
			},
			Timeout: 10 * time.Second,
		},
	}, nil
}

// Status fetches /v1/status.
func (c *Client) Status(ctx context.Context) (rpc.StatusResp, error) {
	var out rpc.StatusResp
	err := c.get(ctx, rpc.PathStatus, &out)
	return out, err
}

// PairBegin opens a pairing window and returns the 6-digit code.
func (c *Client) PairBegin(ctx context.Context) (rpc.PairBeginResp, error) {
	var out rpc.PairBeginResp
	err := c.post(ctx, rpc.PathPairBegin, nil, &out)
	return out, err
}

// PairCancel closes any pending pairing window.
func (c *Client) PairCancel(ctx context.Context) error {
	return c.post(ctx, rpc.PathPairCancel, nil, nil)
}

// Devices lists paired iOS devices.
func (c *Client) Devices(ctx context.Context) (rpc.DeviceListResp, error) {
	var out rpc.DeviceListResp
	err := c.get(ctx, rpc.PathDeviceList, &out)
	return out, err
}

// Revoke removes a device.
func (c *Client) Revoke(ctx context.Context, deviceID string) error {
	return c.post(ctx, rpc.PathDeviceRevoke, rpc.DeviceRevokeReq{DeviceID: deviceID}, nil)
}

// PrintStatus dials the running daemon and writes its /v1/status response as
// JSON to w. Shared by the `bento status` and `bento-daemon status`
// subcommands, which differ only in indent (the CLI pretty-prints, the daemon
// emits compact single-line JSON).
func PrintStatus(ctx context.Context, w io.Writer, indent bool) error {
	c, err := NewClient()
	if err != nil {
		return err
	}
	st, err := c.Status(ctx)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(w)
	if indent {
		enc.SetIndent("", "  ")
	}
	return enc.Encode(st)
}

// ---- helpers ----

func (c *Client) get(ctx context.Context, path string, out any) error {
	return c.do(ctx, http.MethodGet, path, nil, out)
}

func (c *Client) post(ctx context.Context, path string, body, out any) error {
	return c.do(ctx, http.MethodPost, path, body, out)
}

func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://bento"+path, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("daemon not reachable (is it running?): %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		var er rpc.ErrorResp
		_ = json.NewDecoder(resp.Body).Decode(&er)
		if er.Error == "" {
			return fmt.Errorf("status %d", resp.StatusCode)
		}
		return errors.New(er.Error)
	}
	if out == nil || resp.StatusCode == http.StatusNoContent {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
