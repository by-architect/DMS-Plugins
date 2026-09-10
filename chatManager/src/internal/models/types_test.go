package models

import "testing"

// JSON has one number type, so a request's numbers arrive as float64. Asserting
// them straight to int fails, which used to make every numeric parameter fall
// back to its default: "limit" ignored what the caller asked for, and the
// "before" cursor reset to zero so paging never moved past the newest page.
func TestNumbersArriveAsFloats(t *testing.T) {
	req := Request{Params: map[string]any{
		"limit":  float64(5000),
		"before": float64(1789046341745),
	}}

	if got := GetOr(req, "limit", 200); got != 5000 {
		t.Errorf("limit = %d, want 5000", got)
	}

	before, ok := Get[int64](req, "before")
	if !ok {
		t.Fatal("before was not read")
	}
	if before != 1789046341745 {
		t.Errorf("before = %d, want the timestamp unchanged", before)
	}
}

func TestDefaultsWhenAbsentOrWrongType(t *testing.T) {
	req := Request{Params: map[string]any{"limit": "not a number"}}

	if got := GetOr(req, "limit", 200); got != 200 {
		t.Errorf("a non-numeric limit should fall back, got %d", got)
	}
	if got := GetOr(req, "missing", 42); got != 42 {
		t.Errorf("an absent key should fall back, got %d", got)
	}
}

func TestNonNumericParametersStillWork(t *testing.T) {
	req := Request{Params: map[string]any{"provider": "matrixChat", "all": true}}

	if got, ok := Get[string](req, "provider"); !ok || got != "matrixChat" {
		t.Errorf("provider = %q ok=%v", got, ok)
	}
	if got := GetOr(req, "all", false); !got {
		t.Error("all should be true")
	}
}

// A negative value must not wrap around into a huge unsigned number.
func TestNegativeIntoUnsignedIsRejected(t *testing.T) {
	req := Request{Params: map[string]any{"n": float64(-1)}}

	if got := GetOr(req, "n", uint64(7)); got != 7 {
		t.Errorf("negative into uint should fall back, got %d", got)
	}
}
