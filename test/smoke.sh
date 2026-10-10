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

# 7. optional encryption (COGITATING_PUBKEY)
if command -v openssl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/priv.pem" 2>/dev/null || fail "keygen"
  PUB="$(openssl pkey -in "$TMP/priv.pem" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"
  field() { printf '%s' "$1" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read().split("|",2)[2]).get(sys.argv[1],"<absent>"),end="")' "$2"; }
  decrypt() { printf '%s' "${1#e1:}" | base64 -d 2>/dev/null | openssl pkeyutl -decrypt -inkey "$TMP/priv.pem" \
    -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 2>/dev/null; }
  mk() { python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"Notification","message":sys.argv[2]}))' "$1" "$2"; }
  enc() { mk "$1" "$2" | COGITATING_PUBKEY="$3" bash "$CC"; [ $? -eq 0 ] || fail "encrypt exit"; }

  MSG="Zażółć gęślą jaźń: potrzebuję zgody"
  enc "/tmp/mój-projekt" "$MSG" "$PUB"
  L="$(last)"; m="$(field "$L" message)"; p="$(field "$L" project)"
  case "$m$p" in e1:*e1:*) ;; *) fail "not encrypted: $L" ;; esac
  [ "$(decrypt "$m")" = "$MSG" ] || fail "message decrypt"
  [ "$(decrypt "$p")" = "mój-projekt" ] || fail "project decrypt"
  case "$L" in *"Zaż"*|*"mój"*) fail "plaintext leaked" ;; esac

  enc "/tmp/proj" "$(python3 -c 'print("ą"*100)')" "$PUB"
  dec="$(decrypt "$(field "$(last)" message)")"
  [ "$dec" = "$(python3 -c 'print("ą"*75,end="")')" ] || fail "truncation at char boundary"

  enc "/tmp/secret-proj" "secret message" "not-a-key"
  L="$(last)"
  [ "$(field "$L" status)" = "waiting" ] && [ "$(field "$L" message)" = "<absent>" ] && [ "$(field "$L" project)" = "<absent>" ] || fail "bad key: $L"
  case "$L" in *secret*) fail "bad key leaked plaintext" ;; esac

  mk "/tmp/my-proj" "Needs input" | COGITATING_PUBKEY= bash "$CC"
  L="$(last)"
  [ "$(field "$L" message)" = "Needs input" ] && [ "$(field "$L" project)" = "my-proj" ] || fail "plaintext unchanged: $L"

  # installer: --pubkey lands in env block next to the token (fake HOME, unreachable fake API)
  FH="$TMP/home"; mkdir -p "$FH"
  HOME="$FH" bash "$DIR/install.sh" --token tok-fake-install --api http://127.0.0.1:1 --pubkey "$PUB" >"$TMP/inst.out" 2>&1 </dev/null
  grep -q 'tok-fake-install' "$TMP/inst.out" && fail "installer printed the token"
  python3 - "$FH/.claude/settings.json" "$PUB" <<'PY' || fail "installer env"
import json, sys
env = json.load(open(sys.argv[1]))["env"]
assert env["COGITATING_PUBKEY"] == sys.argv[2] and env["COGITATING_HOOK_TOKEN"] == "tok-fake-install"
PY
  HOME="$FH" bash "$DIR/install.sh" --uninstall >/dev/null 2>&1
  grep -q COGITATING_PUBKEY "$FH/.claude/settings.json" 2>/dev/null && fail "uninstall left pubkey"
  ENCMSG=", encryption"
else
  ENCMSG=", encryption SKIPPED (openssl/python3 missing)"
fi

echo "PASS: notify, claude-code, wrapper$ENCMSG"
