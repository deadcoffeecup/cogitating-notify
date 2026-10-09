#!/bin/bash
# Claude Code hook for Cogitating (formerly claude-code-stop.sh).
# Reads the hook JSON from stdin (session_id, cwd, hook_event_name, message) and reports agent status:
#   SessionStart / UserPromptSubmit -> working     (POST /v1/hooks/agent-status)
#   Notification                    -> waiting     (message passed through)
#   Stop                            -> POST /v1/hooks/agent-finished (closes quiz session; push only if enabled in app) + status finished
#   SessionEnd                      -> finished    (POST /v1/hooks/agent-status)
# No/unknown event (old installs) behaves like the old script: agent-finished with an empty body.
# Never blocks, never prints, always exits 0.

set -u

COGITATING_API="${COGITATING_API:-https://cogitating-api.pb79e6spzzxx0.eu-north-1.cs.amazonlightsail.com}"
COGITATING_HOOK_TOKEN="${COGITATING_HOOK_TOKEN:-}"
TOOL="claude-code"

# Silent when token is not set.
if [ -z "$COGITATING_HOOK_TOKEN" ]; then
  exit 0
fi

INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(cat 2>/dev/null || true)"
fi

# ---- parse stdin JSON (python3, then jq, then sed) -> EVENT / SESSION_ID / CWD / MESSAGE
EVENT=""; SESSION_ID=""; CWD=""; MESSAGE=""
if [ -n "$INPUT" ]; then
  if command -v python3 >/dev/null 2>&1; then
    PARSED="$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
for k in ("hook_event_name", "session_id", "cwd", "message"):
    v = d.get(k)
    print(" ".join(str(v).split()) if isinstance(v, str) else "")
' 2>/dev/null)"
  elif command -v jq >/dev/null 2>&1; then
    PARSED="$(printf '%s' "$INPUT" | jq -r '[.hook_event_name, .session_id, .cwd, .message] | map(if type == "string" then gsub("\\s+"; " ") else "" end) | .[]' 2>/dev/null)"
  else
    sed_get() {
      printf '%s' "$INPUT" | tr '\n' ' ' \
        | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\\1/p" \
        | sed 's/\\"/"/g; s/\\\\/\\/g' | head -n1
    }
    PARSED="$(sed_get hook_event_name; echo; sed_get session_id; echo; sed_get cwd; echo; sed_get message)"
    PARSED="$(printf '%s\n' "$PARSED" | sed '/^$/d')"
    # sed path cannot represent empty fields reliably; accept missing ones as empty.
  fi
  {
    IFS= read -r EVENT
    IFS= read -r SESSION_ID
    IFS= read -r CWD
    IFS= read -r MESSAGE
  } <<EOF2
$PARSED
EOF2
fi

# ---- helpers
json_escape() {
  # Escape backslash and quote, flatten control chars.
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

post() {  # post <endpoint> <json-body>
  curl -sS -m 5 -X POST "$COGITATING_API/v1/hooks/$1" \
    -H "Authorization: Bearer $COGITATING_HOOK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null 2>&1 || true
}

PROJECT=""
if [ -n "$CWD" ]; then
  PROJECT="$(basename "$CWD" 2>/dev/null || true)"
fi
PROJECT="${PROJECT:0:120}"
MESSAGE="${MESSAGE:0:200}"

base_fields() {  # ,"agent_id":..,"tool":..,"project":..
  printf '"agent_id":"%s","tool":"%s"' "$(json_escape "$SESSION_ID")" "$TOOL"
  if [ -n "$PROJECT" ]; then printf ',"project":"%s"' "$(json_escape "$PROJECT")"; fi
}

send_status() {  # send_status <working|waiting|finished> [message]
  local body
  body="{$(base_fields),\"status\":\"$1\""
  if [ -n "${2:-}" ]; then body="$body,\"message\":\"$(json_escape "$2")\""; fi
  post agent-status "$body}"
}

# ---- dispatch
case "$EVENT" in
  SessionStart|UserPromptSubmit)
    [ -n "$SESSION_ID" ] && send_status working ;;
  Notification)
    [ -n "$SESSION_ID" ] && send_status waiting "$MESSAGE" ;;
  SessionEnd)
    [ -n "$SESSION_ID" ] && send_status finished ;;
  Stop)
    if [ -n "$SESSION_ID" ]; then
      post agent-finished "{$(base_fields)}"
    else
      post agent-finished '{}'
    fi ;;
  *)
    post agent-finished '{}' ;;  # legacy behaviour
esac

exit 0
