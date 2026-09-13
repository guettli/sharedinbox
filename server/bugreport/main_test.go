package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// resetRateLimit clears the global sliding-window state so tests don't leak
// request timestamps into one another.
func resetRateLimit() {
	rateLimitMu.Lock()
	requestTimes = nil
	rateLimitMu.Unlock()
}

// fakeIssuer records the last CreateIssue call and returns a canned URL.
type fakeIssuer struct {
	title, body string
	err         error
}

func (f *fakeIssuer) CreateIssue(_ context.Context, title, body string) (string, int, error) {
	f.title, f.body = title, body
	if f.err != nil {
		return "", 0, f.err
	}
	return "https://github.com/guettli/sharedinbox/issues/42", 42, nil
}

// encryptedReportBody builds a multipart body with the given form fields and an
// encrypted_mail file (when mail is non-empty).
func encryptedReportBody(t *testing.T, fields map[string]string, mail []byte) (*bytes.Buffer, string) {
	t.Helper()
	buf := &bytes.Buffer{}
	mw := multipart.NewWriter(buf)
	for k, v := range fields {
		if err := mw.WriteField(k, v); err != nil {
			t.Fatalf("WriteField: %v", err)
		}
	}
	if mail != nil {
		fw, err := mw.CreateFormFile("encrypted_mail", "mail.enc")
		if err != nil {
			t.Fatalf("CreateFormFile: %v", err)
		}
		if _, err := fw.Write(mail); err != nil {
			t.Fatalf("write mail: %v", err)
		}
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	return buf, mw.FormDataContentType()
}

func TestReportKeyHandler(t *testing.T) {
	raw := make([]byte, 48)
	for i := range raw {
		raw[i] = byte(i)
	}
	h := reportKeyHandler(base64.StdEncoding.EncodeToString(raw))

	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, "/api/v1/report-key", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var got map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got["keyId"] != base64.StdEncoding.EncodeToString(raw[:16]) {
		t.Errorf("keyId = %q", got["keyId"])
	}
	if got["publicKey"] != base64.StdEncoding.EncodeToString(raw[16:]) {
		t.Errorf("publicKey = %q", got["publicKey"])
	}
	if got["alg"] != "x25519-ecies-aesgcm" {
		t.Errorf("alg = %q", got["alg"])
	}
}

func TestReportKeyHandlerUnconfigured(t *testing.T) {
	rec := httptest.NewRecorder()
	reportKeyHandler("")(rec, httptest.NewRequest(http.MethodGet, "/api/v1/report-key", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}

func TestEncryptedReportHandlerCreatesIssue(t *testing.T) {
	resetRateLimit()
	dir := t.TempDir()
	issuer := &fakeIssuer{}
	h := encryptedReportHandler(dir, "https://sharedinbox.de", issuer)

	body, ct := encryptedReportBody(t,
		map[string]string{"description": "it broke", "about_info": "v1.2.3"},
		[]byte("ciphertext-bytes"),
	)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/encrypted-reports", body)
	req.Header.Set("Content-Type", ct)
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp["issueUrl"] != "https://github.com/guettli/sharedinbox/issues/42" {
		t.Errorf("issueUrl = %v", resp["issueUrl"])
	}
	if !strings.Contains(issuer.body, "it broke") {
		t.Errorf("issue body missing description: %q", issuer.body)
	}
	if !strings.Contains(issuer.body, "/mail.enc") {
		t.Errorf("issue body missing download link: %q", issuer.body)
	}
	if strings.Contains(issuer.body, "ciphertext-bytes") {
		t.Errorf("issue body must not inline the ciphertext")
	}

	// The download endpoint serves the stored blob back.
	id := resp["id"].(string)
	dl := encryptedMailHandler(dir)
	dlReq := httptest.NewRequest(http.MethodGet, "/api/v1/encrypted-reports/"+id+"/mail.enc", nil)
	dlReq.SetPathValue("id", id)
	dlRec := httptest.NewRecorder()
	dl(dlRec, dlReq)
	if dlRec.Code != http.StatusOK {
		t.Fatalf("download status = %d, want 200", dlRec.Code)
	}
	if got, _ := io.ReadAll(dlRec.Body); string(got) != "ciphertext-bytes" {
		t.Errorf("downloaded blob = %q", string(got))
	}
}

func TestEncryptedReportHandlerValidation(t *testing.T) {
	dir := t.TempDir()
	h := encryptedReportHandler(dir, "https://sharedinbox.de", &fakeIssuer{})

	cases := []struct {
		name   string
		fields map[string]string
		mail   []byte
		want   int
	}{
		{"missing description", map[string]string{"about_info": "x"}, []byte("c"), http.StatusBadRequest},
		{"missing mail", map[string]string{"description": "d"}, nil, http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resetRateLimit()
			body, ct := encryptedReportBody(t, tc.fields, tc.mail)
			req := httptest.NewRequest(http.MethodPost, "/api/v1/encrypted-reports", body)
			req.Header.Set("Content-Type", ct)
			rec := httptest.NewRecorder()
			h(rec, req)
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}

func TestEncryptedReportHandlerUnconfigured(t *testing.T) {
	resetRateLimit()
	h := encryptedReportHandler(t.TempDir(), "https://sharedinbox.de", nil)
	body, ct := encryptedReportBody(t, map[string]string{"description": "d"}, []byte("c"))
	req := httptest.NewRequest(http.MethodPost, "/api/v1/encrypted-reports", body)
	req.Header.Set("Content-Type", ct)
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}

func TestEncryptedMailHandlerRejectsBadID(t *testing.T) {
	h := encryptedMailHandler(t.TempDir())
	req := httptest.NewRequest(http.MethodGet, "/api/v1/encrypted-reports/..%2f..%2fetc/mail.enc", nil)
	req.SetPathValue("id", "../../etc")
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestGithubIssueCreator(t *testing.T) {
	var gotAuth, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"html_url":"https://github.com/o/r/issues/7","number":7}`))
	}))
	defer srv.Close()

	g := &githubIssueCreator{token: "tok", repo: "o/r", apiBase: srv.URL, client: srv.Client()}
	url, num, err := g.CreateIssue(context.Background(), "title", "body")
	if err != nil {
		t.Fatalf("CreateIssue: %v", err)
	}
	if url != "https://github.com/o/r/issues/7" || num != 7 {
		t.Errorf("url=%q num=%d", url, num)
	}
	if gotAuth != "Bearer tok" {
		t.Errorf("auth = %q", gotAuth)
	}
	if !strings.Contains(gotBody, `"encrypted-report"`) {
		t.Errorf("body missing label: %q", gotBody)
	}
}
