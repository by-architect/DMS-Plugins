#!/usr/bin/env bash
# Builds the chat manager daemon.
#
# CGO is off so the binary runs on whatever the user has: the SQLite driver is
# pure Go for exactly this reason.
set -euo pipefail

cd "$(dirname "$0")/src"
echo "building the chat manager..."
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o ../bin/chat-managerd .
echo "built: $(cd .. && pwd)/bin/chat-managerd"
