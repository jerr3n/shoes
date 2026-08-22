package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/coder/websocket"
	ginzap "github.com/gin-contrib/zap"
	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/google/uuid"
	"github.com/jerr3n/shoes/util"
	"github.com/joho/godotenv"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"gorm.io/gorm"
	_ "modernc.org/sqlite"
)

// entryPayload is the Open Cloud v2 Entry resource. The entry ID lives in the
// URL path, so the body only carries the value.

const (
	// How many messages a websocket client can fall behind before its
	// messages start getting dropped.
	subscriberBuffer = 32
	writeTimeout     = 10 * time.Second
	expiration       = 5
)

// allowedOrigins is matched against the Origin header on /ws. coder/websocket
// enforces same-origin by default, which would reject the Next.js dev server.
var allowedOrigins = []string{"localhost:3000", "127.0.0.1:3000"}

type EntryPayload struct {
	Value string `json:"value"`
}

func main() {
	if err := godotenv.Load(); err != nil {
		log.Fatal("Error loading .env file")
	}
	cfg := zap.NewDevelopmentConfig()
	cfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	loggerPriorToSettingsIWant, _ := cfg.Build()
	logger := loggerPriorToSettingsIWant.WithOptions(zap.WithCaller(false))
	//db, err := sql.Open("sqlite", "file:shoes.db?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	//if err != nil {
	//	log.Fatal(err)
	//}
	//defer db.Close()
	//
	//db.SetMaxOpenConns(1)
	//
	//if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS API_KEYS (JOB_ID TEXT PRIMARY KEY, API_KEY TEXT NOT NULL);`); err != nil {
	//	log.Fatal(err)
	//}
	db, err := gorm.Open(sqlite.Open("shoes.db"), &gorm.Config{})
	if err != nil {
		log.Fatal(err)
	}
	err = db.AutoMigrate(&util.APIKey{}, &util.DataStorage{})
	if err != nil {
		log.Fatal(err)
	}
	universeId := os.Getenv("UNIVERSE_ID")
	robloxApiKey := os.Getenv("ROBLOX_API_KEY")

	h := newHub()

	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(ginzap.Ginzap(logger, time.RFC3339, true))
	r.Use(ginzap.RecoveryWithZap(logger, true))
	client := http.Client{Timeout: 10 * time.Second}
	var rbx util.RobloxAPIConfig = util.RobloxAPIConfig{
		UniverseID: universeId,
		APIKey:     robloxApiKey,
	}
	r.GET("/init/:id", func(c *gin.Context) {
		id := c.Param("id") // always a string
		initLogger := logger.With(
			zap.String("job_id", id),
			zap.String("stage", "init"),
		)
		sentAt := time.Now().Unix()
		url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s", rbx.UniverseID, id)
		req, err := http.NewRequestWithContext(c.Request.Context(), http.MethodGet, url, nil)
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to init request: %v", err))
		}
		req.Header.Set("x-api-key", rbx.APIKey)
		resp, err := client.Do(req)
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to get resp: %v", err),
				zap.Int("status", resp.StatusCode),
			)
		}
		defer resp.Body.Close()

		switch resp.StatusCode {
		case http.StatusOK:
			var body util.ResolvedEntry
			data, err := io.ReadAll(resp.Body)
			if err != nil {
				initLogger.Error(fmt.Sprintf("i have no idea: %v", err))
				c.Status(http.StatusInternalServerError)
				return
			}
			if err := json.Unmarshal(data, &body); err != nil {
				initLogger.Error(fmt.Sprintf("i have no idea: %v", err))
				c.Status(http.StatusInternalServerError)
				return
			}
			entryTime, err := body.Timestamp()
			if err != nil {
				initLogger.Error(fmt.Sprintf("i have no idea: %v", err))
				c.Status(http.StatusInternalServerError)
				return
			}
			elapsed := sentAt - entryTime
			if elapsed > 60 || elapsed < 0 {
				initLogger.Warn("stale entry",
					zap.Int("sent", int(sentAt)),
					zap.Int("entry", int(entryTime)),
					zap.Int("elapsed", int(elapsed)),
				)
				c.Status(http.StatusTeapot)
				return
			}
		case http.StatusNotFound:
			initLogger.Warn("no entry")
			c.Status(http.StatusTeapot)
			return
		default:
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			log.Printf("job id lookup: roblox returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
			initLogger.Warn("roblox error",
				zap.Int("status", resp.StatusCode),
				zap.String("body", strings.TrimSpace(string(body))),
			)
			return
		}
		raw := make([]byte, 32)
		if _, err := rand.Read(raw); err != nil {
			initLogger.Error(fmt.Sprintf("key gen failed: %v", err))
			c.Status(http.StatusInternalServerError)
			return
		}
		apikey := hex.EncodeToString(raw)
		url = fmt.Sprintf(
			"https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s?allowMissing=true",
			rbx.UniverseID, id,
		)

		payload, err := json.Marshal(EntryPayload{Value: apikey})
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to marshal json: %v", err))
			c.Status(http.StatusInternalServerError)
			return
		}
		req, err = http.NewRequestWithContext(c.Request.Context(), http.MethodPatch, url, strings.NewReader(string(payload)))
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to make req: %v", err))
			c.Status(http.StatusInternalServerError)
			return
		}
		req.Header.Set("x-api-key", rbx.APIKey)
		req.Header.Set("Content-Type", "application/json")
		resp, err = client.Do(req)
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to do req: %v", err))
			c.Status(http.StatusInternalServerError)
			return
		}
		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			initLogger.Error(fmt.Sprintf("produce key: roblox returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body))))
			c.Status(http.StatusInternalServerError)
			return
		}
		resp.Body.Close()
		entry := util.APIKey{
			JobID:  id,
			APIKey: apikey,
		}
		result := db.Create(&entry)
		if result.Error != nil {
			initLogger.Error(fmt.Sprintf("failed to store key %v:", result.Error))
			c.Status(http.StatusInternalServerError)
			return
		}
		c.Status(http.StatusOK)
	})

	r.POST("/send", func(c *gin.Context) {
		key := c.Request.Header.Get("API-Key")

		// The key identifies the job, so authenticating and routing are the
		// same lookup.
		var jobId string
		result := db.Where("job_id = ?", jobId).First(&key)
		if result.Error != nil {
			if errors.Is(result.Error, gorm.ErrRecordNotFound) {
				c.Status(http.StatusUnauthorized)
				return
			} else {
				logger.Error(fmt.Sprintf("auth lookup failed: %v", result.Error))
				c.Status(http.StatusInternalServerError)
				return
			}
		}
		body, err := c.GetRawData()
		if err != nil {
			c.Status(http.StatusInternalServerError)
			return
		}

		if _, dropped := h.publish(jobId, body); dropped > 0 {
			logger.Error(fmt.Sprintf("dropped message for %d slow client(s) on job %q", dropped, jobId))
		}
		c.Status(http.StatusOK)
	})

	r.GET("/data/:id/:uuidv4", func(c *gin.Context) {

	})

	r.GET("/ws/:id", func(c *gin.Context) {
		id := c.Param("id")
		//wsLogger := logger.With(
		//	zap.String("job_id", id),
		//	zap.
		//)
		conn, err := websocket.Accept(c.Writer, c.Request, &websocket.AcceptOptions{
			OriginPatterns: allowedOrigins,
		})
		if err != nil {
			log.Println("accept:", err)
			return
		}
		defer conn.CloseNow()

		// Tied to the connection, not the gin request: gin cancels the request
		// context as soon as this handler returns.
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		// Unsubscribing closes sub, which ends the writer goroutine below.
		sub := h.subscribe(id)
		defer h.unsubscribe(id, sub)

		go func() {
			for msg := range sub {
				// Per-write deadline. One shared context would expire ten
				// seconds into the connection and fail every write after that.
				writeCtx, cancelWrite := context.WithTimeout(ctx, writeTimeout)
				err := conn.Write(writeCtx, websocket.MessageText, msg)
				cancelWrite()
				if err != nil {
					log.Printf("write error on job %q: %v", id, err)
					cancel()
					return
				}
			}
		}()

		for {
			_, payload, err := conn.Read(ctx)
			if err != nil {
				if websocket.CloseStatus(err) == websocket.StatusNormalClosure {
					log.Println("Connection closed normally")
				} else {
					log.Printf("Read error: %v", err)
				}
				break
			}
			identifier := uuid.NewString()
			exp := time.Now().Unix() + expiration
			db.Create(util.DataStorage{
				JobID: id,
				UUID:  identifier,
				Data:  payload,
				Exp:   exp, // timer starts now, server <-> client communication takes place within 5 seconds or it doesnt take place
			})
			//if res.Error != nil {
			//
			//}
			sum := sha256.Sum256(payload)
			content := util.MessageServiceRequest{
				Topic:   id,
				Message: fmt.Sprintf("%s\x1f%s\x1f%d\x04", identifier, hex.EncodeToString(sum[:]), exp),
			}
			message, _ := json.Marshal(content)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s:publishMessage", rbx.UniverseID), bytes.NewBuffer(message))
			if err != nil {

			}
			req.Header.Set("Context-Type", "application/json")
			req.Header.Set("X-API-Key", rbx.APIKey)
			_, _ = client.Do(req) // see no evil, hear no evil, speak no evil
		}

	})

	if err := r.Run(); err != nil {
		log.Fatal(err)

	}
}
