#!/bin/bash
# Dev check for a new hook version, with NO network and NO token needed: shows the requests it WOULD send.
#   bash hooks/check.sh                 check the repo version (hooks/claude-code.sh)
#   bash hooks/check.sh /path/to/hook   check another file, e.g. the one installed in ~/.claude
# Then it runs the compatibility suite (the golden requests of earlier versions must not change).
# To exercise the real installed hook once, use the app's "Settings -> agent hook" test or send one status by hand.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
export HOOK_SCRIPT="${1:-$DIR/hooks/claude-code.sh}"
export COGITATING_API="${COGITATING_API:-https://api.example.invalid}" COGITATING_HOOK_TOKEN="check-only-token" COGITATING_DRY_RUN=1
echo "Hook under test: $HOOK_SCRIPT"
for ev in SessionStart UserPromptSubmit Notification Stop SessionEnd; do
  printf '%-17s -> ' "$ev"
  printf '{"hook_event_name":"%s","session_id":"check-1","cwd":"%s","message":"check message"}' "$ev" "$PWD" | bash "$HOOK_SCRIPT"
done
echo
bash "$DIR/test/regression.sh"
