package util

import "errors"

var ErrorTooMuchTime = errors.New("over 60s")
var ErrorJobIdNotFound = errors.New("jobid not found")
var ErrorMeta = errors.New("unknown error")
