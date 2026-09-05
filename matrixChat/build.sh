#!/usr/bin/env bash
# Build the Matrix bridge.
#
# The bridge is a Go program and has to be compiled for the machine it runs on,
# so it is not shipped prebuilt. Run this once after installing the plugin, and
# again after updating it.
#
# Two build settings are load-bearing:
#
#   -tags goolm     use the pure-Go olm implementation instead of linking the
#                   libolm C library, so end-to-end encryption works without
#                   anything installed system-wide
#   CGO_ENABLED=0   keep the whole binary cgo-free; the encryption store is
#                   SQLite through modernc's pure-Go driver
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
    echo "error: Go is required to build the Matrix bridge." >&2
    echo "Install Go, then run this script again." >&2
    exit 1
fi

mkdir -p bin
echo "building the Matrix bridge (this may take a minute the first time)..."
(cd src && CGO_ENABLED=0 go build -tags goolm -trimpath -o ../bin/matrix-chat-bridge .)

echo "built: $(pwd)/bin/matrix-chat-bridge"
echo
echo "Now run ./login.sh to sign in, then enable Matrix under Settings -> Chats."
