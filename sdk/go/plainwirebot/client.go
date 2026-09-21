package plainwirebot

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	DefaultTimeout      = 15 * time.Second
	DefaultMaxResponse  = 2 << 20
	MaxRequestBodyBytes = 64 << 10
)

type Client struct {
	base             *url.URL
	token            string
	http             *http.Client
	MaxResponseBytes int64
}

type Response struct {
	Status int
	Body   []byte
}

type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string { return fmt.Sprintf("Plainwire API returned HTTP %d", e.Status) }

type CommandOption struct {
	Name        string `json:"name"`
	Type        string `json:"type"`
	Required    bool   `json:"required,omitempty"`
	Description string `json:"description,omitempty"`
}

type CommandDefinition struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Options     []CommandOption `json:"options,omitempty"`
}

type CommandClaim struct {
	ID               int64          `json:"id"`
	CommandID        int64          `json:"command_id"`
	Command          string         `json:"command"`
	ServerID         int64          `json:"server_id"`
	ChannelID        int64          `json:"channel_id"`
	UserID           *int64         `json:"user_id"`
	RequestMessageID *int64         `json:"request_message_id"`
	Args             map[string]any `json:"args"`
	Options          map[string]any `json:"options"`
	GuildID          int64          `json:"guild_id"`
	ClaimToken       string         `json:"claim_token"`
	LeaseUntil       int64          `json:"lease_until"`
	Attempt          int            `json:"attempt"`
	CreatedAt        int64          `json:"created_at"`
}

func (c CommandClaim) Option(name string) (any, bool) {
	if c.Options != nil {
		if value, ok := c.Options[name]; ok {
			return value, true
		}
	}
	if c.Args == nil {
		return nil, false
	}
	value, ok := c.Args[name]
	return value, ok
}

