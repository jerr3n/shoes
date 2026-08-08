package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jerr3n/shoes/util"
	"github.com/joho/godotenv"
)

func JobIdValid(ctx context.Context, client *http.Client, jobid string, universeid string, apikey string) (bool, error) {
	sentAt := time.Now().Unix() // accounting for latency
	url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s", universeid, jobid)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
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
		if elapsed > 60 {
			return false, util.ErrorTooMuchTime
		}

		return true, nil
	case http.StatusNotFound:
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
	r := gin.Default()
	client := http.Client{Timeout: 10 * time.Second}
	r.GET("/init/:id", func(c *gin.Context) {
		id := c.Param("id") // always a string
		ok, err := JobIdValid(context.Background(), &client, id, os.Getenv("UNIVERSE_ID"), os.Getenv("ROBLOX_API_KEY"))
		switch err {
		case util.ErrorTooMuchTime, util.ErrorJobIdNotFound:
			c.Status(http.StatusTeapot)
		case util.ErrorMeta:
			c.Status(http.StatusInternalServerError)
		case !nil:

		}
	})

	r.Run()
}
