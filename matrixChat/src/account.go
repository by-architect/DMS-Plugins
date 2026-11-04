package main

import (
	"context"
	"time"
)

// The account, as the plugin's settings page shows it.
//
// The page had nothing to say about the account: not who was signed in, not
// whether this device had been verified -- the one thing that decides whether
// encrypted history can be read -- and no way to sign out at all. The host
// relays this to that page untouched; nothing else reads it.

// emitAccount describes the account this device is signed in to, or says that
// it is signed in to none.
func (b *bridge) emitAccount() {
	b.mu.RLock()
	sess, helper, waiting := b.sess, b.crypto, b.waiting
	b.mu.RUnlock()

	if sess == nil {
		emitEvent("account", map[string]any{"account": nil})
		return
	}

	account := map[string]any{
		"userId":     sess.UserID,
		"deviceId":   sess.DeviceID,
		"homeserver": sess.HomeserverURL,
		"encryption": helper != nil,
	}
	if helper != nil {
		if mach := helper.Machine(); mach != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			// Cross-signed is what verifying with the recovery key does, and
			// what other people's clients look for before trusting this one.
			account["verified"] = crossSigned(ctx, mach)
			// The backup key, kept once the recovery key has been entered, is
			// what lets keys the account's other devices back up later reach
			// this one.
			account["keyBackup"] = storedBackupKey(ctx, mach) != nil
		}
	}
	if waiting != nil {
		account["waitingForKeys"] = waiting.count()
	}
	emitEvent("account", map[string]any{"account": account})
}

// count is how many messages are waiting for their keys.
func (s *waitingStore) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.events)
}
