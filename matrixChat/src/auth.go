package main

import (
	"context"
	"errors"
	"fmt"

	"maunium.net/go/mautrix"
)

// signIn exchanges a password for an access token.
//
// Shared by the settings form and the terminal helper, so both produce exactly
// the same session and there is only one place where a credential is handled.
// The password is used here and nowhere else: it is not returned, not stored and
// not logged.
func signIn(ctx context.Context, homeserver, user, password string) (*session, error) {
	client, err := mautrix.NewClient(homeserver, "", "")
	if err != nil {
		return nil, fmt.Errorf("that homeserver address is not usable: %w", err)
	}

	resp, err := client.Login(ctx, &mautrix.ReqLogin{
		Type: mautrix.AuthTypePassword,
		Identifier: mautrix.UserIdentifier{
			Type: mautrix.IdentifierTypeUser,
			User: user,
		},
		Password:                 password,
		InitialDeviceDisplayName: "DankMaterialShell",
		// Follow the homeserver's own advice about where its API lives: the URL
		// people know is often not the one a client should talk to.
		StoreHomeserverURL: true,
		StoreCredentials:   true,
	})
	if err != nil {
		return nil, err
	}

	pickleKey, err := newPickleKey()
	if err != nil {
		return nil, err
	}

	// The homeserver may have redirected us elsewhere via .well-known, and the
	// address it named is the one to keep.
	hsURL := homeserver
	if client.HomeserverURL != nil {
		hsURL = client.HomeserverURL.String()
	}

	return &session{
		HomeserverURL: hsURL,
		UserID:        string(resp.UserID),
		DeviceID:      string(resp.DeviceID),
		AccessToken:   resp.AccessToken,
		PickleKey:     pickleKey,
	}, nil
}

// loginErrorMessage turns a failure into something worth showing a person.
//
// The homeserver's own wording is the useful part -- "Invalid password" rather
// than a wrapped transport error -- because this string is what appears under
// the sign-in form.
func loginErrorMessage(err error) string {
	if err == nil {
		return ""
	}

	var httpErr mautrix.HTTPError
	if errors.As(err, &httpErr) && httpErr.RespError != nil {
		if msg := httpErr.RespError.Err; msg != "" {
			return msg
		}
		switch httpErr.RespError.ErrCode {
		case "M_FORBIDDEN":
			return "That user id or password was not accepted."
		case "M_USER_DEACTIVATED":
			return "That account has been deactivated."
		case "M_LIMIT_EXCEEDED":
			return "Too many attempts. Wait a moment and try again."
		}
	}
	return err.Error()
}
