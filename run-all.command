#!/bin/zsh
# Baut und startet erst CouchHost (Mac), dann CouchRemote (iPhone). Per Doppelklick ausführbar.
cd "$(dirname "$0")"
./run-host.command && ./run-iphone.command
