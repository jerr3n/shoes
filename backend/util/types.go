package util

import (
	"context"
	"errors"
	"net/http"
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
	Path               string    `json:"path"`
	CreateTime         time.Time `json:"createTime"`
	RevisionId         string    `json:"revisionId"`
	RevisionCreateTime time.Time `json:"revisionCreateTime"`
	State              string    `json:"state"`
	Etag               string    `json:"etag"`
	Value              string    `json:"value"`
	Id                 string    `json:"id"`
	Attributes         struct {
	} `json:"attributes"`
}

type MessageServiceRequest struct {
	Topic   string `json:"topic"`
	Message string `json:"message"`
}

var ErrorTooMuchTime = errors.New("over 60s")
var ErrorJobIdNotFound = errors.New("jobid not found")
var ErrorMeta = errors.New("unknown error")
