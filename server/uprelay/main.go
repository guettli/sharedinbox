// Command uprelay is a minimal HTTP relay that forwards events to
// UnifiedPush endpoints registered by SharedInbox clients.
//
// Architecture
//
//	  Mail server (IMAP IDLE / sieve hook)
//	          │
//	          ▼
//	  ┌────────────────┐    POST /trigger     ┌──────────────────────┐
//	  │   This relay   │ ───────────────────► │  Distributor on the  │
//	  │  (stateless)   │                      │   device (ntfy, …)   │
//	  └────────────────┘ ◄─────────────────── │                      │
//	          ▲          POST /register       └──────────────────────┘
//	          │
//	   SharedInbox app
//
// Endpoints:
//
//	POST /register   — body: {"account_id":"…","endpoint":"…"}.
//	                   Persists the mapping; idempotent on account_id.
//	POST /unregister — body: {"account_id":"…"}. Removes the mapping.
//	POST /trigger    — body: {"account_id":"…"}. POSTs an empty wake-up
//	                   to the corresponding endpoint URL. Call this from
//	                   your mail server's sieve/hook script when a new
//	                   message arrives.
//	GET  /healthz    — returns 200 OK.
//
// State is held in memory and persisted to a JSON file passed via -state.
// Out of scope for this minimal scaffold: IMAP IDLE itself. Plug your
// mail server's "new message" trigger into POST /trigger — Stalwart and
// Dovecot both support arbitrary HTTP webhooks via sieve "vnd.dovecot.execute".
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// Registration ties one SharedInbox account to its UnifiedPush endpoint.
type Registration struct {
	AccountID string `json:"account_id"`
	Endpoint  string `json:"endpoint"`
}

type store struct {
	mu        sync.Mutex
	path      string
	entries   map[string]Registration // keyed by account_id
	httpClnt  *http.Client
}

func newStore(path string) (*store, error) {
	s := &store{
		path:     path,
		entries:  map[string]Registration{},
		httpClnt: &http.Client{Timeout: 10 * time.Second},
	}
	if err := s.load(); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return s, nil
}

func (s *store) load() error {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return err
	}
	var loaded map[string]Registration
	if err := json.Unmarshal(data, &loaded); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.entries = loaded
	return nil
}

func (s *store) save() error {
	s.mu.Lock()
	data, err := json.MarshalIndent(s.entries, "", "  ")
	s.mu.Unlock()
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func (s *store) put(r Registration) {
	s.mu.Lock()
	s.entries[r.AccountID] = r
	s.mu.Unlock()
}

func (s *store) get(accountID string) (Registration, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.entries[accountID]
	return r, ok
}

func (s *store) delete(accountID string) {
	s.mu.Lock()
	delete(s.entries, accountID)
	s.mu.Unlock()
}

// trigger sends an empty wake-up to the endpoint registered for accountID.
// UnifiedPush accepts arbitrary payloads up to 4 KiB; we send a single byte
// because the client treats every wake-up identically.
func (s *store) trigger(ctx context.Context, accountID string) error {
	r, ok := s.get(accountID)
	if !ok {
		return errNotRegistered
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.Endpoint, nil)
	if err != nil {
		return err
	}
	resp, err := s.httpClnt.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode/100 != 2 {
		return errEndpointFailed
	}
	return nil
}

var (
	errNotRegistered  = errors.New("account not registered")
	errEndpointFailed = errors.New("endpoint returned non-2xx")
)

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func handleRegister(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var reg Registration
		if err := json.NewDecoder(r.Body).Decode(&reg); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if reg.AccountID == "" || reg.Endpoint == "" {
			http.Error(w, "account_id and endpoint required", http.StatusBadRequest)
			return
		}
		s.put(reg)
		if err := s.save(); err != nil {
			log.Printf("save failed: %v", err)
			http.Error(w, "persistence failed", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func handleUnregister(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			AccountID string `json:"account_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if body.AccountID == "" {
			http.Error(w, "account_id required", http.StatusBadRequest)
			return
		}
		s.delete(body.AccountID)
		if err := s.save(); err != nil {
			log.Printf("save failed: %v", err)
			http.Error(w, "persistence failed", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func handleTrigger(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var body struct {
			AccountID string `json:"account_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if body.AccountID == "" {
			http.Error(w, "account_id required", http.StatusBadRequest)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		if err := s.trigger(ctx, body.AccountID); err != nil {
			if errors.Is(err, errNotRegistered) {
				http.Error(w, "account not registered", http.StatusNotFound)
				return
			}
			log.Printf("trigger failed for %s: %v", body.AccountID, err)
			http.Error(w, "trigger failed", http.StatusBadGateway)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok")
}

func main() {
	addr := flag.String("addr", ":8089", "listen address")
	statePath := flag.String("state", "uprelay-state.json", "path to persistent state file")
	flag.Parse()

	s, err := newStore(*statePath)
	if err != nil {
		log.Fatalf("load state: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/register", handleRegister(s))
	mux.HandleFunc("/unregister", handleUnregister(s))
	mux.HandleFunc("/trigger", handleTrigger(s))

	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
		close(idle)
	}()

	log.Printf("uprelay listening on %s; state=%s", *addr, *statePath)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("listen: %v", err)
	}
	<-idle
}
