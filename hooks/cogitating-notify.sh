#!/bin/bash
# Generic "agent finished" notifier for any AI coding tool.
# Reads COGITATING_API + COGITATING_HOOK_TOKEN, ignores stdin/argv payload,
# POSTs to the API with a short timeout and ALWAYS exits 0 (never fails the agent).

COGITATING_API="${COGITATING_API:-https://cogitating-api.pb79e6spzzxx0.eu-north-1.cs.amazonlightsail.com}"
COGITATING_HOOK_TOKEN="${COGITATING_HOOK_TOKEN:-}"

if [ -n "$COGITATING_HOOK_TOKEN" ] && command -v curl >/dev/null 2>&1; then
  curl -sS -m 5 -X POST \
    "${COGITATING_API%/}/v1/hooks/agent-finished" \
    -H "Authorization: Bearer $COGITATING_HOOK_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{}' \
    >/dev/null 2>&1 </dev/null || true
fi

# Some tools (Gemini CLI, Cursor) expect a JSON object on stdout.
[ "${COGITATING_NOTIFY_JSON:-}" = "1" ] && echo '{}'
exit 0
