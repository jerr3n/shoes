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
	"slices"
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
	"moul.io/zapgorm2"
)

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
var version = "unknown" // this reminds me of the 6 bangs in systemd if you know what i mean

type EntryPayload struct {
	Value string `json:"value"`
}

// GameMiddleware middleware to make sure that endpoints that a game would access are secure
func GameMiddleware(db *gorm.DB, logger *zap.Logger, allowedGameIds []string, strict bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := c.Request.Header.Get("API-Key")
		jobid := c.Request.Header.Get("Job-ID")
		if strict {
			rbxid := c.Request.Header.Get("roblox-id")
			useragent := c.Request.Header.Get("user-agent")
			if !(slices.Contains(allowedGameIds, rbxid) && useragent == "Roblox/Linux") {
				logger.Warn("malicious actor caught by middleware",
					zap.String("req_game_id", rbxid),
					zap.String("req_useragent", useragent),
					zap.String("host", c.Request.Host),
				)
				c.AbortWithStatus(http.StatusForbidden)
				return
			}
		}

		var apiKey util.APIKey
		if err := db.Where("job_id = ?", jobid).First(&apiKey).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {

				c.AbortWithStatus(http.StatusUnauthorized)
				return
			}

			logger.Error(fmt.Sprintf("auth lookup failed: %v", err))
			c.AbortWithStatus(http.StatusInternalServerError)
			return
		}
		if apiKey.APIKey != key {
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}

		c.Set("jobid", jobid)
		c.Set("apikey", key)
		c.Next()
	}

}

