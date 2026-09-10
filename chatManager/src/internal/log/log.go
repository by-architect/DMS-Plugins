// Package log is the chat manager's logging, kept API-compatible with the DMS
// core logger the chat code was written against.
//
// The manager runs as its own process rather than inside the shell, so its
// output is a plain stderr stream that the shell captures. Levels are filtered
// by DMS_CHAT_LOG_LEVEL, defaulting to info, because a chat host at debug level
// narrates every message that passes through it.
package log

import (
	"fmt"
	"os"
	"strings"
	"sync/atomic"
)

type level int32

const (
	levelDebug level = iota
	levelInfo
	levelWarn
	levelError
)

var current atomic.Int32

func init() {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("DMS_CHAT_LOG_LEVEL"))) {
	case "debug":
		current.Store(int32(levelDebug))
	case "warn":
		current.Store(int32(levelWarn))
	case "error":
		current.Store(int32(levelError))
	default:
		current.Store(int32(levelInfo))
	}
}

func emit(l level, tag, format string, args ...any) {
	if l < level(current.Load()) {
		return
	}
	fmt.Fprintf(os.Stderr, "%s %s\n", tag, fmt.Sprintf(format, args...))
}

func Debugf(format string, args ...any) { emit(levelDebug, "DEBUG", format, args...) }
func Infof(format string, args ...any)  { emit(levelInfo, "INFO", format, args...) }
func Warnf(format string, args ...any)  { emit(levelWarn, "WARN", format, args...) }
func Errorf(format string, args ...any) { emit(levelError, "ERROR", format, args...) }

func Info(args ...any)  { emit(levelInfo, "INFO", "%s", fmt.Sprint(args...)) }
func Warn(args ...any)  { emit(levelWarn, "WARN", "%s", fmt.Sprint(args...)) }
func Error(args ...any) { emit(levelError, "ERROR", "%s", fmt.Sprint(args...)) }
