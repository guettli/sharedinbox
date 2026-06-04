package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// BugReport represents the data stored in report.json
type BugReport struct {
	Description string    `json:"description"`
	Email       string    `json:"email"`
	AboutInfo   string    `json:"about_info"`
	EmailData   string    `json:"email_data,omitempty"`
	SyncLog     string    `json:"sync_log,omitempty"`
	Timestamp   time.Time `json:"timestamp"`
	HashedIP    string    `json:"hashed_ip"`
}

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

func hashIP(ip string) string {
	h := sha256.New()
	h.Write([]byte(ip))
	return hex.EncodeToString(h.Sum(nil))
}

func bugReportHandler(storageDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Enable CORS so the web app (if applicable) can upload
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		if r.Method != http.MethodPost {
			http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
			return
		}

		// Rate limiting check
		allowed, waitTime := checkRateLimit()
		if !allowed {
			retryAfter := int(waitTime.Seconds())
			if retryAfter < 1 {
				retryAfter = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusTooManyRequests)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "Too many requests. Please try again later."})
			return
		}

		// Limit body size to 20 MB (20 * 1024 * 1024 bytes)
		const maxBodySize = 20 * 1024 * 1024
		r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

		// Parse the multipart form
		err := r.ParseMultipartForm(maxBodySize)
		if err != nil {
			log.Printf("Failed to parse multipart form: %v", err)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusRequestEntityTooLarge)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "Request body too large or invalid multipart form."})
			return
		}
		defer func() {
			_ = r.MultipartForm.RemoveAll()
		}()

		description := r.FormValue("description")
		aboutInfo := r.FormValue("about_info")

		if description == "" || aboutInfo == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "description and about_info are required fields."})
			return
		}

		email := r.FormValue("email")
		emailData := r.FormValue("email_data")
		syncLog := r.FormValue("sync_log")

		// Get IP address
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		// Check X-Forwarded-For if behind a proxy
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if len(parts) > 0 {
				ip = strings.TrimSpace(parts[0])
			}
		}
		hashedIP := hashIP(ip)

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
			Email:       email,
			AboutInfo:   aboutInfo,
			EmailData:   emailData,
			SyncLog:     syncLog,
			Timestamp:   now,
			HashedIP:    hashedIP,
		}

		reportJSONPath := filepath.Join(reportDir, "report.json")
		reportJSONFile, err := os.OpenFile(reportJSONPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
		if err != nil {
			log.Printf("Failed to create report.json: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}
		defer reportJSONFile.Close()

		enc := json.NewEncoder(reportJSONFile)
		enc.SetIndent("", "  ")
		err = enc.Encode(report)
		if err != nil {
			log.Printf("Failed to write report.json: %v", err)
			http.Error(w, "Internal Server Error", http.StatusInternalServerError)
			return
		}

		// Save attachments
		form := r.MultipartForm
		files := form.File["attachments[]"]
		for i, fileHeader := range files {
			file, err := fileHeader.Open()
			if err != nil {
				log.Printf("Failed to open attachment %d: %v", i, err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
			defer file.Close()

			// Sanitize filename to avoid directory traversal
			baseName := filepath.Base(fileHeader.Filename)
			attachmentName := fmt.Sprintf("attachment_%d_%s", i, baseName)
			attachmentPath := filepath.Join(reportDir, attachmentName)

			destFile, err := os.OpenFile(attachmentPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
			if err != nil {
				log.Printf("Failed to create attachment file %s: %v", attachmentName, err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
			defer destFile.Close()

			_, err = io.Copy(destFile, file)
			if err != nil {
				log.Printf("Failed to copy attachment content to %s: %v", attachmentName, err)
				http.Error(w, "Internal Server Error", http.StatusInternalServerError)
				return
			}
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]string{"id": uuidVal})
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

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/bug-reports", bugReportHandler(storageDir))

	addr := net.JoinHostPort("127.0.0.1", port)
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
