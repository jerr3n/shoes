package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jerr3n/shoes/util"
	"github.com/joho/godotenv"
	_ "modernc.org/sqlite"
)

func ProduceKey(ctx context.Context, client *http.Client, jobid string, universeid string, apikey string, producedapikey string) error {
	url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s", universeid, jobid)
	req, err := http.NewRequestWithContext(ctx, http.MethodPatch, url, strings.NewReader(fmt.Sprintf(`{"%s": "%s"}`, jobid, producedapikey)))
	if err != nil {
		return err
	}
	req.Header.Set("x-api-key", apikey)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("unknown error")
	}
	return nil
}

func JobIdValid(ctx context.Context, client *http.Client, jobid string, universeid string, apikey string) (bool, error) {
	sentAt := time.Now().Unix() // accounting for latency
	url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s", universeid, jobid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("x-api-key", apikey)
	resp, err := client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		var body util.ResolvedEntry
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return false, err
		}
		err = json.Unmarshal(data, &body)
		if err != nil {
			return false, err
		}
		entryTime, err := strconv.ParseInt(body.Value, 10, 64)
		if err != nil {
			return false, err
		}
		elapsed := sentAt - entryTime
		if elapsed > 60 || elapsed < 0 {
			return false, util.ErrorTooMuchTime
		}

		return true, nil
	case http.StatusNotFound:
		print("not found")
		return false, util.ErrorJobIdNotFound
	default:
		return false, util.ErrorMeta
	}
}

func main() {
	err := godotenv.Load()
	if err != nil {
		log.Fatal("Error loading .env file")
	}
	db, err := sql.Open("sqlite", "file:shoes.db")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS API_KEYS (JOB_ID TEXT PRIMARY KEY, API_KEY TEXT NOT NULL);`); err != nil {
		log.Fatal(err)
	}

	var universeId = os.Getenv("UNIVERSE_ID")
	var robloxApiKey = os.Getenv("ROBLOX_API_KEY")
	r := gin.Default()
	client := http.Client{Timeout: 10 * time.Second}
	r.GET("/init/:id", func(c *gin.Context) {
		id := c.Param("id") // always a string
		ok, err := JobIdValid(context.Background(), &client, id, universeId, robloxApiKey)
		fmt.Println(id)
		if !ok {
			switch {
			case errors.Is(err, util.ErrorTooMuchTime), errors.Is(err, util.ErrorJobIdNotFound):
				c.Status(http.StatusTeapot)
			case errors.Is(err, util.ErrorMeta):
				c.Status(http.StatusInternalServerError)
			}
		} else {
			bytes := make([]byte, 32)
			_, err := rand.Read(bytes)
			if err != nil {
				c.Status(http.StatusInternalServerError)
			}
			var apikey = string(bytes)
			err = ProduceKey(context.Background(), &client, id, universeId, robloxApiKey, apikey)
			if err != nil {
				c.Status(http.StatusInternalServerError)
			}
			if _, err := db.Exec(`INSERT INTO API_KEYS(JOB_ID, API_KEY) VALUES(?, ?)`, id, apikey); err != nil {
				c.Status(http.StatusInternalServerError)
			}
			c.Status(http.StatusOK)
		}
	})
	r.GET("/msg", func(c *gin.Context) {
		key := c.Request.Header.Get("X-API-Key")
		var authorized bool
		err := db.QueryRow(`SELECT EXISTS(SELECT 1 FROM API_KEYS WHERE API_KEY = ?)`, key).Scan(&authorized)
		if err != nil {
			c.Status(http.StatusInternalServerError)
		}

		if !authorized {
			c.Status(http.StatusUnauthorized)
		} else {
			body, err := c.GetRawData()
			if err != nil {
				c.Status(http.StatusInternalServerError)
				return
			}
			fmt.Print(string(body))
		}
	})
	r.Run()
}
