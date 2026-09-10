package models

import (
	"encoding/json"
	"net"
	"reflect"

	"dmschatmanager/internal/log"
	"github.com/AvengeMedia/dankgo/ipc"
	"github.com/AvengeMedia/dankgo/ipc/params"
)

type Conn = ipc.ConnWriter

func NewConn(c net.Conn) *Conn { return ipc.NewConnWriter(c) }

type Request struct {
	ID     int            `json:"id,omitempty"`
	Method string         `json:"method"`
	Params map[string]any `json:"params,omitempty"`
}

func Get[T any](r Request, key string) (T, bool) {
	if v, err := params.Get[T](r.Params, key); err == nil {
		return v, true
	}

	// JSON has one number type, so every number arrives as a float64 and a
	// plain assertion to int fails. Left unhandled, every numeric parameter
	// silently falls back to its default: "limit" would ignore what the caller
	// asked for, and the "before" cursor would reset to zero, so paging back
	// through a conversation would keep returning the newest page.
	return asNumber[T](r.Params[key])
}

func GetOr[T any](r Request, key string, def T) T {
	if v, ok := Get[T](r, key); ok {
		return v
	}
	return def
}

// asNumber converts a JSON number to whatever numeric type was asked for.
func asNumber[T any](raw any) (T, bool) {
	var out T

	f, ok := toFloat(raw)
	if !ok {
		return out, false
	}

	v := reflect.ValueOf(&out).Elem()
	switch v.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		v.SetInt(int64(f))
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		if f < 0 {
			return out, false
		}
		v.SetUint(uint64(f))
	case reflect.Float32, reflect.Float64:
		v.SetFloat(f)
	default:
		return out, false
	}
	return out, true
}

func toFloat(raw any) (float64, bool) {
	switch n := raw.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int32:
		return float64(n), true
	case int64:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

type Response[T any] struct {
	ID     int    `json:"id,omitempty"`
	Result *T     `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

func RespondError(conn *Conn, id int, errMsg string) {
	log.Errorf("DMS API Error: id=%d error=%s", id, errMsg)
	_ = conn.WriteResponse(Response[any]{ID: id, Error: errMsg})
}

func Respond[T any](conn *Conn, id int, result T) {
	_ = conn.WriteResponse(Response[T]{ID: id, Result: &result})
}

type SuccessResult struct {
	Success bool   `json:"success"`
	Message string `json:"message,omitempty"`
	Value   string `json:"value,omitempty"`
}