func New(baseURL, token string) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("invalid Plainwire base URL")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && loopbackHost(u.Hostname())) {
		return nil, errors.New("Plainwire bots require HTTPS except on loopback")
	}
	if !strings.HasPrefix(token, "pwb_") || len(token) < 16 || len(token) > 256 || strings.ContainsAny(token, "\r\n") {
		return nil, errors.New("invalid Plainwire bot token")
	}
	u.Path = strings.TrimRight(u.Path, "/")
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 12 * time.Second
	transport.TLSHandshakeTimeout = 8 * time.Second
	return &Client{
		base:             u,
		token:            token,
		MaxResponseBytes: DefaultMaxResponse,
		http: &http.Client{
			Timeout:       DefaultTimeout,
			Transport:     transport,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

func loopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (c *Client) Request(ctx context.Context, method, path string, body any) (*Response, error) {
	if c == nil || c.base == nil || c.http == nil {
		return nil, errors.New("nil Plainwire client")
	}
	if !strings.HasPrefix(path, "/") || strings.ContainsAny(path, "\r\n") || strings.Contains(path, "://") {
		return nil, errors.New("invalid Plainwire API path")
	}
	var payload []byte
	var err error
	if body != nil {
		payload, err = json.Marshal(body)
		if err != nil {
			return nil, err
		}
		if len(payload) > MaxRequestBodyBytes {
			return nil, errors.New("request body too large")
		}
	}
	target := *c.base
	target.Path = strings.TrimRight(c.base.Path, "/") + path
	target.RawQuery = ""
	if q := strings.IndexByte(path, '?'); q >= 0 {
		target.Path = strings.TrimRight(c.base.Path, "/") + path[:q]
		target.RawQuery = path[q+1:]
	}
	req, err := http.NewRequestWithContext(ctx, method, target.String(), bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bot "+c.token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "plainwire-go-bot/2.4")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	max := c.MaxResponseBytes
	if max <= 0 {
		max = DefaultMaxResponse
	}
	limited := io.LimitReader(res.Body, max+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, errors.New("Plainwire response too large")
	}
	out := &Response{Status: res.StatusCode, Body: data}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return out, &APIError{Status: res.StatusCode, Body: string(data)}
	}
	return out, nil
}

func (c *Client) get(ctx context.Context, path string) (*Response, error) {
	return c.Request(ctx, http.MethodGet, path, nil)
}
func (c *Client) post(ctx context.Context, path string, body any) (*Response, error) {
	return c.Request(ctx, http.MethodPost, path, body)
}

func (c *Client) Capabilities(ctx context.Context) (*Response, error) {
	return c.get(ctx, "/api/bot/v1")
}
func (c *Client) Me(ctx context.Context) (*Response, error) { return c.get(ctx, "/api/bot/v1/me") }
func (c *Client) Server(ctx context.Context) (*Response, error) {
	return c.get(ctx, "/api/bot/v1/server")
}
func (c *Client) Channels(ctx context.Context) (*Response, error) {
	return c.get(ctx, "/api/bot/v1/channels")
}
func (c *Client) Messages(ctx context.Context, channelID, before, after int64) (*Response, error) {
	q := url.Values{}
	if before > 0 {
		q.Set("before", strconv.FormatInt(before, 10))
	}
	if after > 0 {
		q.Set("after", strconv.FormatInt(after, 10))
	}
	path := fmt.Sprintf("/api/bot/v1/channels/%d/messages", channelID)
	if encoded := q.Encode(); encoded != "" {
		path += "?" + encoded
	}
	return c.get(ctx, path)
}
func (c *Client) SendMessage(ctx context.Context, channelID int64, body string, replyTo int64) (*Response, error) {
	payload := map[string]any{"body": body}
	if replyTo > 0 {
		payload["reply_to_id"] = replyTo
	}
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/channels/%d/messages", channelID), payload)
}
func (c *Client) DeleteMessage(ctx context.Context, messageID int64) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/messages/%d/delete", messageID), map[string]any{})
}
func (c *Client) ToggleReaction(ctx context.Context, messageID int64, emoji string) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/messages/%d/reaction", messageID), map[string]any{"emoji": emoji})
}
func (c *Client) EditMessage(ctx context.Context, messageID int64, body string) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/messages/%d/edit", messageID), map[string]any{"body": body})
}
func (c *Client) PinMessage(ctx context.Context, messageID int64, pinned bool) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/messages/%d/pin", messageID), map[string]any{"pinned": pinned})
}
func (c *Client) Pins(ctx context.Context, channelID int64) (*Response, error) {
	return c.get(ctx, fmt.Sprintf("/api/bot/v1/channels/%d/pins", channelID))
}
func (c *Client) MessageContext(ctx context.Context, messageID int64) (*Response, error) {
	return c.get(ctx, fmt.Sprintf("/api/bot/v1/messages/%d/context", messageID))
}
func (c *Client) CreateChannel(ctx context.Context, name, kind string, categoryID int64) (*Response, error) {
	payload := map[string]any{"name": name, "kind": kind}
	if categoryID > 0 {
		payload["category_id"] = categoryID
	}
	return c.post(ctx, "/api/bot/v1/channels", payload)
}
func (c *Client) UpdateChannel(ctx context.Context, channelID int64, patch map[string]any) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/channels/%d/settings", channelID), patch)
}
func (c *Client) Roles(ctx context.Context) (*Response, error) {
	return c.get(ctx, "/api/bot/v1/roles")
}
func (c *Client) CreateRole(ctx context.Context, name string, patch map[string]any) (*Response, error) {
	body := map[string]any{"name": name}
	for k, v := range patch {
		body[k] = v
	}
	return c.post(ctx, "/api/bot/v1/roles", body)
}
func (c *Client) UpdateRole(ctx context.Context, roleID int64, patch map[string]any) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/roles/%d", roleID), patch)
}
func (c *Client) DeleteRole(ctx context.Context, roleID int64) (*Response, error) {
	return c.Request(ctx, http.MethodDelete, fmt.Sprintf("/api/bot/v1/roles/%d", roleID), nil)
}
func (c *Client) Members(ctx context.Context, after int64, limit int) (*Response, error) {
	if limit < 1 {
		limit = 1
	}
	if limit > 200 {
		limit = 200
	}
	q := url.Values{"limit": []string{strconv.Itoa(limit)}}
	if after > 0 {
		q.Set("after", strconv.FormatInt(after, 10))
	}
	return c.get(ctx, "/api/bot/v1/members?"+q.Encode())
}
func (c *Client) Member(ctx context.Context, userID int64) (*Response, error) {
	return c.get(ctx, fmt.Sprintf("/api/bot/v1/members/%d", userID))
}
func (c *Client) SetMemberRoles(ctx context.Context, userID int64, roleIDs []int64) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/members/%d/roles", userID), map[string]any{"role_ids": roleIDs})
}
func (c *Client) KickMember(ctx context.Context, userID int64) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/members/%d/kick", userID), map[string]any{})
}
func (c *Client) BanMember(ctx context.Context, userID int64, reason string) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/members/%d/ban", userID), map[string]any{"reason": reason})
}
func (c *Client) UnbanMember(ctx context.Context, userID int64) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/members/%d/unban", userID), map[string]any{})
}
func (c *Client) Bans(ctx context.Context) (*Response, error) { return c.get(ctx, "/api/bot/v1/bans") }
func (c *Client) Wires(ctx context.Context) (*Response, error) {
	return c.get(ctx, "/api/bot/v1/wires")
}
func (c *Client) CreateWire(ctx context.Context, channelID int64, maxUses, expiresIn int) (*Response, error) {
	return c.post(ctx, "/api/bot/v1/wires", map[string]any{"channel_id": channelID, "max_uses": maxUses, "expires_in": expiresIn})
}
func (c *Client) RegisterCommand(ctx context.Context, name, description string, options []CommandOption) (*Response, error) {
	return c.post(ctx, "/api/bot/v1/commands", map[string]any{"name": name, "description": description, "options": options})
}
func (c *Client) SyncCommands(ctx context.Context, commands []CommandDefinition) (*Response, error) {
	return c.Request(ctx, http.MethodPut, "/api/bot/v1/commands", map[string]any{"commands": commands})
}
func (c *Client) Commands(ctx context.Context) (*Response, error) {
	return c.get(ctx, "/api/bot/v1/commands")
}
func (c *Client) DeleteCommand(ctx context.Context, commandID int64) (*Response, error) {
	return c.Request(ctx, http.MethodDelete, fmt.Sprintf("/api/bot/v1/commands/%d", commandID), nil)
}
func (c *Client) ClaimCommands(ctx context.Context, limit int) ([]CommandClaim, error) {
	if limit < 1 {
		limit = 1
	}
	if limit > 50 {
		limit = 50
	}
	res, err := c.get(ctx, "/api/bot/v1/commands/claims?limit="+strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	var envelope struct {
		OK   bool           `json:"ok"`
		Data []CommandClaim `json:"data"`
	}
	if err := json.Unmarshal(res.Body, &envelope); err != nil {
		return nil, err
	}
	if !envelope.OK {
		return nil, errors.New("Plainwire returned an invalid command envelope")
	}
	return envelope.Data, nil
}
func (c *Client) DeferCommand(ctx context.Context, claim CommandClaim, lease time.Duration) (*Response, error) {
	leaseMS := lease.Milliseconds()
	if leaseMS < 5000 {
		leaseMS = 5000
	}
	if leaseMS > 120000 {
		leaseMS = 120000
	}
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/commands/claims/%d/defer", claim.ID), map[string]any{"claim_token": claim.ClaimToken, "lease_ms": leaseMS})
}
func (c *Client) RespondCommand(ctx context.Context, claim CommandClaim, body string) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/commands/claims/%d/respond", claim.ID), map[string]any{"claim_token": claim.ClaimToken, "body": body})
}
func (c *Client) FailCommand(ctx context.Context, claim CommandClaim, reason string) (*Response, error) {
	return c.post(ctx, fmt.Sprintf("/api/bot/v1/commands/claims/%d/fail", claim.ID), map[string]any{"claim_token": claim.ClaimToken, "reason": reason})
}

