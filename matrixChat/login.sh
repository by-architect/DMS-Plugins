#!/usr/bin/env bash
# Sign in to Matrix.
#
# Run this once, from a terminal. It asks for your homeserver, user id and
# password, exchanges them for an access token, and stores only the token.
#
# The password is never written anywhere. This is a script rather than a box in
# the shell's settings because plugin settings are ordinary config: readable by
# anything that can read your home directory, and not a place for a credential.
set -euo pipefail

cd "$(dirname "$0")"

BRIDGE="./bin/matrix-chat-bridge"

if [ ! -x "$BRIDGE" ]; then
    echo "error: the bridge is not built yet." >&2
    echo "Run ./build.sh first." >&2
    exit 1
fi

exec "$BRIDGE" -login
