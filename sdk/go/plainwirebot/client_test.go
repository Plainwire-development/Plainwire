package plainwirebot

import (
	"context"
	"net/http"
	"net/http/httptest"
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
