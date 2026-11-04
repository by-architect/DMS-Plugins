package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/id"
)

// Pictures: rooms', and people's.
//
// Every Matrix conversation used to show the first letter of its name. A room's
// picture is its m.room.avatar; a direct chat with none takes the other
// person's, which is what Element shows; and a sender's is their picture in
// that room, which is per room in Matrix like a display name.
//
// Each is fetched once, as a small thumbnail, from the account's own homeserver,
// into an avatars folder in the media directory the host gave this bridge, and
// named after its content address: two rooms with one picture share a file, and
// a changed picture is a new one. The host counts these files as in use, so its
// cache sweep leaves them alone.
//
// In the background, always. A conversation is never held up for a picture; it
// is republished once it has one, and a message carries its sender's from then
// on.

const (
	avatarSize       = 96
	avatarMaxBytes   = 2 << 20
	avatarWorkers    = 2
	avatarQueueDepth = 256

	// avatarRetryAfter is how long a picture that would not download is left
	// before it is tried again, rather than asked for on every republish.
	avatarRetryAfter = time.Hour
)

// avatarFetcher is the background queue pictures are fetched from.
type avatarFetcher struct {
	mu   sync.Mutex
	once sync.Once
	jobs chan avatarJob

	// pending is the pictures being fetched, and what to do once each is
	// here; failed is when each picture last could not be fetched.
	pending map[id.ContentURI][]func()
	failed  map[id.ContentURI]time.Time
}

type avatarJob struct {
	uri  id.ContentURI
	path string
}

// avatarPath is where a picture is kept once fetched, or "" when there is
// nowhere to keep it.
func (b *bridge) avatarPath(uri id.ContentURI) string {
	if uri.IsEmpty() {
		return ""
	}
	b.mu.RLock()
	dir := b.mediaDir
	b.mu.RUnlock()
	if dir == "" {
		return ""
	}
	return filepath.Join(dir, "avatars", safeName(uri.Homeserver)+"_"+safeName(uri.FileID))
}

// safeName makes part of a content address safe as a file name. Media ids are
// plain letters and digits, but they come from other servers, and a separator
// or a leading dot in one must not reach outside the folder.
func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == 0 {
			return '_'
		}
		return r
	}, strings.TrimLeft(s, "."))
}

// avatarFor is a picture's local path once it has been fetched. Until then it
// is asked for, and onReady runs when it has arrived; the caller carries on
// without it meanwhile.
func (b *bridge) avatarFor(uri id.ContentURI, onReady func()) string {
	if uri.IsEmpty() || !b.settingBool("showAvatars", true) {
		return ""
	}
	path := b.avatarPath(uri)
	if path == "" {
		return ""
	}
	if info, err := os.Stat(path); err == nil && info.Size() > 0 {
		return path
	}
	b.queueAvatar(avatarJob{uri: uri, path: path}, onReady)
	return ""
}

// roomAvatar is the picture a room is shown with, fetching it if need be and
// republishing the room once it is here.
func (b *bridge) roomAvatar(roomID id.RoomID) string {
	b.mu.RLock()
	var uri id.ContentURI
	if info := b.rooms[roomID]; info != nil {
		uri = info.AvatarURL
		// A direct chat with no picture of its own looks like the person in it.
		if uri.IsEmpty() && info.IsDirect {
			self := b.selfIDLocked()
			var other id.UserID
			others := 0
			for member := range info.Members {
				if member != self {
					other = member
					others++
				}
			}
			if others == 1 {
				uri = info.MemberAvatars[other]
			}
		}
	}
	b.mu.RUnlock()

	return b.avatarFor(uri, func() { b.touchRoom(roomID) })
}

// senderAvatar is someone's picture in a room, if it has been fetched; it is
// asked for if it has not, for the messages they send after it arrives.
func (b *bridge) senderAvatar(roomID id.RoomID, user id.UserID) string {
	b.mu.RLock()
	var uri id.ContentURI
	if info := b.rooms[roomID]; info != nil {
		uri = info.MemberAvatars[user]
	}
	b.mu.RUnlock()

	return b.avatarFor(uri, nil)
}

func (b *bridge) queueAvatar(job avatarJob, onReady func()) {
	f := &b.avatars

	f.mu.Lock()
	if when, failed := f.failed[job.uri]; failed && time.Since(when) < avatarRetryAfter {
		f.mu.Unlock()
		return
	}
	if f.pending == nil {
		f.pending = map[id.ContentURI][]func(){}
	}
	waiting, inFlight := f.pending[job.uri]
	if onReady != nil {
		waiting = append(waiting, onReady)
	}
	f.pending[job.uri] = waiting
	f.mu.Unlock()

	if inFlight {
		return
	}

	f.once.Do(func() {
		f.jobs = make(chan avatarJob, avatarQueueDepth)
		for range avatarWorkers {
			go func() {
				for queued := range f.jobs {
					b.fetchAvatar(queued)
				}
			}()
		}
	})

	select {
	case f.jobs <- job:
	default:
		// More at once than is worth queueing: a first sync of a big account.
		// Asked for again the next time it is wanted.
		f.mu.Lock()
		delete(f.pending, job.uri)
		f.mu.Unlock()
	}
}

func (b *bridge) fetchAvatar(job avatarJob) {
	err := b.downloadAvatar(job)

	f := &b.avatars
	f.mu.Lock()
	callbacks := f.pending[job.uri]
	delete(f.pending, job.uri)
	if err != nil {
		if f.failed == nil {
			f.failed = map[id.ContentURI]time.Time{}
		}
		f.failed[job.uri] = time.Now()
	}
	f.mu.Unlock()

	if err != nil {
		logf("debug", "could not fetch a picture: %v", err)
		return
	}
	for _, fn := range callbacks {
		fn()
	}
}

// downloadAvatar fetches a thumbnail and writes it into place, through a
// temporary file the host's cache sweep knows to leave alone.
func (b *bridge) downloadAvatar(job avatarJob) error {
	client := b.getClient()
	if client == nil {
		return errors.New("Matrix is not connected")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	resp, err := client.DownloadThumbnail(ctx, job.uri, avatarSize, avatarSize, mautrix.DownloadThumbnailExtra{Method: "crop"})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return savePicture(job.path, resp.Body)
}

func savePicture(path string, body io.Reader) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".incoming-avatar-*")
	if err != nil {
		return err
	}

	n, err := io.Copy(tmp, io.LimitReader(body, avatarMaxBytes+1))
	if err == nil && n > avatarMaxBytes {
		err = fmt.Errorf("the picture is larger than %d bytes", avatarMaxBytes)
	}
	if err == nil && n == 0 {
		err = errors.New("the homeserver sent an empty picture")
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return nil
}
