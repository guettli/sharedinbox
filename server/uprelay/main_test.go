package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

// newTestStore returns a store backed by a temp file so persistence is
// exercised end-to-end without polluting the working directory.
func newTestStore(t *testing.T) *store {
	t.Helper()
	dir := t.TempDir()
	s, err := newStore(filepath.Join(dir, "state.json"))
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	return s
}

func postJSON(t *testing.T, h http.HandlerFunc, body any) *httptest.ResponseRecorder {
	t.Helper()
	buf, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(buf))
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

func TestRegisterAndTrigger(t *testing.T) {
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	s := newTestStore(t)

	// /register
	resp := postJSON(t, handleRegister(s), Registration{
		AccountID: "acc-1",
		Endpoint:  upstream.URL,
	})
	if resp.Code != http.StatusOK {
		t.Fatalf("register status = %d, want 200", resp.Code)
	}

	// /trigger fires the upstream POST
	resp = postJSON(t, handleTrigger(s), map[string]string{"account_id": "acc-1"})
	if resp.Code != http.StatusOK {
		t.Fatalf("trigger status = %d body=%s", resp.Code, resp.Body.String())
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("upstream hits = %d, want 1", got)
	}
}

func TestTriggerUnknownAccount(t *testing.T) {
	s := newTestStore(t)
	resp := postJSON(t, handleTrigger(s), map[string]string{"account_id": "missing"})
	if resp.Code != http.StatusNotFound {
		t.Fatalf("trigger status = %d, want 404", resp.Code)
	}
}

func TestRegisterValidatesPayload(t *testing.T) {
	s := newTestStore(t)
	resp := postJSON(t, handleRegister(s), map[string]string{"account_id": ""})
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("register status = %d, want 400", resp.Code)
	}
}

func TestUnregisterRemovesAccount(t *testing.T) {
	s := newTestStore(t)
	s.put(Registration{AccountID: "acc-1", Endpoint: "http://example/"})
	resp := postJSON(t, handleUnregister(s), map[string]string{"account_id": "acc-1"})
	if resp.Code != http.StatusOK {
		t.Fatalf("unregister status = %d", resp.Code)
	}
	if _, ok := s.get("acc-1"); ok {
		t.Fatalf("expected acc-1 to be removed")
	}
}

func TestPersistenceRoundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	s1, err := newStore(path)
	if err != nil {
		t.Fatalf("newStore #1: %v", err)
	}
	s1.put(Registration{AccountID: "acc-1", Endpoint: "http://e/"})
	if err := s1.save(); err != nil {
		t.Fatalf("save: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Contains(data, []byte("acc-1")) {
		t.Fatalf("state file is missing acc-1: %s", data)
	}

	s2, err := newStore(path)
	if err != nil {
		t.Fatalf("newStore #2: %v", err)
	}
	if _, ok := s2.get("acc-1"); !ok {
		t.Fatalf("acc-1 not loaded back from %s", path)
	}
}

func TestHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handleHealth(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz status = %d", rec.Code)
	}
	body, _ := io.ReadAll(rec.Body)
	if string(body) != "ok" {
		t.Fatalf("healthz body = %q", body)
	}
}

func TestTriggerEndpointFailure(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer upstream.Close()

	s := newTestStore(t)
	s.put(Registration{AccountID: "acc-1", Endpoint: upstream.URL})

	if err := s.trigger(context.Background(), "acc-1"); err == nil {
		t.Fatalf("expected trigger error on 500 upstream")
	}
}
