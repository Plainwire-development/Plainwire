package plainwirebot

import "testing"

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
