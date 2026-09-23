package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
func encryptedReportBody(t *testing.T, fields map[string]string, mail []byte, attachments ...[]byte) (*bytes.Buffer, string) {
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
	for i, a := range attachments {
		fw, err := mw.CreateFormFile("encrypted_attachments[]", fmt.Sprintf("shot-%d.enc", i+1))
		if err != nil {
			t.Fatalf("CreateFormFile attachment: %v", err)
		}
		if _, err := fw.Write(a); err != nil {
			t.Fatalf("write attachment: %v", err)
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
		map[string]string{"title": "login fails", "description": "it broke", "about_info": "v1.2.3"},
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
	if issuer.title != "Bug report: login fails" {
		t.Errorf("issue title = %q, want %q", issuer.title, "Bug report: login fails")
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
		// title, description and about_info are all required; the mail is optional.
		{"all present", map[string]string{"title": "t", "description": "d", "about_info": "x"}, []byte("c"), http.StatusCreated},
		{"no mail is allowed", map[string]string{"title": "t", "description": "d", "about_info": "x"}, nil, http.StatusCreated},
		{"missing title", map[string]string{"description": "d", "about_info": "x"}, []byte("c"), http.StatusBadRequest},
		{"blank title", map[string]string{"title": "   ", "description": "d", "about_info": "x"}, []byte("c"), http.StatusBadRequest},
		{"missing description", map[string]string{"title": "t", "about_info": "x"}, []byte("c"), http.StatusBadRequest},
		{"blank description", map[string]string{"title": "t", "description": "  ", "about_info": "x"}, []byte("c"), http.StatusBadRequest},
		{"missing about_info", map[string]string{"title": "t", "description": "d"}, []byte("c"), http.StatusBadRequest},
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

func TestEncryptedReportHandlerStoresScreenshots(t *testing.T) {
	resetRateLimit()
	dir := t.TempDir()
	issuer := &fakeIssuer{}
	h := encryptedReportHandler(dir, "https://sharedinbox.de", issuer)

	body, ct := encryptedReportBody(t,
		map[string]string{"title": "screenshots", "description": "see the screenshots", "about_info": "v1"},
		[]byte("mail-cipher"),
		[]byte("shot-1-cipher"),
		[]byte("shot-2-cipher"),
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
	id := resp["id"].(string)

	// Both screenshots are linked from the issue as encrypted downloads, and
	// the plaintext ciphertext is never inlined.
	for _, want := range []string{"/image_1.enc", "/image_2.enc", "Encrypted screenshot"} {
		if !strings.Contains(issuer.body, want) {
			t.Errorf("issue body missing %q\n---\n%s", want, issuer.body)
		}
	}
	for _, bad := range []string{"shot-1-cipher", "shot-2-cipher"} {
		if strings.Contains(issuer.body, bad) {
			t.Errorf("issue body must not inline screenshot ciphertext %q", bad)
		}
	}

	// The attachment endpoint serves each stored blob back byte-for-byte.
	dl := encryptedAttachmentHandler(dir)
	for name, want := range map[string]string{"image_1.enc": "shot-1-cipher", "image_2.enc": "shot-2-cipher"} {
		r := httptest.NewRequest(http.MethodGet, "/api/v1/encrypted-reports/"+id+"/"+name, nil)
		r.SetPathValue("id", id)
		r.SetPathValue("name", name)
		w := httptest.NewRecorder()
		dl(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("download %s status = %d, want 200", name, w.Code)
		}
		if got, _ := io.ReadAll(w.Body); string(got) != want {
			t.Errorf("download %s = %q, want %q", name, string(got), want)
		}
	}
}

// TestEncryptedReportHandlerGeneralNoMail: a general bug report with no mail
// and no other encrypted parts still opens a public issue (#847 no-mail path),
// and the issue mentions no encrypted attachments.
func TestEncryptedReportHandlerGeneralNoMail(t *testing.T) {
	resetRateLimit()
	dir := t.TempDir()
	issuer := &fakeIssuer{}
	h := encryptedReportHandler(dir, "https://sharedinbox.de", issuer)

	body, ct := encryptedReportBody(t,
		map[string]string{"title": "crash on start", "description": "app crashes on start", "about_info": "v1.2.3"},
		nil,
	)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/encrypted-reports", body)
	req.Header.Set("Content-Type", ct)
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	// The issue title is always "Bug report: <user subject>", even with no mail.
	if issuer.title != "Bug report: crash on start" {
		t.Errorf("issue title = %q, want %q", issuer.title, "Bug report: crash on start")
	}
	if !strings.Contains(issuer.body, "app crashes on start") {
		t.Errorf("issue body missing description: %q", issuer.body)
	}
	for _, bad := range []string{"Encrypted mail", "Encrypted metadata", "Encrypted screenshot", "How to decrypt"} {
		if strings.Contains(issuer.body, bad) {
			t.Errorf("no-attachment report should not mention %q: %q", bad, issuer.body)
		}
	}
}

// TestEncryptedReportHandlerStoresMetadata: the encrypted metadata blob is
// stored, linked in the issue, and downloadable via the {id}/{name} route.
func TestEncryptedReportHandlerStoresMetadata(t *testing.T) {
	resetRateLimit()
	dir := t.TempDir()
	issuer := &fakeIssuer{}
	h := encryptedReportHandler(dir, "https://sharedinbox.de", issuer)

	buf := &bytes.Buffer{}
	mw := multipart.NewWriter(buf)
	for k, v := range map[string]string{"title": "metadata", "description": "d", "about_info": "v1"} {
		if err := mw.WriteField(k, v); err != nil {
			t.Fatalf("WriteField: %v", err)
		}
	}
	fw, err := mw.CreateFormFile("encrypted_metadata", "metadata.enc")
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	if _, err := fw.Write([]byte("meta-cipher")); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/encrypted-reports", buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !strings.Contains(issuer.body, "/metadata.enc") {
		t.Errorf("issue body missing metadata link: %q", issuer.body)
	}

	id := resp["id"].(string)
	dl := encryptedAttachmentHandler(dir)
	r := httptest.NewRequest(http.MethodGet, "/api/v1/encrypted-reports/"+id+"/metadata.enc", nil)
	r.SetPathValue("id", id)
	r.SetPathValue("name", "metadata.enc")
	w := httptest.NewRecorder()
	dl(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("download status = %d, want 200", w.Code)
	}
	if got, _ := io.ReadAll(w.Body); string(got) != "meta-cipher" {
		t.Errorf("downloaded metadata = %q", string(got))
	}
}

func TestEncryptedReportHandlerRejectsTooManyScreenshots(t *testing.T) {
	resetRateLimit()
	dir := t.TempDir()
	h := encryptedReportHandler(dir, "https://sharedinbox.de", &fakeIssuer{})

	shots := make([][]byte, maxEncryptedAttachments+1)
	for i := range shots {
		shots[i] = []byte(fmt.Sprintf("shot-%d", i))
	}
	body, ct := encryptedReportBody(t, map[string]string{"title": "too many", "description": "too many", "about_info": "v1"}, []byte("mail"), shots...)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/encrypted-reports", body)
	req.Header.Set("Content-Type", ct)
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	// Nothing should have been persisted for a rejected report.
	entries, _ := os.ReadDir(filepath.Join(dir, "encrypted"))
	if len(entries) != 0 {
		t.Errorf("rejected report left %d dirs on disk, want 0", len(entries))
	}
}

func TestEncryptedAttachmentHandlerRejectsNonGET(t *testing.T) {
	h := encryptedAttachmentHandler(t.TempDir())
	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.SetPathValue("id", "00000000-0000-4000-8000-000000000000")
	req.SetPathValue("name", "image_1.enc")
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rec.Code)
	}
}

func TestEncryptedAttachmentHandlerRejectsBadNames(t *testing.T) {
	dir := t.TempDir()
	h := encryptedAttachmentHandler(dir)
	id := "00000000-0000-4000-8000-000000000000"
	cases := []struct {
		id, name string
	}{
		{id, "mail.enc"},             // not an image blob
		{id, "image_1.png"},          // wrong extension
		{id, "../../etc/passwd"},     // traversal
		{"../../etc", "image_1.enc"}, // bad id
		{id, "image_9999.enc"},       // over the 3-digit bound
	}
	for _, tc := range cases {
		r := httptest.NewRequest(http.MethodGet, "/x", nil)
		r.SetPathValue("id", tc.id)
		r.SetPathValue("name", tc.name)
		w := httptest.NewRecorder()
		h(w, r)
		if w.Code != http.StatusNotFound {
			t.Errorf("id=%q name=%q status = %d, want 404", tc.id, tc.name, w.Code)
		}
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
