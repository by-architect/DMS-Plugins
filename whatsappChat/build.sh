#!/usr/bin/env bash
# Build the WhatsApp bridge.
#
# The bridge is a Go program and has to be compiled for the machine it runs on,
# so it is not shipped prebuilt. Run this once after installing the plugin, and
# again after updating it.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
    echo "error: Go is required to build the WhatsApp bridge." >&2
    echo "Install Go, then run this script again." >&2
    exit 1
fi

mkdir -p bin
echo "building the WhatsApp bridge (this may take a minute the first time)..."
(cd src && go build -trimpath -o ../bin/whatsapp-chat-bridge .)

echo "built: $(pwd)/bin/whatsapp-chat-bridge"
echo
echo "Now enable WhatsApp Chat (and Chat Manager) under Settings -> Plugins, open the"
echo "chat window, and scan the QR code it shows with WhatsApp on your phone"
echo "(Settings -> Linked devices -> Link a device)."