func main() {

	// logger stuff
	cfg := zap.NewDevelopmentConfig()
	cfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	loggerPriorToSettingsIWant, _ := cfg.Build()
	logger := loggerPriorToSettingsIWant.WithOptions(zap.WithCaller(false))
	logger.Info("shoes - a protected socket between roblox and a backend")
	logger.Info(fmt.Sprintf("you are on version %s", version))
	if err := godotenv.Load(); err != nil {
		logger.Fatal("Error loading .env file")
	}
	gormLog := zapgorm2.New(logger)
	// db stuff
	db, err := gorm.Open(sqlite.Open("shoes.db"), &gorm.Config{Logger: gormLog})
	if err != nil {
		log.Fatal(err)
	}
	err = db.AutoMigrate(&util.APIKey{}, &util.DataStorage{})
	if err != nil {
		log.Fatal(err)
	}
	// env vars
	universeId := os.Getenv("UNIVERSE_ID")
	robloxApiKey := os.Getenv("ROBLOX_API_KEY")

	h := newHub()

	// it begins here
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(ginzap.Ginzap(logger, time.RFC3339, true))
	r.Use(ginzap.RecoveryWithZap(logger, true))
	client := http.Client{Timeout: 10 * time.Second}
	var rbx util.RobloxAPIConfig = util.RobloxAPIConfig{
		UniverseID: universeId,
		APIKey:     robloxApiKey,
	}
	r.GET("/init", func(c *gin.Context) {
		id := c.Request.Header.Get("Job-ID")

		initLogger := logger.With(
			zap.String("job_id", id),
			zap.String("stage", "init"),
		)
		// Without this the empty id sails through and we look up (then write)
		// the datastore entry named "", keyed to an APIKey row with no job.
		if id == "" {
			initLogger.Warn("init with no Job-ID header")
			c.Status(http.StatusBadRequest)
			return
		}
		sentAt := time.Now().Unix()
		url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s", rbx.UniverseID, id)
		req, err := http.NewRequestWithContext(c.Request.Context(), http.MethodGet, url, nil)
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to init request: %v", err))
			c.Status(http.StatusInternalServerError)
			return
		}
		req.Header.Set("x-api-key", rbx.APIKey)
		// On a transport error Do returns a nil response, so there is no status
		// to log and nothing to close: bail before touching resp.
		resp, err := client.Do(req)
		if err != nil {
			initLogger.Error(fmt.Sprintf("failed to get resp: %v", err))
			c.Status(http.StatusBadGateway)
			return
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
			c.Status(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			initLogger.Error(fmt.Sprintf("produce key: roblox returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body))))
			c.Status(http.StatusInternalServerError)
			return
		}
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
	authGroup := r.Group("/")
	authGroup.Use(GameMiddleware(db, logger, []string{universeId}, false))
	{
		authGroup.POST("/send", func(c *gin.Context) {
			id := fmt.Sprint(c.MustGet("jobid"))
			// The key identifies the job, so authenticating and routing are the
			// same lookup.
			body, err := c.GetRawData()
			if err != nil {
				c.Status(http.StatusInternalServerError)
				return
			}

			if _, dropped := h.publish(id, body); dropped > 0 {
				logger.Error(fmt.Sprintf("dropped message for %d slow client(s) on job %q", dropped, id))
			}
			c.Status(http.StatusOK)
		})
		authGroup.GET("/data/:uuidv4", func(c *gin.Context) {
			id := fmt.Sprint(c.MustGet("jobid"))
			uuidv4 := c.Param("uuidv4")

			var entry util.DataStorage
			if err := db.Where("job_id = ? AND uuid = ?", id, uuidv4).First(&entry).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					c.Status(http.StatusNotFound)
					return
				}

				logger.Error(fmt.Sprintf("data lookup failed: %v", err))
				c.Status(http.StatusInternalServerError)
				return
			}
			// The entry is only good for the window the producer promised.
			if time.Now().Unix() > entry.Exp {
				c.Status(http.StatusGone)
				return
			}
			c.Data(http.StatusOK, "application/octet-stream", entry.Data)
		})
	}

	r.GET("/ws/:id", func(c *gin.Context) {
		id := c.Param("id")
		wsLogger := logger.With(
			zap.String("job_id", id),
			zap.String("meth", "tx"),
		)
		conn, err := websocket.Accept(c.Writer, c.Request, &websocket.AcceptOptions{
			//OriginPatterns: allowedOrigins,
		})
		if err != nil {
			wsLogger.Error(fmt.Sprintf("accept: %v", err))
			return
		}
		defer conn.CloseNow()

		// Tied to the connection, not the gin request: gin cancels the request
		// context as soon as this handler returns.
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()

		sub := h.subscribe(id)

		// writerDone is closed when the writer goroutine has stopped touching
		// conn. Unsubscribing closes sub, which is what ends that goroutine, so
		// the two have to happen in order and before the deferred CloseNow.
		writerDone := make(chan struct{})
		defer func() {
			h.unsubscribe(id, sub)
			<-writerDone
		}()

		go func() {
			defer close(writerDone)
			// A dead write means a dead connection: cancelling unblocks the
			// read loop below so the handler runs its teardown.
			defer cancel()

			for msg := range sub {
				// Per-write deadline. One shared context would expire ten
				// seconds into the connection and fail every write after that.
				writeCtx, cancelWrite := context.WithTimeout(ctx, writeTimeout)
				err := conn.Write(writeCtx, websocket.MessageText, msg)
				cancelWrite()
				if err != nil {
					wsLogger.Error(fmt.Sprintf("write failed: %v", err))
					return
				}
			}
		}()

		for {
			_, payload, err := conn.Read(ctx)
			if err != nil {
				if websocket.CloseStatus(err) == websocket.StatusNormalClosure {
					wsLogger.Info("connection closed normally")
				} else {
					wsLogger.Error(fmt.Sprintf("read failed: %v", err))
				}
				break
			}
			identifier := uuid.NewString()
			exp := time.Now().Unix() + expiration
			res := db.Create(&util.DataStorage{
				JobID: id,
				UUID:  identifier,
				Data:  payload,
				Exp:   exp, // timer starts now, server <-> client communication takes place within 5 seconds or it doesnt take place
			})
			if res.Error != nil {
				logger.Error(fmt.Sprintf("failed to store data for job %q: %v", id, res.Error))
				continue
			}
			sum := sha256.Sum256(payload)
			content := util.MessageServiceRequest{
				Topic:   id,
				Message: fmt.Sprintf("\x02%s\x1f%s\x1f%d\x03", identifier, hex.EncodeToString(sum[:]), exp),
			}
			message, _ := json.Marshal(content)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s:publishMessage", rbx.UniverseID), bytes.NewBuffer(message))
			if err != nil {
				wsLogger.Error(fmt.Sprintf("failed to build publish request: %v", err))
				continue
			}
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-API-Key", rbx.APIKey)
			_, _ = client.Do(req) // see no evil, hear no evil, speak no evil
		}

	})

	if err := r.Run(); err != nil {
		log.Fatal(err)

	}
}
