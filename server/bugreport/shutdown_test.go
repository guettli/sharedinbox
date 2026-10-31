package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

// TestServeFinishesInFlightRequestOnShutdown: a request that is still running
// when the shutdown signal arrives must complete, and serve must return nil.
func TestServeFinishesInFlightRequestOnShutdown(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		_, _ = io.WriteString(w, "done")
	})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() { served <- serve(ctx, &http.Server{Handler: mux}, ln, 5*time.Second) }()

	type result struct {
		body string
		err  error
	}
	got := make(chan result, 1)
	go func() {
		resp, err := http.Get("http://" + ln.Addr().String() + "/slow")
		if err != nil {
			got <- result{err: err}
			return
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		got <- result{string(b), err}
	}()

	<-started
	cancel() // SIGTERM arrives while /slow is in flight

	// New connections are refused once shutdown has begun.
	deadline := time.Now().Add(2 * time.Second)
	for {
		c, err := net.DialTimeout("tcp", ln.Addr().String(), 100*time.Millisecond)
		if err != nil {
			break
		}
		c.Close()
		if time.Now().After(deadline) {
			t.Fatal("listener still accepting connections after shutdown began")
		}
		time.Sleep(10 * time.Millisecond)
	}

	select {
	case err := <-served:
		t.Fatalf("serve returned (%v) before the in-flight request finished", err)
	default:
	}

	close(release)
	r := <-got
	if r.err != nil || r.body != "done" {
		t.Fatalf("in-flight request: body=%q err=%v, want body=done", r.body, r.err)
	}
	if err := <-served; err != nil {
		t.Fatalf("serve: %v", err)
	}
}

// TestServeReturnsErrorWhenShutdownTimesOut: a request that outlives the
// timeout makes serve report it instead of hanging.
func TestServeReturnsErrorWhenShutdownTimesOut(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	defer close(release)
	mux := http.NewServeMux()
	mux.HandleFunc("/stuck", func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
	})

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() { served <- serve(ctx, &http.Server{Handler: mux}, ln, 100*time.Millisecond) }()
	go func() {
		resp, err := http.Get("http://" + ln.Addr().String() + "/stuck")
		if err == nil {
			resp.Body.Close()
		}
	}()

	<-started
	cancel()
	select {
	case err := <-served:
		if err == nil {
			t.Fatal("serve returned nil, want a shutdown timeout error")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve did not return after the shutdown timeout")
	}
}
