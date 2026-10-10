#!/bin/bash
# Cogitating hook installer for Claude Code.
#   bash install.sh [--token TOKEN] [--api URL] [--pubkey BASE64] [--uninstall]
# Copies scripts to ~/.cogitating/ and merges hooks + env into ~/.claude/settings.json.
# Idempotent. Never aborts the calling shell (always exits 0 except on bad usage).

DEFAULT_API="https://cogitating-api.pb79e6spzzxx0.eu-north-1.cs.amazonlightsail.com"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
TOKEN=""; API=""; PUBKEY=""; UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 || shift ;;
    --token=*) TOKEN="${1#--token=}"; shift ;;
    --api) API="${2:-}"; shift 2 || shift ;;
    --api=*) API="${1#--api=}"; shift ;;
    --pubkey) PUBKEY="${2:-}"; shift 2 || shift ;;
    --pubkey=*) PUBKEY="${1#--pubkey=}"; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) echo "Usage: bash install.sh [--token TOKEN] [--api URL] [--pubkey BASE64] [--uninstall]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

DEST="$HOME/.cogitating"
SETTINGS="$HOME/.claude/settings.json"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to edit $SETTINGS. Add the hooks manually (see hooks/settings.example.json)."
  exit 0
fi

# Edits settings.json. Args: action(install|uninstall) settings_path token api dest pubkey
edit_settings() {
  python3 - "$@" <<'PY'
import json, os, shutil, sys
action, path, token, api, dest, pubkey = sys.argv[1:7]
EVENTS = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"]
MARK = ".cogitating/claude-code"
cmd = "bash " + os.path.join(dest, "claude-code.sh")

data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            raw = f.read()
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            raise ValueError("top-level value is not an object")
    except Exception as e:
        print("ERROR: cannot parse %s (%s). Left untouched; fix it and re-run." % (path, e))
        sys.exit(3)
    shutil.copyfile(path, path + ".cogitating.bak")

def strip(hooks):
    """Remove our entries from every event; drop emptied groups/events."""
    for ev in list(hooks.keys()):
        groups = hooks.get(ev)
        if not isinstance(groups, list):
            continue
        kept = []
        for g in groups:
            hs = g.get("hooks") if isinstance(g, dict) else None
            if isinstance(hs, list):
                hs = [h for h in hs if not (isinstance(h, dict) and MARK in str(h.get("command", "")))]
                if not hs:
                    continue
                g = dict(g, hooks=hs)
            kept.append(g)
        if kept:
            hooks[ev] = kept
        else:
            del hooks[ev]

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
strip(hooks)
env = data.get("env")
if not isinstance(env, dict):
    env = {}

if action == "install":
    for ev in EVENTS:
        hooks.setdefault(ev, []).append({"hooks": [{"type": "command", "command": cmd}]})
    if token:
        env["COGITATING_HOOK_TOKEN"] = token
    if api:
        env["COGITATING_API"] = api
    if pubkey:
        env["COGITATING_PUBKEY"] = "".join(pubkey.split())
else:
    env.pop("COGITATING_HOOK_TOKEN", None)
    env.pop("COGITATING_API", None)
    env.pop("COGITATING_PUBKEY", None)

if hooks: data["hooks"] = hooks
else: data.pop("hooks", None)
if env: data["env"] = env
else: data.pop("env", None)

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

if [ "$UNINSTALL" = 1 ]; then
  edit_settings uninstall "$SETTINGS" "" "" "$DEST" "" || echo "Could not update $SETTINGS."
  rm -rf "$DEST"
  echo "Cogitating hooks removed (settings backup: $SETTINGS.cogitating.bak)."
  exit 0
fi

# Token: --token or interactive prompt.
if [ -z "$TOKEN" ]; then
  if [ -t 0 ]; then
    printf 'Hook token (app: Settings -> Agent hook -> Share): '
    IFS= read -r TOKEN
  fi
fi
if [ -z "$TOKEN" ]; then
  echo "No token given. Re-run with --token YOUR_TOKEN." 
  exit 0
fi

# Copy scripts.
if ! { mkdir -p "$DEST" && cp "$SRC"/hooks/claude-code.sh "$SRC"/hooks/claude-code-stop.sh "$SRC"/hooks/cogitating-notify.sh "$DEST"/ \
      && chmod +x "$DEST"/*.sh; }; then
  echo "Could not copy scripts to $DEST (run from the repo checkout)."
  exit 0
fi
echo "Scripts installed to $DEST"

mkdir -p "$HOME/.claude" 2>/dev/null
edit_settings install "$SETTINGS" "$TOKEN" "$API" "$DEST" "$PUBKEY" || { echo "settings.json not updated."; exit 0; }
echo "Hooks merged into $SETTINGS"
[ -n "$PUBKEY" ] && echo "Message encryption enabled (COGITATING_PUBKEY set)."

# Verify.
URL="${API:-$DEFAULT_API}"
if command -v curl >/dev/null 2>&1; then
  CODE="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -X POST "${URL%/}/v1/hooks/agent-status" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"agent_id":"install-test","tool":"claude-code","project":"install-test","status":"finished"}' 2>/dev/null)"
  case "$CODE" in
    2??) echo "Verified: API accepted the test status (HTTP $CODE). Restart Claude Code and you are done." ;;
    401|403) echo "API rejected the token (HTTP $CODE). Copy it again from the app." ;;
    ""|000) echo "Could not reach $URL. Hooks are installed; check your network or --api value." ;;
    *) echo "API answered HTTP $CODE. Hooks are installed, but check the token and API URL." ;;
  esac
else
  echo "curl not found; skipped verification."
fi
exit 0
