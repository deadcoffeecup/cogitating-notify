#!/bin/bash
# Compatibility regression for claude-code-stop.sh: the request each event produces must never change for
# existing installs. Golden lines are in test/fixtures/golden.txt (append-only: new behaviour gets NEW cases,
# an existing case may only change together with a deliberate, documented protocol change).
#   bash hooks/test/regression.sh            run
#   bash hooks/test/regression.sh --update   print current output for new cases (review before appending!)
# Offline: dry-run mode, fake token, no network.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${HOOK_SCRIPT:-$DIR/claude-code-stop.sh}"
[ -f "$SCRIPT" ] || SCRIPT="$DIR/hooks/claude-code.sh"  # public cogitating-notify repo layout
GOLDEN="$DIR/test/fixtures/golden.txt"
export COGITATING_API="https://api.test" COGITATING_HOOK_TOKEN="fake-token" COGITATING_DRY_RUN=1
unset COGITATING_PUBKEY

run() {  # run <stdin-json|-> [env...]
  local input="$1"; shift
  if [ "$input" = "-" ]; then env "$@" bash "$SCRIPT" </dev/null; else printf '%s' "$input" | env "$@" bash "$SCRIPT"; fi
}

# Tools-restricted PATH: no python3 and no jq, to exercise the sed fallback parser.
NOTOOLS="$(mktemp -d)"; trap 'rm -rf "$NOTOOLS"' EXIT
for t in bash sh cat tr sed head basename printf od fold mktemp rm base64 env cut; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$NOTOOLS/$t"
done

cases() {
  echo "== legacy: no stdin, no event (old installs: agent-finished with empty body)"
  run - | sed 's/^/legacy-empty|/'
  echo "== unknown event"
  run '{"hook_event_name":"SomethingNew","session_id":"s1","cwd":"/a/b"}' | sed 's/^/unknown|/'
  echo "== SessionStart"
  run '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/work/app"}' | sed 's/^/start|/'
  echo "== UserPromptSubmit"
  run '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/work/app","prompt":"secret prompt"}' | sed 's/^/prompt|/'
  echo "== Notification keeps the message, whitespace flattened"
  run '{"hook_event_name":"Notification","session_id":"s1","cwd":"/work/app","message":"Needs  your\npermission"}' | sed 's/^/notify|/'
  echo "== Stop"
  run '{"hook_event_name":"Stop","session_id":"s1","cwd":"/work/app"}' | sed 's/^/stop|/'
  echo "== Stop without session id"
  run '{"hook_event_name":"Stop"}' | sed 's/^/stop-nosid|/'
  echo "== SessionEnd"
  run '{"hook_event_name":"SessionEnd","session_id":"s1","cwd":"/work/app"}' | sed 's/^/end|/'
  echo "== quotes and backslashes are escaped"
  run '{"hook_event_name":"Notification","session_id":"s\"1","cwd":"/work/my app","message":"say \"hi\" \\ bye"}' | sed 's/^/escape|/'
  echo "== invalid JSON behaves like the legacy call"
  run 'not json at all' | sed 's/^/badjson|/'
  echo "== message longer than 200 chars is cut"
  run "{\"hook_event_name\":\"Notification\",\"session_id\":\"s1\",\"cwd\":\"/x\",\"message\":\"$(printf 'm%.0s' $(seq 1 250))\"}" | sed 's/^/longmsg|/' | cut -c1-120
  echo "== sed fallback parser (no python3, no jq) gives the same requests"
  run '{"hook_event_name":"Notification","session_id":"s1","cwd":"/work/app","message":"Needs your permission"}' PATH="$NOTOOLS" | sed 's/^/sedparse|/'
  run '{"hook_event_name":"Stop","session_id":"s1","cwd":"/work/app"}' PATH="$NOTOOLS" | sed 's/^/sedparse|/'
  echo "== silent without a token"
  printf '%s' '{"hook_event_name":"Stop","session_id":"s1"}' | env -u COGITATING_HOOK_TOKEN bash "$SCRIPT" | sed 's/^/notoken|/'
  echo "== always exit 0"
  printf '%s' 'x' | bash "$SCRIPT" >/dev/null; echo "exit=$?" | sed 's/^/exit|/'
}

if [ "${1:-}" = "--update" ]; then cases; exit 0; fi
OUT="$(cases)"
if [ "$OUT" = "$(cat "$GOLDEN")" ]; then echo "PASS: regression ($(grep -c '|' "$GOLDEN") golden lines)"; exit 0; fi
echo "FAIL: output differs from $GOLDEN"; diff <(cat "$GOLDEN") <(printf '%s\n' "$OUT"); exit 1
