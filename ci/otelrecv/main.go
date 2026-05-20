// otelrecv is a minimal OTLP HTTP/JSON trace receiver for Dagger CI timing.
//
// Usage:
//
//	go run ./ci/otelrecv/ --port-file=/tmp/otel.port [--raw=/tmp/otel.json]
//
// It listens on a random port (written to --port-file for the caller to read),
// collects spans sent by the Dagger CLI via OTLP HTTP/JSON, and prints a
// timing report on SIGTERM/SIGINT.
//
// Caller sets:
//
//	OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:<port>
//	OTEL_EXPORTER_OTLP_PROTOCOL=http/json
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// OTLP HTTP/JSON payload — proto3 JSON mapping, minimal subset.
type exportRequest struct {
	ResourceSpans []resourceSpan `json:"resourceSpans"`
}

type resourceSpan struct {
	ScopeSpans []scopeSpan `json:"scopeSpans"`
}

type scopeSpan struct {
	Spans []otlpSpan `json:"spans"`
}

type otlpSpan struct {
	Name              string `json:"name"`
	StartTimeUnixNano string `json:"startTimeUnixNano"` // decimal string (proto3 uint64 → JSON string)
	EndTimeUnixNano   string `json:"endTimeUnixNano"`
	ParentSpanID      string `json:"parentSpanId"`
	Attributes        []kv   `json:"attributes"`
}

type kv struct {
	Key   string  `json:"key"`
	Value kvValue `json:"value"`
}

type kvValue struct {
	StringValue *string  `json:"stringValue,omitempty"`
	BoolValue   *bool    `json:"boolValue,omitempty"`
	IntValue    *string  `json:"intValue,omitempty"`
	DoubleValue *float64 `json:"doubleValue,omitempty"`
}

func (v kvValue) str() string {
	switch {
	case v.StringValue != nil:
		return *v.StringValue
	case v.BoolValue != nil:
		return strconv.FormatBool(*v.BoolValue)
	case v.IntValue != nil:
		return *v.IntValue
	case v.DoubleValue != nil:
		return strconv.FormatFloat(*v.DoubleValue, 'f', -1, 64)
	}
	return ""
}

var (
	mu    sync.Mutex
	spans []otlpSpan
)

func main() {
	portFile := flag.String("port-file", "", "write listening port to this file (required)")
	rawFile  := flag.String("raw", "", "write all received JSON bodies to this file for inspection")
	flag.Parse()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "otelrecv: listen: %v\n", err)
		os.Exit(1)
	}

	if *portFile != "" {
		port := ln.Addr().(*net.TCPAddr).Port
		if err := os.WriteFile(*portFile, []byte(strconv.Itoa(port)), 0o600); err != nil {
			fmt.Fprintf(os.Stderr, "otelrecv: port-file: %v\n", err)
			os.Exit(1)
		}
	}

	var rawOut *os.File
	if *rawFile != "" {
		f, err := os.Create(*rawFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "otelrecv: raw: %v\n", err)
			os.Exit(1)
		}
		defer f.Close()
		rawOut = f
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/traces", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if rawOut != nil {
			rawOut.Write(body)
			rawOut.WriteString("\n")
		}
		var req exportRequest
		if err := json.Unmarshal(body, &req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		mu.Lock()
		for _, rs := range req.ResourceSpans {
			for _, ss := range rs.ScopeSpans {
				spans = append(spans, ss.Spans...)
			}
		}
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})

	srv := &http.Server{Handler: mux}
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-ch; srv.Close() }()

	srv.Serve(ln) //nolint:errcheck // returns non-nil only on Close
	printReport()
}

func printReport() {
	mu.Lock()
	defer mu.Unlock()

	if len(spans) == 0 {
		fmt.Fprintln(os.Stderr, "otelrecv: no spans received — check OTEL_EXPORTER_OTLP_PROTOCOL=http/json is supported")
		return
	}

	type row struct {
		name   string
		dur    float64
		cached bool
		attrs  string
	}

	rows := make([]row, 0, len(spans))
	for _, s := range spans {
		start, _ := strconv.ParseInt(s.StartTimeUnixNano, 10, 64)
		end, _   := strconv.ParseInt(s.EndTimeUnixNano,   10, 64)
		dur := float64(end-start) / 1e9

		cached := false
		var parts []string
		for _, a := range s.Attributes {
			val := a.Value.str()
			if a.Value.BoolValue != nil && strings.Contains(strings.ToLower(a.Key), "cached") {
				cached = *a.Value.BoolValue
			}
			parts = append(parts, a.Key+"="+val)
		}

		rows = append(rows, row{
			name:   s.Name,
			dur:    dur,
			cached: cached,
			attrs:  strings.Join(parts, "  "),
		})
	}

	sort.Slice(rows, func(i, j int) bool { return rows[i].dur > rows[j].dur })

	const nameW, attrW = 38, 60
	fmt.Printf("\n%-6s  %8s  %-*s  %s\n", "STATUS", "DURATION", nameW, "SPAN", "ATTRIBUTES")
	fmt.Println(strings.Repeat("─", 6+2+8+2+nameW+2+attrW))
	for _, r := range rows {
		status := "LIVE"
		if r.cached {
			status = "CACHED"
		}
		attrs := r.attrs
		if len(attrs) > attrW {
			attrs = attrs[:attrW-1] + "…"
		}
		fmt.Printf("%-6s  %7.2fs  %-*s  %s\n", status, r.dur, nameW, clip(r.name, nameW), attrs)
	}
	fmt.Printf("\n%d spans total\n", len(rows))
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
