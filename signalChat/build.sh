#!/usr/bin/env bash
# Build the Signal bridge.
#
# The bridge is a Go program and has to be compiled for the machine it runs on,
# so it is not shipped prebuilt. Run this once after installing the plugin, and
# again after updating it.
#
# It has no Go dependencies to download: Signal itself is reached through
# signal-cli, which the bridge runs as a child process.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
    echo "error: Go is required to build the Signal bridge." >&2
    echo "Install Go, then run this script again." >&2
    exit 1
fi

mkdir -p bin
echo "building the Signal bridge..."
(cd src && go build -trimpath -o ../bin/signal-chat-bridge .)

echo "built: $(pwd)/bin/signal-chat-bridge"

if ! command -v signal-cli >/dev/null 2>&1; then
    echo
    echo "warning: signal-cli was not found on PATH." >&2
    echo "The bridge drives signal-cli to reach Signal, and will not connect" >&2
    echo "without it. Install it from https://github.com/AsamK/signal-cli" >&2
    exit 0
fi

echo "signal-cli: $(command -v signal-cli) ($(signal-cli --version 2>/dev/null || echo 'version unknown'))"
echo
echo "Now enable Signal under Settings -> Chats, and scan the QR code with"
echo "Signal on your phone (Settings -> Linked devices -> Link New Device)."
