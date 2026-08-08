package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/coder/websocket"
	"github.com/gin-gonic/gin"
	"github.com/jerr3n/shoes/util"
	"github.com/joho/godotenv"
	_ "modernc.org/sqlite"
)

// entryPayload is the Open Cloud v2 Entry resource. The entry ID lives in the
// URL path, so the body only carries the value.

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
	tx := make(chan []byte)
	rx := make(chan []byte)

	r := gin.Default()
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
				log.Printf("no entry for job %q", id)
				c.Status(http.StatusTeapot)
			case errors.Is(err, util.ErrorTooMuchTime):
				log.Printf("stale entry for job %q", id)
				c.Status(http.StatusTeapot)
			case errors.Is(err, util.ErrorMeta):
				c.Status(http.StatusInternalServerError)
			default:
				// Network failure, malformed response, unparseable timestamp,
				// etc. Without this the handler would fall through to 200.
				log.Printf("job id validation failed for %q: %v", id, err)
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
			log.Printf("failed to store key for %q: %v", id, err)
			c.Status(http.StatusInternalServerError)
			return
		}

		c.Status(http.StatusOK)
	})

	r.POST("/incoming", func(c *gin.Context) {
		key := c.Request.Header.Get("X-API-Key")

		var authorized bool
		if err := db.QueryRow(
			`SELECT EXISTS(SELECT 1 FROM API_KEYS WHERE API_KEY = ?)`, key,
		).Scan(&authorized); err != nil {
			log.Printf("auth lookup failed: %v", err)
			c.Status(http.StatusInternalServerError)
			return
		}

		if !authorized {
			c.Status(http.StatusUnauthorized)
			return
		}

		body, err := c.GetRawData()
		if err != nil {
			c.Status(http.StatusInternalServerError)
			return
		}
		rx <- body
		c.Status(http.StatusOK)
	})

	r.GET("/ws", func(c *gin.Context) {
		conn, err := websocket.Accept(c.Writer, c.Request, &websocket.AcceptOptions{})
		if err != nil {
			log.Println("accept:", err)
			return
		}
		defer conn.CloseNow()
		go func() {
			writeCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			for msg := range rx {
				_ = conn.Write(writeCtx, websocket.MessageText, msg)
			}
		}()
		for {
			_, payload, err := conn.Read(context.Background())
			if err != nil {
				if websocket.CloseStatus(err) == websocket.StatusNormalClosure {
					log.Println("Connection closed normally")
				} else {
					log.Printf("Read error: %v", err)
				}
				break
			}
			
		}

	})

	if err := r.Run(); err != nil {
		log.Fatal(err)

	}
}
