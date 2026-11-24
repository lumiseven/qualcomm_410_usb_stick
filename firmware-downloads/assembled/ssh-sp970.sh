#!/bin/sh
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$DIR/known_hosts" -i "$DIR/sp970_ed25519" user@192.168.5.1 "$@"
