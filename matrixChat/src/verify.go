package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"maunium.net/go/mautrix/crypto"
	"maunium.net/go/mautrix/crypto/backup"
	"maunium.net/go/mautrix/crypto/ssss"
	"maunium.net/go/mautrix/event"
)

// Verifying this device with the account's recovery key.
//
// Signing in creates a new device, and a new device holds no keys to anything
// sent before it existed. The usual remedy is to accept a prompt on a device
// already signed in -- but that needs a second device, and someone signing in on
// their only machine has none. Element shows "start verification on the other
// device" and there is no other device.
//
// The recovery key is the other half of the same design. It unlocks secret
// storage on the homeserver, which holds two things worth having: the
// cross-signing keys that let this device prove it is genuinely ours, and the
// megolm backup key that decrypts the history.

func (b *bridge) handleVerify(ctx context.Context, c call) {
	var params struct {
		RecoveryKey string `json:"recoveryKey"`
	}
	if err := json.Unmarshal(c.Params, &params); err != nil {
		fail(c.ID, "bad_params", "could not read the recovery key")
		return
	}

	// Password managers wrap and pad; the key itself is base58 and has no
	// whitespace in it, so collapsing everything is safe and saves a user from
	// an invalid-key error caused by a stray newline.
	secret := strings.Join(strings.Fields(params.RecoveryKey), " ")
	if secret == "" {
		fail(c.ID, "bad_params", "a recovery key is required")
		return
	}

	b.mu.RLock()
	helper := b.crypto
	b.mu.RUnlock()

	if helper == nil {
		fail(c.ID, "no_encryption", "encryption is not available on this device, so there is nothing to verify")
		return
	}

	mach := helper.Machine()
	if mach == nil {
		fail(c.ID, "no_encryption", "the encryption store is not ready yet; try again in a moment")
		return
	}

	restored, err := b.verifyWithSecret(ctx, mach, secret)
	if err != nil {
		fail(c.ID, "verify_failed", "%s", err.Error())
		return
	}

	ok(c.ID, map[string]any{"restoredBackup": restored})

	if restored {
		logf("info", "this device is verified, and its room keys were restored from backup")
	} else {
		// Verification still succeeded; there was simply no key backup to pull
		// from, which is normal on an account that never turned one on.
		logf("info", "this device is verified. No key backup was available, so older encrypted messages stay unreadable.")
	}

	emitEvent("auth", map[string]any{"method": "verified"})
}

// verifyWithSecret unlocks secret storage and puts this device in good standing.
//
// Reports whether the key backup came back too, which is what the user actually
// cares about: it is the difference between a verified device and a readable
// history.
func (b *bridge) verifyWithSecret(ctx context.Context, mach *crypto.OlmMachine, secret string) (bool, error) {
	keyID, keyData, err := mach.SSSS.GetDefaultKeyData(ctx)
	if err != nil {
		// Almost always means secure backup was never turned on, rather than a
		// transport failure, and that is a thing the user must do elsewhere.
		return false, fmt.Errorf("this account has no secure backup set up. Turn on Secure Backup in another Matrix client first, then come back with the recovery key it gives you")
	}

	key, err := resolveSSSSKey(keyID, keyData, secret)
	if err != nil {
		return false, err
	}

	// The cross-signing keys: what lets this device prove it is ours, so other
	// people's clients stop flagging it as unverified.
	if err := mach.FetchCrossSigningKeysFromSSSS(ctx, key); err != nil {
		return false, fmt.Errorf("the recovery key was accepted, but the cross-signing keys could not be read: %w", err)
	}
	if err := mach.SignOwnDevice(ctx, mach.OwnIdentity()); err != nil {
		return false, fmt.Errorf("could not sign this device: %w", err)
	}
	if err := mach.SignOwnMasterKey(ctx); err != nil {
		return false, fmt.Errorf("could not sign the account's master key: %w", err)
	}

	// History. Separate from verification and allowed to fail on its own: the
	// device is already verified by this point, and reporting a total failure
	// would send the user back to re-enter a key that worked.
	restored, err := b.restoreKeyBackup(ctx, mach, key)
	if err != nil {
		logf("warn", "verified, but the key backup could not be restored: %v", err)
		return false, nil
	}
	return restored, nil
}

// resolveSSSSKey accepts either form of the secret.
//
// Matrix lets secret storage be unlocked by a 48-character base58 recovery key
// or by the passphrase it was created from. Users rarely know which one they
// have, so both are tried rather than asked about.
func resolveSSSSKey(keyID string, keyData *ssss.KeyMetadata, secret string) (*ssss.Key, error) {
	key, err := keyData.VerifyRecoveryKey(keyID, secret)
	if err == nil || errors.Is(err, ssss.ErrUnverifiableKey) {
		// An unverifiable key has no stored check value to compare against.
		// mautrix itself proceeds here; a wrong key fails at decryption instead.
		return key, nil
	}

	passphraseKey, passphraseErr := keyData.VerifyPassphrase(keyID, secret)
	if passphraseErr == nil || errors.Is(passphraseErr, ssss.ErrUnverifiableKey) {
		return passphraseKey, nil
	}

	// Report against whichever the input looked like, so the message matches
	// what the user believes they typed.
	if looksLikeRecoveryKey(secret) {
		return nil, fmt.Errorf("that recovery key was not accepted. Check it was copied in full")
	}
	return nil, fmt.Errorf("that recovery key or passphrase was not accepted")
}

// looksLikeRecoveryKey distinguishes the two forms well enough to word an error.
//
// A recovery key is base58 in groups of four; a passphrase is prose. This only
// picks the wording of a failure, so a wrong guess costs nothing.
func looksLikeRecoveryKey(secret string) bool {
	compact := strings.ReplaceAll(secret, " ", "")
	if len(compact) < 40 {
		return false
	}
	for _, r := range compact {
		isBase58 := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '1' && r <= '9')
		if !isBase58 {
			return false
		}
	}
	return true
}

// restoreKeyBackup pulls the account's room keys down from the homeserver.
//
// This is what actually makes old messages readable: the cross-signing above
// only establishes that the device is trusted.
func (b *bridge) restoreKeyBackup(ctx context.Context, mach *crypto.OlmMachine, key *ssss.Key) (bool, error) {
	raw, err := mach.SSSS.GetDecryptedAccountData(ctx, event.AccountDataMegolmBackupKey, key)
	if err != nil {
		return false, fmt.Errorf("read the backup key: %w", err)
	}

	backupKey, err := backup.MegolmBackupKeyFromBytes(raw)
	if err != nil {
		return false, fmt.Errorf("the stored backup key is not usable: %w", err)
	}

	version, err := mach.DownloadAndStoreLatestKeyBackup(ctx, backupKey)
	if err != nil {
		return false, fmt.Errorf("download the key backup: %w", err)
	}
	if version == "" {
		return false, nil
	}

	logf("info", "restored room keys from backup version %s", version)
	return true, nil
}
