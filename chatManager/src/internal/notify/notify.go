package notify

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/godbus/dbus/v5"
)

const (
	notifyDest      = "org.freedesktop.Notifications"
	notifyPath      = "/org/freedesktop/Notifications"
	notifyInterface = "org.freedesktop.Notifications"

	// A guard against a pasted novel going onto the bus, not a decision about
	// what fits on screen. How much of a notification is shown belongs to the
	// notification daemon: it is the one that knows how wide the screen is, and
	// whether the line can be expanded. Cutting at 29 and 80 here meant a group
	// name and a sentence were both stubs before anything could lay them out.
	maxSummaryRunes = 200
	maxBodyRunes    = 2000

	listenerMaxLifetime = time.Hour
)

// clip shortens a string on a character boundary.
//
// Slicing a Go string slices bytes, and every character outside ASCII is more
// than one of them -- so the obvious version cuts "DOĞA SPORLARI TOPLULUĞU" in
// the middle of a Ğ and puts half a character on the bus. Nothing sent through
// a chat reaches this length anyway; it exists so that something pasted can't.
func clip(value string, limit int) string {
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	return strings.TrimRight(string([]rune(value)[:limit-1]), " ") + "…"
}

type Notification struct {
	AppName  string
	Icon     string
	Summary  string
	Body     string
	FilePath string
	Timeout  int32

	// Actions are key and label pairs offered on the notification. "default"
	// is the one a notification server invokes when the notification itself
	// is clicked. Left empty, a notification carrying a file offers to open
	// it and its folder -- which only does anything while somebody is
	// listening for the answer, see Listen.
	Actions []string
}

func Send(n Notification) (uint32, error) {
	conn, err := dbus.SessionBus()
	if err != nil {
		return 0, fmt.Errorf("dbus session failed: %w", err)
	}

	if n.AppName == "" {
		n.AppName = "DMS"
	}
	if n.Timeout == 0 {
		n.Timeout = 5000
	}

	n.Summary = clip(n.Summary, maxSummaryRunes)
	n.Body = clip(n.Body, maxBodyRunes)

	actions := n.Actions
	if actions == nil && n.FilePath != "" {
		actions = []string{
			"open", "Open",
			"folder", "Open Folder",
		}
	}

	hints := map[string]dbus.Variant{}
	if n.FilePath != "" {
		imgPath := n.FilePath
		if !strings.HasPrefix(imgPath, "file://") {
			imgPath = "file://" + imgPath
		}
		hints["image_path"] = dbus.MakeVariant(imgPath)
	}

	obj := conn.Object(notifyDest, notifyPath)
	call := obj.Call(
		notifyInterface+".Notify",
		0,
		n.AppName,
		uint32(0),
		n.Icon,
		n.Summary,
		n.Body,
		actions,
		hints,
		n.Timeout,
	)

	if call.Err != nil {
		return 0, fmt.Errorf("notify call failed: %w", call.Err)
	}

	var notificationID uint32
	if err := call.Store(&notificationID); err != nil {
		return 0, fmt.Errorf("failed to get notification id: %w", err)
	}

	return notificationID, nil
}

// Listen reports what happens to notifications after they are shown, until ctx
// ends: onAction when one of a notification's actions is invoked -- "default"
// for a click on the notification itself -- and onClosed when it goes away.
//
// A notification's actions are only an offer. The server answers on the bus,
// and without somebody listening a button does nothing at all, which is what
// chat's "Open" buttons did.
func Listen(ctx context.Context, onAction func(id uint32, action string), onClosed func(id uint32)) error {
	conn, err := dbus.SessionBus()
	if err != nil {
		return fmt.Errorf("dbus session failed: %w", err)
	}

	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(notifyPath),
		dbus.WithMatchInterface(notifyInterface),
	); err != nil {
		return fmt.Errorf("watch notifications: %w", err)
	}

	signals := make(chan *dbus.Signal, 32)
	conn.Signal(signals)
	defer conn.RemoveSignal(signals)

	for {
		select {
		case <-ctx.Done():
			return nil
		case sig, ok := <-signals:
			if !ok {
				return nil
			}
			if sig == nil || sig.Path != notifyPath || len(sig.Body) < 1 {
				continue
			}
			id, ok := sig.Body[0].(uint32)
			if !ok {
				continue
			}
			switch sig.Name {
			case notifyInterface + ".ActionInvoked":
				if len(sig.Body) < 2 {
					continue
				}
				if action, ok := sig.Body[1].(string); ok && onAction != nil {
					onAction(id, action)
				}
			case notifyInterface + ".NotificationClosed":
				if onClosed != nil {
					onClosed(id)
				}
			}
		}
	}
}

// OpenPath hands a file or directory to the desktop's opener, detached, so it
// outlives whoever asked.
func OpenPath(path string) {
	openPath(path)
}

func SpawnActionListener(notificationID uint32, filePath string) {
	exe, err := os.Executable()
	if err != nil {
		return
	}

	cmd := exec.Command(exe, "notify-action-generic", fmt.Sprintf("%d", notificationID), filePath)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid: true,
	}
	cmd.Start()
}

func RunActionListener(args []string) {
	if len(args) < 2 {
		return
	}

	notificationID, err := strconv.ParseUint(args[0], 10, 32)
	if err != nil {
		return
	}

	filePath := args[1]

	conn, err := dbus.SessionBus()
	if err != nil {
		return
	}

	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(notifyPath),
		dbus.WithMatchInterface(notifyInterface),
	); err != nil {
		return
	}

	signals := make(chan *dbus.Signal, 10)
	conn.Signal(signals)
	deadline := time.After(listenerMaxLifetime)

	for {
		select {
		case <-deadline:
			return
		case sig := <-signals:
			if sig == nil || handleSignal(sig, uint32(notificationID), filePath) {
				return
			}
		}
	}
}

func handleSignal(sig *dbus.Signal, notificationID uint32, filePath string) bool {
	if len(sig.Body) < 1 {
		return false
	}
	id, ok := sig.Body[0].(uint32)
	if !ok || id != notificationID {
		return false
	}
	switch sig.Name {
	case notifyInterface + ".NotificationClosed":
		return true
	case notifyInterface + ".ActionInvoked":
		if len(sig.Body) < 2 {
			return false
		}
		action, ok := sig.Body[1].(string)
		if !ok {
			return false
		}
		handleAction(action, filePath)
		return true
	}
	return false
}

func handleAction(action, filePath string) {
	switch action {
	case "open", "default":
		openPath(filePath)
	case "folder":
		openPath(filepath.Dir(filePath))
	}
}

func openPath(path string) {
	cmd := exec.Command("xdg-open", path)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setsid: true,
	}
	if err := cmd.Start(); err != nil {
		return
	}
	// Reaped, so a caller that runs for days does not collect a defunct
	// process per click.
	go cmd.Wait()
}
