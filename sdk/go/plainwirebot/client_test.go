package plainwirebot

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestURLPolicy(t *testing.T) {
	if _, err := New("http://example.com", "pwb_1234567890123456"); err == nil {
		t.Fatal("remote HTTP must be rejected")
	}
	if _, err := New("http://127.0.0.1:8080", "pwb_1234567890123456"); err != nil {
		t.Fatalf("loopback HTTP should work: %v", err)
	}
	if _, err := New("https://chat.example.com", "pwb_1234567890123456"); err != nil {
		t.Fatalf("HTTPS should work: %v", err)
	}
}

func TestV22Routes(t *testing.T) {
	type request struct{ method, path, query string }
	var requests []request
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, request{r.Method, r.URL.Path, r.URL.RawQuery})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"data":{}}`))
	}))
	defer server.Close()
	client, err := New(server.URL, "pwb_1234567890123456")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err = client.Members(ctx, 41, 500); err != nil {
		t.Fatal(err)
	}
	if _, err = client.SyncCommands(ctx, []CommandDefinition{{Name: "ping"}}); err != nil {
		t.Fatal(err)
	}
	claim := CommandClaim{ID: 9, ClaimToken: "pwc_claim"}
	if _, err = client.DeferCommand(ctx, claim, 5*time.Minute); err != nil {
		t.Fatal(err)
	}
	if requests[0].method != http.MethodGet || requests[0].path != "/api/bot/v1/members" || requests[0].query != "after=41&limit=200" {
		t.Fatalf("unexpected members request: %+v", requests[0])
	}
	if requests[1].method != http.MethodPut || requests[1].path != "/api/bot/v1/commands" {
		t.Fatalf("unexpected sync request: %+v", requests[1])
	}
	if requests[2].method != http.MethodPost || requests[2].path != "/api/bot/v1/commands/claims/9/defer" {
		t.Fatalf("unexpected defer request: %+v", requests[2])
	}
}

func TestCommandClaimOption(t *testing.T) {
	claim := CommandClaim{Args: map[string]any{"raw": "hello", "text": "hello"}, Options: map[string]any{"text": "hello"}}
	value, ok := claim.Option("text")
	if !ok || value != "hello" {
		t.Fatalf("expected named option, got %v %v", value, ok)
	}
}

func TestWorkerProtectsErrorsAndCapsClaims(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var claimLimit string
	var failure string
	var renewals atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/bot/v1/commands/claims":
			if claimLimit != "" {
				_, _ = w.Write([]byte(`{"ok":true,"data":[]}`))
				return
			}
			claimLimit = r.URL.Query().Get("limit")
			_, _ = w.Write([]byte(`{"ok":true,"data":[{"id":7,"command":"ping","claim_token":"pwc_x"}]}`))
		case "/api/bot/v1/commands/claims/7/defer":
			renewals.Add(1)
			_, _ = w.Write([]byte(`{"ok":true,"data":{}}`))
		case "/api/bot/v1/commands/claims/7/fail":
			var body struct {
				Reason string `json:"reason"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			failure = body.Reason
			_, _ = w.Write([]byte(`{"ok":true,"data":{}}`))
		time.AfterFunc(50*time.Millisecond, cancel)
		}
	}))
	defer server.Close()
	client, err := New(server.URL, "pwb_1234567890123456")
	if err != nil {
		t.Fatal(err)
	}
	var reported error
	err = client.RunCommandWorker(ctx, map[string]CommandHandler{
		"ping": func(context.Context, CommandClaim, *Client) (string, error) {
			time.Sleep(2700 * time.Millisecond)
			return "", errors.New("secret-provider-key")
		},
	}, WorkerOptions{BatchSize: 20, Concurrency: 2, Lease: 5 * time.Second, OnError: func(err error, _ *CommandClaim) { reported = err }})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cancellation: %v", err)
	}
	if claimLimit != "2" || failure != "Command failed" {
		t.Fatalf("limit=%q failure=%q", claimLimit, failure)
	}
	if renewals.Load() < 2 {
		t.Fatal("active lease was not renewed during handler")
	}
	if reported == nil || reported.Error() != "secret-provider-key" {
		t.Fatalf("local error missing: %v", reported)
	}
}
