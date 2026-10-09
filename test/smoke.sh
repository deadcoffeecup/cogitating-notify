#!/bin/bash
# Smoke test for the hooks. By default starts a local fake API (python3).
# `bash test/smoke.sh --fake-curl` uses a fake curl on PATH instead (no network, no python server).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; LOG="$TMP/req.log"; : > "$LOG"
PORT="${PORT:-18765}"
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

if [ "${1:-}" = "--fake-curl" ]; then
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'FC'
#!/bin/bash
url=""; auth=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s|%s|%s\n' "${url#*://*/}" "$auth" "$body" >> "$FAKE_CURL_LOG"
FC
  chmod +x "$TMP/bin/curl"
  export FAKE_CURL_LOG="$LOG" PATH="$TMP/bin:$PATH"
  export COGITATING_API="http://fake.invalid"
  FMT() { cat "$LOG"; }
else
  python3 - "$PORT" "$LOG" <<'PY' &
import sys, http.server
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0); body = self.rfile.read(n).decode()
        open(log, 'a').write(f"{self.path.lstrip('/')}|{self.headers.get('Authorization')}|{body}\n")
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(b'{"ok":true}')
    def do_GET(self):
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  SRV=$!; disown "$SRV" 2>/dev/null
  for _ in $(seq 25); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
  export COGITATING_API="http://127.0.0.1:$PORT"
fi
export COGITATING_HOOK_TOKEN="tok-smoke"
count() { wc -l < "$LOG" | tr -d ' '; }
last() { tail -n1 "$LOG"; }
CC="$DIR/hooks/claude-code.sh"

# 1. notify posts agent-finished with the bearer token
bash "$DIR/hooks/cogitating-notify.sh" '{"type":"agent-turn-complete"}' </dev/null || fail "notify exit"
[ "$(last)" = "v1/hooks/agent-finished|Bearer tok-smoke|{}" ] || fail "notify request: $(last)"

# 2. no token -> no request, exit 0
n=$(count); COGITATING_HOOK_TOKEN= bash "$DIR/hooks/cogitating-notify.sh"; [ $? -eq 0 ] || fail "no-token exit"
COGITATING_HOOK_TOKEN= bash "$CC" </dev/null; [ "$(count)" = "$n" ] || fail "request sent without token"

# 3. JSON mode prints {}
[ "$(COGITATING_NOTIFY_JSON=1 bash "$DIR/hooks/cogitating-notify.sh")" = "{}" ] || fail "json mode"

# 4. claude-code.sh event mapping
ev() { printf '%s' "$1" | bash "$CC"; [ $? -eq 0 ] || fail "claude-code exit for $1"; }
ev '{"session_id":"s1","cwd":"/tmp/my-proj","hook_event_name":"UserPromptSubmit"}'
last | grep -q '^v1/hooks/agent-status|Bearer tok-smoke|.*"agent_id":"s1".*"project":"my-proj".*"status":"working"' || fail "working: $(last)"
ev '{"session_id":"s1","cwd":"/tmp/my-proj","hook_event_name":"Notification","message":"Needs \"input\""}'
last | grep -q '"status":"waiting".*"message":"Needs \\"input\\""' || fail "waiting: $(last)"
ev '{"session_id":"s1","cwd":"/tmp/my-proj","hook_event_name":"Stop"}'
last | grep -q '^v1/hooks/agent-finished|.*"agent_id":"s1"' || fail "stop: $(last)"
ev '{"session_id":"s1","cwd":"/tmp/my-proj","hook_event_name":"SessionEnd"}'
last | grep -q '^v1/hooks/agent-status|.*"status":"finished"' || fail "session end: $(last)"

# 5. legacy wrapper still works
n=$(count); bash "$DIR/hooks/claude-code-stop.sh" </dev/null; [ $? -eq 0 ] || fail "wrapper exit"
[ "$(count)" -gt "$n" ] || fail "wrapper did not POST"

# 6. unreachable server -> exit 0 (skipped with fake curl)
if [ -z "${FAKE_CURL_LOG:-}" ]; then
  COGITATING_API="http://127.0.0.1:1" bash "$DIR/hooks/cogitating-notify.sh"; [ $? -eq 0 ] || fail "unreachable notify"
  echo '{"session_id":"x","hook_event_name":"Stop"}' | COGITATING_API="http://127.0.0.1:1" bash "$CC"; [ $? -eq 0 ] || fail "unreachable claude"
fi

echo "PASS: notify, claude-code, wrapper"
