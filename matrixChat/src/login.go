package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"
)

// The interactive sign-in helper, run from a terminal rather than from the
// shell.
//
// Matrix signs in with a password, and a password has no place in the shell's
// settings file -- it is world-readable config, not a credential store. So it is
// asked for here, exchanged for an access token immediately, and never written
// anywhere. Only the token is kept, in a file readable by its owner alone.
//
// This is also why the sign-in panel in Settings has nothing to show: there is
// no QR code to render, and the honest alternative to a helper would be a
// password box in the shell.
func runLogin() {
	in := bufio.NewReader(os.Stdin)

	fmt.Println("Sign in to Matrix")
	fmt.Println()

	existing, _ := loadSession()
	if existing.valid() {
		fmt.Printf("Already signed in as %s on %s.\n", existing.UserID, existing.HomeserverURL)
		if !confirm(in, "Replace that session?") {
			fmt.Println("Left the existing session alone.")
			return
		}
	}

	homeserver := ask(in, "Homeserver URL", "https://matrix.org")
	if !strings.Contains(homeserver, "://") {
		// A bare hostname is what people type; assume the safe scheme rather
		// than failing with a URL parse error.
		homeserver = "https://" + homeserver
	}

	user := ask(in, "User ID (e.g. @you:example.org, or just 'you')", "")
	if user == "" {
		fmt.Fprintln(os.Stderr, "error: a user id is required")
		os.Exit(1)
	}

	password, err := askSecret(in, "Password: ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: could not read the password: %v\n", err)
		os.Exit(1)
	}
	if password == "" {
		fmt.Fprintln(os.Stderr, "error: a password is required")
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("Signing in...")

	sess, err := signIn(context.Background(), homeserver, user, password)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: sign-in failed: %s\n", loginErrorMessage(err))
		os.Exit(1)
	}

	// A new device means new encryption keys, so any store from a previous
	// session is stale and would only produce undecryptable messages.
	_ = clearSession()

	if err := saveSession(sess); err != nil {
		fmt.Fprintf(os.Stderr, "error: could not save the session: %v\n", err)
		os.Exit(1)
	}

	path, _ := sessionPath()
	fmt.Println()
	fmt.Printf("Signed in as %s\n", sess.UserID)
	fmt.Printf("Device:  %s\n", sess.DeviceID)
	fmt.Printf("Session: %s\n", path)
	fmt.Println()
	fmt.Println("Now enable Matrix under Settings -> Chats.")
	fmt.Println()
	fmt.Println("This device is new, so it cannot read messages sent before now.")
	fmt.Println("To read encrypted history, verify it from another signed-in")
	fmt.Println("client (Element: Settings -> Security -> verify this device).")

}

func ask(in *bufio.Reader, prompt, fallback string) string {
	if fallback != "" {
		fmt.Printf("%s [%s]: ", prompt, fallback)
	} else {
		fmt.Printf("%s: ", prompt)
	}

	line, err := in.ReadString('\n')
	if err != nil && line == "" {
		return fallback
	}

	line = strings.TrimSpace(line)
	if line == "" {
		return fallback
	}
	return line
}

func confirm(in *bufio.Reader, prompt string) bool {
	answer := strings.ToLower(ask(in, prompt+" [y/N]", "n"))
	return answer == "y" || answer == "yes"
}

// askSecret reads without echoing, so the password does not end up on screen or
// in the terminal's scrollback.
//
// Takes the same reader the other prompts used. Opening a second one over stdin
// loses whatever the first had already buffered, which for piped input is the
// password itself.
func askSecret(in *bufio.Reader, prompt string) (string, error) {
	fmt.Print(prompt)
	defer fmt.Println()

	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) {
		// Piped input: read it plainly rather than refusing, so the helper can
		// be scripted.
		line, err := in.ReadString('\n')
		if err != nil && line == "" {
			return "", err
		}
		return strings.TrimSpace(line), nil
	}

	raw, err := term.ReadPassword(fd)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(raw)), nil
}
