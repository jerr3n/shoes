package util

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

type EntryPayload struct {
	Value string `json:"value"`
}

// ProduceKey produces a key in the datastore.
func ProduceKey(cfg HTTPConfig, rbx RobloxAPIConfig, jobId string, apikey string) error {
	url := fmt.Sprintf(
		"https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s?allowMissing=true",
		rbx.UniverseID, jobId,
	)

	payload, err := json.Marshal(EntryPayload{Value: apikey})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(cfg.Ctx, http.MethodPatch, url, strings.NewReader(string(payload)))
	if err != nil {
		return err
	}
	req.Header.Set("x-api-key", rbx.APIKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := cfg.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("produce key: roblox returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

func ValidateJobId(cfg HTTPConfig, rbx RobloxAPIConfig, jobid string) (bool, error) {
	sentAt := time.Now().Unix() // accounting for latency
	url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s/data-stores/SecureStore/entries/%s", rbx.UniverseID, jobid)
	req, err := http.NewRequestWithContext(cfg.Ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("x-api-key", rbx.APIKey)
	resp, err := cfg.Client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		var body ResolvedEntry
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return false, err
		}
		if err := json.Unmarshal(data, &body); err != nil {
			return false, err
		}
		entryTime, err := body.Timestamp()
		if err != nil {
			return false, err
		}
		elapsed := sentAt - entryTime
		if elapsed > 60 || elapsed < 0 {
			log.Printf("stale entry for %q: sentAt=%d entryTime=%d elapsed=%d", jobid, sentAt, entryTime, elapsed)
			return false, ErrorTooMuchTime
		}
		return true, nil
	case http.StatusNotFound:
		return false, ErrorJobIdNotFound
	default:
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		log.Printf("job id lookup: roblox returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		return false, ErrorMeta
	}
}

func SendMessage(cfg HTTPConfig, rbx RobloxAPIConfig, jobid string, data []byte) error {
	url := fmt.Sprintf("https://apis.roblox.com/cloud/v2/universes/%s:publishMessage", rbx.UniverseID)
	messages, err := Chunk(data)
	if err != nil {
		return err
	}
	for _, message := range messages {
		payload := MessageServiceRequest{Topic: jobid, Message: string(message)}
		body, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(cfg.Ctx, http.MethodPost, url, bytes.NewBuffer(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("x-api-key", rbx.APIKey)
		resp, err := cfg.Client.Do(req)
		if err != nil {
			return err
		}
		status := resp.StatusCode
		resp.Body.Close()
		if status != http.StatusOK {
			return errors.New(fmt.Sprintf("roblox api returned status code %d", status))
		}
	}
	return nil
}
