package util

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"
)

type HTTPConfig struct {
	Ctx    context.Context
	Client *http.Client
}

type RobloxAPIConfig struct {
	UniverseID string
	APIKey     string
}
type ResolvedEntry struct {
	Path               string          `json:"path"`
	CreateTime         time.Time       `json:"createTime"`
	RevisionId         string          `json:"revisionId"`
	RevisionCreateTime time.Time       `json:"revisionCreateTime"`
	State              string          `json:"state"`
	Etag               string          `json:"etag"`
	Value              json.RawMessage `json:"value"`
	Id                 string          `json:"id"`
	Attributes         struct {
	} `json:"attributes"`
}

// Timestamp reads the entry value as a unix timestamp. The Roblox side writes
// it with SetAsync(jobId, os.time()), so it arrives as a JSON number, but the
// quoted form is accepted too.
func (e ResolvedEntry) Timestamp() (int64, error) {
	raw := string(e.Value)
	if unquoted, err := strconv.Unquote(raw); err == nil {
		raw = unquoted
	}
	return strconv.ParseInt(raw, 10, 64)
}

type MessageServiceRequest struct {
	Topic   string `json:"topic"`
	Message string `json:"message"`
}

var ErrorTooMuchTime = errors.New("over 60s")
var ErrorJobIdNotFound = errors.New("jobid not found")
var ErrorMeta = errors.New("unknown error")

type APIKey struct {
	JobID  string `gorm:"primarykey"`
	APIKey string `gorm:"not null"`
}

type DataStorage struct {
	JobID string `gorm:"primarykey"`
	UUID  string `gorm:"primarykey"`
	Data  []byte `gorm:"not null"`
	Exp   int64  `gorm:"not null"`
}
