#!/bin/bash
# Claude Code hook for Cogitating (formerly claude-code-stop.sh).
# Reads the hook JSON from stdin (session_id, cwd, hook_event_name, message) and reports agent status:
#   SessionStart / UserPromptSubmit -> working     (POST /v1/hooks/agent-status)
#   Notification                    -> waiting     (message passed through)
#   Stop                            -> POST /v1/hooks/agent-finished (closes quiz session; push only if enabled in app) + status finished
#   SessionEnd                      -> finished    (POST /v1/hooks/agent-status)
# No/unknown event (old installs) behaves like the old script: agent-finished with an empty body.
# Optional E2E encryption: if COGITATING_PUBKEY (base64 RSA-2048 SPKI DER) is set, `message` and `project` are
# sent as "e1:" + base64(RSA-OAEP-SHA256 ciphertext), each cut to 150 bytes first. If encryption fails the
# fields are omitted (never plaintext). Without COGITATING_PUBKEY plaintext is sent as before.
# COGITATING_DRY_RUN=1 prints the request ("DRY-RUN POST /v1/hooks/<endpoint> <body>") instead of sending it.
# Never blocks, never prints (except in dry-run), always exits 0.

set -u

COGITATING_API="${COGITATING_API:-https://cogitating-api.pb79e6spzzxx0.eu-north-1.cs.amazonlightsail.com}"
COGITATING_HOOK_TOKEN="${COGITATING_HOOK_TOKEN:-}"
COGITATING_PUBKEY="${COGITATING_PUBKEY:-}"
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
  # COGITATING_DRY_RUN=1: print the request instead of sending it (for checking new versions; never set in real use).
  if [ "${COGITATING_DRY_RUN:-}" = "1" ]; then
    printf 'DRY-RUN POST /v1/hooks/%s %s\n' "$1" "$2"
    return 0
  fi
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

# ---- optional encryption (RSA-OAEP, SHA-256 for OAEP and MGF1)
PEM_DIR=""
PEM_FILE=""
cleanup() { [ -n "$PEM_DIR" ] && rm -rf "$PEM_DIR"; }
trap cleanup EXIT

truncate_bytes() {  # truncate_bytes <string> <max-bytes>: cut at a UTF-8 character boundary
  local s="$1" max="$2" cut b
  local LC_ALL=C
  if [ "${#s}" -le "$max" ]; then printf '%s' "$s"; return 0; fi
  cut="$max"
  while [ "$cut" -gt 0 ]; do
    b="$(printf '%s' "${s:cut:1}" | od -An -tu1 | tr -d ' ')"
    # 128..191 = UTF-8 continuation byte, so the cut would split a character
    if [ -n "$b" ] && [ "$b" -ge 128 ] && [ "$b" -le 191 ]; then cut=$((cut - 1)); else break; fi
  done
  printf '%s' "${s:0:cut}"
}

init_pem() {  # builds a PEM file from COGITATING_PUBKEY; returns 1 on failure
  command -v openssl >/dev/null 2>&1 || return 1
  local key
  key="$(printf '%s' "$COGITATING_PUBKEY" | tr -d ' \t\r\n')"
  [ -n "$key" ] || return 1
  umask 077
  PEM_DIR="$(mktemp -d 2>/dev/null)" || return 1
  PEM_FILE="$PEM_DIR/key.pem"
  { printf -- '-----BEGIN PUBLIC KEY-----\n'; printf '%s' "$key" | fold -w 64; printf '\n-----END PUBLIC KEY-----\n'; } > "$PEM_FILE" 2>/dev/null || return 1
  return 0
}

enc_value() {  # enc_value <plaintext>: prints "e1:<base64>" or nothing on any failure
  [ -n "$1" ] || return 0
  [ -n "$PEM_FILE" ] || return 0
  local plain ct
  plain="$(truncate_bytes "$1" 150)"
  [ -n "$plain" ] || return 0
  ct="$(printf '%s' "$plain" | openssl pkeyutl -encrypt -pubin -inkey "$PEM_FILE" \
        -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 2>/dev/null \
        | base64 2>/dev/null | tr -d '\n\r ')" || return 0
  [ -n "$ct" ] && printf 'e1:%s' "$ct"
  return 0
}

# PROJECT_VAL / MESSAGE_VAL are JSON-string-safe values to send (empty = omit field).
if [ -n "$COGITATING_PUBKEY" ]; then
  if init_pem; then
    PROJECT_VAL="$(enc_value "$PROJECT")"
    MESSAGE_VAL="$(enc_value "$MESSAGE")"
  else
    PROJECT_VAL=""; MESSAGE_VAL=""
  fi
else
  PROJECT_VAL="$(json_escape "$PROJECT")"
  MESSAGE_VAL="$(json_escape "$MESSAGE")"
fi

base_fields() {  # "agent_id":..,"tool":..[,"project":..]
  printf '"agent_id":"%s","tool":"%s"' "$(json_escape "$SESSION_ID")" "$TOOL"
  if [ -n "$PROJECT_VAL" ]; then printf ',"project":"%s"' "$PROJECT_VAL"; fi
}

send_status() {  # send_status <working|waiting|finished> [with-message]
  local body
  body="{$(base_fields),\"status\":\"$1\""
  if [ -n "${2:-}" ] && [ -n "$MESSAGE_VAL" ]; then body="$body,\"message\":\"$MESSAGE_VAL\""; fi
  post agent-status "$body}"
}

# ---- dispatch
case "$EVENT" in
  SessionStart|UserPromptSubmit)
    [ -n "$SESSION_ID" ] && send_status working ;;
  Notification)
    [ -n "$SESSION_ID" ] && send_status waiting msg ;;
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
