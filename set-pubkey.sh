#!/bin/bash
# Sets COGITATING_PUBKEY (the public key from the app: Settings -> Agent hook -> Encrypt messages) in the "env"
# block of ~/.claude/settings.json, so the Claude Code hook encrypts message and project name.
#   bash hooks/set-pubkey.sh <base64-public-key>      set it
#   bash hooks/set-pubkey.sh --remove                  turn encryption off again
# Backs up the file first (settings.json.bak-<time>), changes nothing else and never prints the hook token.
# CLAUDE_SETTINGS=/path/to/settings.json overrides the target (used by tests).
set -u
FILE="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
ARG="${1:-}"
[ -n "$ARG" ] || { echo "usage: $0 <base64-public-key> | --remove" >&2; exit 2; }
[ -f "$FILE" ] || { echo "not found: $FILE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
if [ "$ARG" != "--remove" ]; then
  KEY="$(printf '%s' "$ARG" | tr -d ' \t\r\n')"
  case "$KEY" in *[!A-Za-z0-9+/=]*|"") echo "that does not look like a base64 public key" >&2; exit 2 ;; esac
  [ "${#KEY}" -ge 300 ] || { echo "key too short for an RSA-2048 public key (copy the whole value from the app)" >&2; exit 2; }
fi
cp "$FILE" "$FILE.bak-$(date +%Y%m%d%H%M%S)" || exit 1
python3 - "$FILE" "$ARG" <<'PY'
import json, sys
path, arg = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
env = data.setdefault("env", {})
if arg == "--remove":
    env.pop("COGITATING_PUBKEY", None)
else:
    env["COGITATING_PUBKEY"] = "".join(arg.split())
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("COGITATING_PUBKEY removed" if arg == "--remove" else "COGITATING_PUBKEY set (restart Claude Code sessions to pick it up)")
PY
