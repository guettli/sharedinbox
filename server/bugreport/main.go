package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// BugReport represents the data stored in report.json
type BugReport struct {
	Description string    `json:"description"`
	AboutInfo   string    `json:"about_info"`
	EmailData   string    `json:"email_data,omitempty"`
	SyncLog     string    `json:"sync_log,omitempty"`
	Timestamp   time.Time `json:"timestamp"`
}

// maxBodySize caps request bodies at 20 MB.
const maxBodySize = 20 * 1024 * 1024

// uuidRe matches the UUID v4 strings we generate; used to reject path
// traversal in the encrypted-mail download route.
var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

var (
	rateLimitMu  sync.Mutex
	requestTimes []time.Time
)

// checkRateLimit implements a sliding window rate limiter: max 10 requests per minute globally.
func checkRateLimit() (bool, time.Duration) {
	rateLimitMu.Lock()
	defer rateLimitMu.Unlock()

	now := time.Now()
	// Clean up timestamps older than 1 minute
	var valid []time.Time
	for _, t := range requestTimes {
		if now.Sub(t) < time.Minute {
			valid = append(valid, t)
		}
	}
	requestTimes = valid

	if len(requestTimes) >= 10 {
		// Calculate time until the oldest request in the window falls out of it
		oldest := requestTimes[0]
		remaining := time.Minute - now.Sub(oldest)
		if remaining < 0 {
			remaining = 0
		}
		return false, remaining
	}

	requestTimes = append(requestTimes, now)
	return true, 0
}

// setCORS allows the web app to talk to the API from any origin.
func setCORS(w http.ResponseWriter, methods string) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", methods)
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
}

// writeJSONError writes {"error": msg} with the given status code.
func writeJSONError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// enforceRateLimit returns false (and writes a 429) when the global limit is
// exceeded; callers should stop processing in that case.
func enforceRateLimit(w http.ResponseWriter) bool {
	allowed, waitTime := checkRateLimit()
	if allowed {
		return true
	}
	retryAfter := int(waitTime.Seconds())
	if retryAfter < 1 {
		retryAfter = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSONError(w, http.StatusTooManyRequests, "Too many requests. Please try again later.")
	return false
}

// preflightPost handles the shared prologue for the multipart POST endpoints:
// CORS, the OPTIONS pre-flight, the method guard, rate limiting and body
// parsing. It returns false when it has already written the response and the
// caller should stop.
func preflightPost(w http.ResponseWriter, r *http.Request) bool {
	setCORS(w, "POST, OPTIONS")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return false
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return false
	}
	if !enforceRateLimit(w) {
		return false
	}
	return parseMultipart(w, r)
}

// parseMultipart enforces the body-size cap and parses the multipart form,
// writing a 413 on failure. Returns false when parsing failed.
func parseMultipart(w http.ResponseWriter, r *http.Request) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)
	if err := r.ParseMultipartForm(maxBodySize); err != nil {
		log.Printf("Failed to parse multipart form: %v", err)
		writeJSONError(w, http.StatusRequestEntityTooLarge, "Request body too large or invalid multipart form.")
		return false
	}
	return true
}

func generateUUID() (string, error) {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		return "", err
	}
	// Format as UUID v4 structure
	b[6] = (b[6] & 0x0f) | 0x40 // Version 4
	b[8] = (b[8] & 0x3f) | 0x80 // Variant is 10
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

