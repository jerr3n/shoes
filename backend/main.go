package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/coder/websocket"
	ginzap "github.com/gin-contrib/zap"
	"github.com/gin-gonic/gin"
	"github.com/jerr3n/shoes/util"
	"github.com/joho/godotenv"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	_ "modernc.org/sqlite"
)

// entryPayload is the Open Cloud v2 Entry resource. The entry ID lives in the
// URL path, so the body only carries the value.

const (
	// How many messages a websocket client can fall behind before its
	// messages start getting dropped.
	subscriberBuffer = 32
	writeTimeout     = 10 * time.Second
)

// allowedOrigins is matched against the Origin header on /ws. coder/websocket
// enforces same-origin by default, which would reject the Next.js dev server.
var allowedOrigins = []string{"localhost:3000", "127.0.0.1:3000"}

func generateKey() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func main() {
	if err := godotenv.Load(); err != nil {
		log.Fatal("Error loading .env file")
	}
	cfg := zap.NewDevelopmentConfig()
	cfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	loggerPriorToSettingsIWant, _ := cfg.Build()
	logger := loggerPriorToSettingsIWant.WithOptions(zap.WithCaller(false))
	db, err := sql.Open("sqlite", "file:shoes.db?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	db.SetMaxOpenConns(1)

	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS API_KEYS (JOB_ID TEXT PRIMARY KEY, API_KEY TEXT NOT NULL);`); err != nil {
		log.Fatal(err)
	}

	universeId := os.Getenv("UNIVERSE_ID")
	robloxApiKey := os.Getenv("ROBLOX_API_KEY")

	// we have no idea what it's sending/receiving
	// but it's data!
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

		ok, err := util.ValidateJobId(util.HTTPConfig{
			Ctx:    c.Request.Context(),
			Client: &client,
		}, rbx, id)
		if !ok {
			switch {
			case errors.Is(err, util.ErrorJobIdNotFound):
				logger.Warn(fmt.Sprintf("no entry for job %q", id))
				c.Status(http.StatusTeapot)
			case errors.Is(err, util.ErrorTooMuchTime):
				logger.Warn(fmt.Sprintf("stale entry for job %q", id))
				c.Status(http.StatusTeapot)
			case errors.Is(err, util.ErrorMeta):
				c.Status(http.StatusInternalServerError)
			default:
				// Network failure, malformed response, unparseable timestamp,
				// etc. Without this the handler would fall through to 200.
				logger.Warn(fmt.Sprintf("job id validation failed for %q: %v", id, err))
				c.Status(http.StatusInternalServerError)
			}
			return
		}

		apikey, err := generateKey()
		if err != nil {
			log.Printf("key generation failed: %v", err)
			c.Status(http.StatusInternalServerError)
			return
		}

		if err := util.ProduceKey(util.HTTPConfig{
			Ctx:    context.Background(),
			Client: &client,
		}, rbx, id, apikey); err != nil {
			log.Printf("failed to push key for %q: %v", id, err)
			c.Status(http.StatusInternalServerError)
			return
		}

		// Re-initializing an existing job should rotate its key rather than
		// collide on the primary key.
		if _, err := db.Exec(
			`INSERT INTO API_KEYS(JOB_ID, API_KEY) VALUES(?, ?)
			 ON CONFLICT(JOB_ID) DO UPDATE SET API_KEY = excluded.API_KEY`,
			id, apikey,
		); err != nil {
			logger.Error(fmt.Sprintf("failed to store key for %q: %v", id, err))
			c.Status(http.StatusInternalServerError)
			return
		}

		c.Status(http.StatusOK)
	})

	//r.POST("/ready", func(c *gin.Context) {
	//	key := c.Request.Header.Get("X-API-Key")
	//
	//})

	r.POST("/send", func(c *gin.Context) {
		key := c.Request.Header.Get("API-Key")

		// The key identifies the job, so authenticating and routing are the
		// same lookup.
		var jobId string
		switch err := db.QueryRow(
			`SELECT JOB_ID FROM API_KEYS WHERE API_KEY = ?`, key,
		).Scan(&jobId); {
		case errors.Is(err, sql.ErrNoRows):
			c.Status(http.StatusUnauthorized)
			return
		case err != nil:
			logger.Error(fmt.Sprintf("auth lookup failed: %v", err))
			c.Status(http.StatusInternalServerError)
			return
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

	// TODO: /ws is unauthenticated. Anyone who can reach the port can read a
	// job's traffic and inject messages into it, given only its job id.
	r.GET("/ws/:id", func(c *gin.Context) {
		id := c.Param("id")

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

			if err := util.SendMessage(util.HTTPConfig{
				Ctx:    ctx,
				Client: &client,
			}, rbx, id, payload); err != nil {
				log.Printf("failed to publish to job %q: %v", id, err)
			}
		}

	})

	if err := r.Run(); err != nil {
		log.Fatal(err)

	}
}
