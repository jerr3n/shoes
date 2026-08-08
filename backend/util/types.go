package util

import "time"

type InitializationPostRequest struct {
	UniverseId int `json:"universe_id" binding:"required"`
	JobId      int `json:"job_id" binding:"required"`
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

type UnresolvedKey struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}