// saveFormFile copies a single uploaded file into destPath.
func saveFormFile(fileHeader *multipart.FileHeader, destPath string) error {
	src, err := fileHeader.Open()
	if err != nil {
		return err
	}
	defer src.Close()

	dst, err := os.OpenFile(destPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer dst.Close()

	_, err = io.Copy(dst, src)
	return err
}

func bugReportHandler(storageDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !preflightPost(w, r) {
			return
		}
		defer func() {
			_ = r.MultipartForm.RemoveAll()
		}()

		description := r.FormValue("description")
		aboutInfo := r.FormValue("about_info")

		if description == "" || aboutInfo == "" {
			writeJSONError(w, http.StatusBadRequest, "description and about_info are required fields.")
			return
		}

		email := r.FormValue("email")
		emailData := r.FormValue("email_data")
		syncLog := r.FormValue("sync_log")

		uuidVal, err := generateUUID()
		if err != nil {
			log.Printf("Failed to generate UUID: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		now := time.Now()
		timestampStr := now.Format("20060102_150405")
		dirName := fmt.Sprintf("%s_%s", timestampStr, uuidVal)
		reportDir := filepath.Join(storageDir, dirName)

		err = os.MkdirAll(reportDir, 0750)
		if err != nil {
			log.Printf("Failed to create report directory: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		// Write report.json
		report := BugReport{
			Description: description,
			AboutInfo:   aboutInfo,
			EmailData:   emailData,
			SyncLog:     syncLog,
			Timestamp:   now,
		}

		if err := writeReportJSON(reportDir, report); err != nil {
			log.Printf("Failed to write report.json: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		// Write contact email to mail.eml (kept separate from report.json to isolate PII)
		if email != "" {
			mailEmlPath := filepath.Join(reportDir, "mail.eml")
			err = os.WriteFile(mailEmlPath, []byte(email), 0600)
			if err != nil {
				log.Printf("Failed to write mail.eml: %v", err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
		}

		// Save attachments
		form := r.MultipartForm
		files := form.File["attachments[]"]
		for i, fileHeader := range files {
			// Sanitize filename to avoid directory traversal
			baseName := filepath.Base(fileHeader.Filename)
			attachmentName := fmt.Sprintf("attachment_%d_%s", i, baseName)
			if err := saveFormFile(fileHeader, filepath.Join(reportDir, attachmentName)); err != nil {
				log.Printf("Failed to save attachment %s: %v", attachmentName, err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]string{"id": uuidVal})
	}
}

// writeReportJSON writes an indented report.json into reportDir.
func writeReportJSON(reportDir string, report BugReport) error {
	f, err := os.OpenFile(filepath.Join(reportDir, "report.json"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(report)
}

// reportKeyHandler serves the maintainer's public key. pubKeyB64 is
// base64(keyId[16] || publicKey[32]) — the same payload the app embeds in its
// public-key QR codes.
func reportKeyHandler(pubKeyB64 string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		setCORS(w, "GET, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		if pubKeyB64 == "" {
			writeJSONError(w, http.StatusServiceUnavailable, "Encrypted reports are not configured on this server.")
			return
		}
		raw, err := base64.StdEncoding.DecodeString(pubKeyB64)
		if err != nil || len(raw) != 48 {
			log.Printf("Invalid REPORT_PUBLIC_KEY: err=%v len=%d", err, len(raw))
			writeJSONError(w, http.StatusInternalServerError, "Server public key is misconfigured.")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"keyId":     base64.StdEncoding.EncodeToString(raw[:16]),
			"publicKey": base64.StdEncoding.EncodeToString(raw[16:]),
			"alg":       "x25519-ecies-aesgcm",
		})
	}
}

// issueCreator abstracts GitHub issue creation so the handler is testable.
type issueCreator interface {
	CreateIssue(ctx context.Context, title, body string) (htmlURL string, number int, err error)
}

// githubIssueCreator creates issues via the GitHub REST API.
type githubIssueCreator struct {
	token   string // GitHub token with `issues:write` on the target repo
	repo    string // "owner/name"
	apiBase string // e.g. https://api.github.com
	client  *http.Client
}

func (g *githubIssueCreator) CreateIssue(ctx context.Context, title, body string) (string, int, error) {
	payload, _ := json.Marshal(map[string]any{
		"title":  title,
		"body":   body,
		"labels": []string{"encrypted-report"},
	})
	url := fmt.Sprintf("%s/repos/%s/issues", g.apiBase, g.repo)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Authorization", "Bearer "+g.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")

	resp, err := g.client.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusCreated {
		return "", 0, fmt.Errorf("github returned %d: %s", resp.StatusCode, string(respBody))
	}
	var parsed struct {
		HTMLURL string `json:"html_url"`
		Number  int    `json:"number"`
	}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", 0, err
	}
	return parsed.HTMLURL, parsed.Number, nil
}

// encryptedReportHandler stores the encrypted mail and opens a public GitHub
// issue that links to it. The mail is encrypted on the device, so only the
// maintainer (holding the private key) can read it.
func encryptedReportHandler(storageDir, publicBaseURL string, issuer issueCreator) http.HandlerFunc {
	encDir := filepath.Join(storageDir, "encrypted")
	return func(w http.ResponseWriter, r *http.Request) {
		if !preflightPost(w, r) {
			return
		}
		defer func() {
			_ = r.MultipartForm.RemoveAll()
		}()
		if issuer == nil {
			writeJSONError(w, http.StatusServiceUnavailable, "Encrypted reports are not configured on this server.")
			return
		}

		description := r.FormValue("description")
		if description == "" {
			writeJSONError(w, http.StatusBadRequest, "description is a required field.")
			return
		}
		mailFiles := r.MultipartForm.File["encrypted_mail"]
		if len(mailFiles) == 0 {
			writeJSONError(w, http.StatusBadRequest, "encrypted_mail is a required file.")
			return
		}

		uuidVal, err := generateUUID()
		if err != nil {
			log.Printf("Failed to generate UUID: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		reportDir := filepath.Join(encDir, uuidVal)
		if err := os.MkdirAll(reportDir, 0750); err != nil {
			log.Printf("Failed to create report directory: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		if err := saveFormFile(mailFiles[0], filepath.Join(reportDir, "mail.enc")); err != nil {
			log.Printf("Failed to save encrypted mail: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		report := BugReport{
			Description: description,
			AboutInfo:   r.FormValue("about_info"),
			SyncLog:     r.FormValue("sync_log"),
			Timestamp:   time.Now(),
		}
		if err := writeReportJSON(reportDir, report); err != nil {
			log.Printf("Failed to write report.json: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		downloadURL := fmt.Sprintf("%s/api/v1/encrypted-reports/%s/mail.enc", publicBaseURL, uuidVal)
		title, body := buildIssue(report, downloadURL)
		issueURL, number, err := issuer.CreateIssue(r.Context(), title, body)
		if err != nil {
			log.Printf("Failed to create GitHub issue: %v", err)
			writeJSONError(w, http.StatusBadGateway, "Failed to create the GitHub issue.")
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id":          uuidVal,
			"issueUrl":    issueURL,
			"issueNumber": number,
		})
	}
}

// buildIssue renders the public (cleartext) issue title and body. The mail
// itself is never inlined — only a link to its encrypted download.
func buildIssue(report BugReport, downloadURL string) (title, body string) {
	title = "Bug report with encrypted mail"
	var b bytes.Buffer
	b.WriteString(report.Description)
	b.WriteString("\n\n---\n\n")
	b.WriteString("📎 **Encrypted mail:** ")
	b.WriteString(downloadURL)
	b.WriteString("\n\n_The attached mail is end-to-end encrypted; only the maintainer can decrypt it._\n")
	if report.AboutInfo != "" {
		b.WriteString("\n<details><summary>System info</summary>\n\n")
		b.WriteString(report.AboutInfo)
		b.WriteString("\n</details>\n")
	}
	return title, b.String()
}

// encryptedMailHandler serves a stored encrypted-mail blob by report id.
func encryptedMailHandler(storageDir string) http.HandlerFunc {
	encDir := filepath.Join(storageDir, "encrypted")
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}
		id := r.PathValue("id")
		if !uuidRe.MatchString(id) {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		path := filepath.Join(encDir, id, "mail.enc")
		f, err := os.Open(path)
		if err != nil {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		defer f.Close()
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", `attachment; filename="mail.enc"`)
		_, _ = io.Copy(w, f)
	}
}

func main() {
	port := os.Getenv("BUGREPORT_PORT")
	if port == "" {
		port = "8090"
	}

	storageDir := os.Getenv("BUGREPORT_STORAGE_DIR")
	if storageDir == "" {
		storageDir = "./reports"
	}

	// Create storage directory if it doesn't exist
	err := os.MkdirAll(storageDir, 0750)
	if err != nil {
		log.Fatalf("Failed to create storage directory %s: %v", storageDir, err)
	}

	publicBaseURL := os.Getenv("PUBLIC_BASE_URL")
	if publicBaseURL == "" {
		publicBaseURL = "https://sharedinbox.de"
	}

	// GitHub issue creation is optional: without a token/repo the encrypted
	// report endpoint reports itself as unavailable instead of failing hard.
	var issuer issueCreator
	ghToken := os.Getenv("GITHUB_TOKEN")
	ghRepo := os.Getenv("GITHUB_REPO")
	if ghToken != "" && ghRepo != "" {
		apiBase := os.Getenv("GITHUB_API_URL")
		if apiBase == "" {
			apiBase = "https://api.github.com"
		}
		issuer = &githubIssueCreator{
			token:   ghToken,
			repo:    ghRepo,
			apiBase: apiBase,
			client:  &http.Client{Timeout: 15 * time.Second},
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/bug-reports", bugReportHandler(storageDir))
	mux.HandleFunc("/api/v1/report-key", reportKeyHandler(os.Getenv("REPORT_PUBLIC_KEY")))
	mux.HandleFunc("/api/v1/encrypted-reports", encryptedReportHandler(storageDir, publicBaseURL, issuer))
	mux.HandleFunc("GET /api/v1/encrypted-reports/{id}/mail.enc", encryptedMailHandler(storageDir))

	addr := net.JoinHostPort("0.0.0.0", port)
	log.Printf("Bug report server starting on %s...", addr)
	log.Printf("Reports storage directory: %s", storageDir)

	server := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed to start: %v", err)
	}
}
