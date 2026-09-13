// Package pprofserver serves net/http/pprof on its own non-public listener.
//
// Parca's eBPF agent profiles CPU node-wide but cannot see a Go process's heap,
// goroutines, mutex or block contention — those come only from net/http/pprof.
// The Go services (uprelay, bugreport) each expose one through this package so
// the debug endpoint, and the security reasoning around it, lives in one place.
package pprofserver

import (
	"errors"
	"log"
	"net/http"
	"net/http/pprof"
	"time"
)

// Start serves net/http/pprof on its own listener at addr and blocks until the
// process exits. These handlers expose the command line, goroutine stacks and
// live heap, and profile/trace pin a CPU for their whole duration, so addr MUST
// be a non-public bind (localhost or the WireGuard address) — never a public
// listener. Bind failures are logged, not fatal, so a missing WireGuard
// interface on a dev box never takes the service down.
func Start(addr string) {
	// No WriteTimeout: a 30s CPU profile or trace legitimately holds the
	// connection open longer than any request timeout we'd want elsewhere.
	srv := &http.Server{
		Addr:              addr,
		Handler:           Mux(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("pprof listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("pprof server on %s stopped: %v", addr, err)
	}
}

// Mux builds the mux that Start serves. Exported so tests can exercise the
// routing without binding a socket.
func Mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	return mux
}