type CommandHandler func(context.Context, CommandClaim, *Client) (string, error)

type WorkerOptions struct {
	BatchSize   int
	Concurrency int
	IdleDelay   time.Duration
	Lease       time.Duration
	OnError     func(error, *CommandClaim)
}

// RunCommandWorker claims durable invocations until ctx is cancelled. A
// non-empty handler result is posted as the command reply; an empty result lets
// the handler complete the claim itself using the client.
func (c *Client) RunCommandWorker(ctx context.Context, handlers map[string]CommandHandler, options WorkerOptions) error {
	batch := options.BatchSize
	if batch < 1 {
		batch = 20
	}
	if batch > 50 {
		batch = 50
	}
	concurrency := options.Concurrency
	if concurrency < 1 {
		concurrency = 4
	}
	if concurrency > 32 {
		concurrency = 32
	}
	idle := options.IdleDelay
	if idle <= 0 {
		idle = 500 * time.Millisecond
	}
	lease := options.Lease
	if lease <= 0 {
		lease = 120 * time.Second
	}
	report := options.OnError
	if report == nil {
		report = func(error, *CommandClaim) {}
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		claims, err := c.ClaimCommands(ctx, batch)
		if err != nil {
			report(err, nil)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(idle):
				continue
			}
		}
		if len(claims) == 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(idle):
				continue
			}
		}
		jobs := make(chan CommandClaim)
		var workers sync.WaitGroup
		workerCount := concurrency
		if workerCount > len(claims) {
			workerCount = len(claims)
		}
		workers.Add(workerCount)
		for i := 0; i < workerCount; i++ {
			go func() {
				defer workers.Done()
				for claim := range jobs {
					handler := handlers[claim.Command]
					if handler == nil {
						_, err := c.FailCommand(ctx, claim, "No handler registered for /"+claim.Command)
						if err != nil {
							report(err, &claim)
						}
						continue
					}
					if _, err := c.DeferCommand(ctx, claim, lease); err != nil {
						report(err, &claim)
						continue
					}
					body, err := handler(ctx, claim, c)
					if err != nil {
						report(err, &claim)
						reason := err.Error()
						if len(reason) > 240 {
							reason = reason[:240]
						}
						if _, failErr := c.FailCommand(ctx, claim, reason); failErr != nil {
							report(failErr, &claim)
						}
					} else if strings.TrimSpace(body) != "" {
						if _, err := c.RespondCommand(ctx, claim, body); err != nil {
							report(err, &claim)
						}
					}
				}
			}()
		}
		for _, claim := range claims {
			jobs <- claim
		}
		close(jobs)
		workers.Wait()
	}
}
