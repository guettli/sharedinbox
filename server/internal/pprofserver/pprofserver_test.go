package pprofserver

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestMuxServesDebugEndpoints verifies the dedicated pprof mux answers the
// /debug/pprof/ routes we register, and that an unrelated route on it 404s —
// i.e. pprof lives on its own mux, never a service's public one.
func TestMuxServesDebugEndpoints(t *testing.T) {
	mux := Mux()
	for _, path := range []string{"/debug/pprof/", "/debug/pprof/heap", "/debug/pprof/cmdline"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s on pprof mux: got %d, want 200", path, rec.Code)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Errorf("GET /healthz on pprof mux: got %d, want 404", rec.Code)
	}
}
