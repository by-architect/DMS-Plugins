package models

import (
	"net"

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
	v, err := params.Get[T](r.Params, key)
	return v, err == nil
}

func GetOr[T any](r Request, key string, def T) T {
	return params.GetOpt(r.Params, key, def)
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
