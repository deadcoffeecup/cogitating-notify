# cogitating-notify

Get pinged on your phone when Claude Code, Codex, Cursor or Gemini CLI finishes — and see which agents are working or waiting for you.

Small shell hooks for the [Cogitating](#get-the-app) app (a quiz feed for developers who are waiting on AI coding agents). They tell the Cogitating API what your agents are doing; the app shows a live agents indicator and an in-app banner when an agent finishes, so you can stop doomscrolling and get back to work at the right moment.

## Install for Claude Code (60 seconds)

1. **Get a token.** In the app: Settings → Agent hook → Share. Copy the hook token.
2. **Run the installer:**
   ```bash
   git clone https://github.com/deadcoffeecup/cogitating-notify.git
   cd cogitating-notify
   bash install.sh --token YOUR_TOKEN
   ```
   It copies the scripts to `~/.cogitating/`, adds the five hooks and your token (as `env`) to `~/.claude/settings.json`, keeps every other setting, and sends a test status. Safe to re-run; `bash install.sh --uninstall` removes everything.
3. **Done.** Restart Claude Code. Your agent shows up in the app.

Prefer to do it by hand? Copy `hooks/claude-code.sh` somewhere, merge [`hooks/settings.example.json`](hooks/settings.example.json) into `~/.claude/settings.json` (fix the path), and add to the same file:
```json
{ "env": { "COGITATING_HOOK_TOKEN": "YOUR_TOKEN" } }
```

## Don't know your tool or model? Let your agent do it

In the app: Settings → Agent hook → **Copy prompt for your agent**, then paste it into any coding agent (Claude Code, Codex, Cursor, Gemini CLI, Copilot CLI, Windsurf, Aider, OpenCode…). It works with every model: the agent works out which tool it runs in, merges the hook into the right config file (with a backup), and verifies it with a test request. The prompt contains your hook token, so don't share it.

## Supported tools

| Tool | Coverage | Event used | Example |
|---|---|---|---|
| Claude Code | Full status (working / waiting / finished) | `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd` | [`settings.example.json`](hooks/settings.example.json) |
| Codex CLI | Finished only | `notify` | [`codex-config.toml`](hooks/examples/codex-config.toml) |
| Cursor | Finished only | `stop` | [`cursor-hooks.json`](hooks/examples/cursor-hooks.json) |
| Gemini CLI | Finished only | `AfterAgent` | [`gemini-settings.json`](hooks/examples/gemini-settings.json) |
| Windsurf | Finished only | `post_cascade_response` | [`windsurf-hooks.json`](hooks/examples/windsurf-hooks.json) |
| Aider | Finished only | `notifications-command` | [`aider.conf.yml`](hooks/examples/aider.conf.yml) |
| OpenCode | Finished only | `session.idle` | [`opencode-cogitating.js`](hooks/examples/opencode-cogitating.js) |
| GitHub Copilot CLI | Finished only | `agentStop` | [`copilot-cli-hook.json`](hooks/examples/copilot-cli-hook.json) |

"Finished only" tools use the generic [`hooks/cogitating-notify.sh`](hooks/cogitating-notify.sh). Copy it to `~/.cogitating/` (the installer does this) and paste the example into the tool's config. Hook formats were checked against each tool's official docs on 2026-10-06 and may change; open an issue if one breaks.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `COGITATING_HOOK_TOKEN` | — | Your hook token. If empty, the hooks do nothing. |
| `COGITATING_API` | `https://cogitating-api.pb79e6spzzxx0.eu-north-1.cs.amazonlightsail.com` | API base URL. |
| `COGITATING_PUBKEY` | unset | Optional. Base64 public key from the app; turns on message encryption (see below). |
| `COGITATING_NOTIFY_JSON` | unset | Set to `1` to print `{}` on stdout (needed by Cursor and Gemini CLI). |

## How it works

```
 agent (Claude Code, ...)      hook script            Cogitating API         phone app
        |  event + JSON stdin      |                        |                    |
        |------------------------->|  POST /v1/hooks/       |                    |
        |                          |  agent-status          |                    |
        |                          |----------------------->| store status       |
        |                          |                        |<-------------------|
        |                          |                        |  poll /v1/agents   |
        |                          |                        |------------------->| indicator,
        |                          |                        |                    | "finished" banner
```

Every hook runs with a 5-second timeout, never prints anything, and always exits 0, so it can never block or break your agent.

Claude Code events map to statuses like this: `SessionStart` / `UserPromptSubmit` → working, `Notification` → waiting for you (with the message), `Stop` → finished (via `agent-finished`), `SessionEnd` → finished.

## Encrypting messages (optional)

The app shows a public key in Settings. Install with it, or set it yourself:

```bash
bash install.sh --token YOUR_TOKEN --pubkey BASE64_PUBLIC_KEY
# or set it in ~/.claude/settings.json (backs up the file, --remove turns it off)
bash set-pubkey.sh BASE64_PUBLIC_KEY
```

With `COGITATING_PUBKEY` set, the hook encrypts the `message` and the `project` name on your machine (RSA-OAEP with SHA-256, needs `openssl` in `PATH`) and sends them as `e1:<base64>`. Only your phone holds the private key, so the Cogitating server and push services see only ciphertext.

- The message is cut to about 150 bytes before encryption.
- The project name is encrypted too.
- Push notification text becomes generic, because the server cannot read the message.
- If encryption fails (no `openssl`, bad key), the hook omits `message` and `project` and still sends the status. It never falls back to plaintext.

## Privacy

Your code, prompts and agent output are never sent. A hook sends only:

- the session id (used as `agent_id`),
- the tool name (e.g. `claude-code`),
- the base name of the working directory (e.g. `my-project`, not the full path),
- the status, and for "waiting" events the notification text Claude Code produced (cut to 200 characters).

The generic notifier sends an empty `{}` body. The hook token is a secret: it is stored in `~/.claude/settings.json` and can trigger your notifications, so do not commit it. Everything is plain shell; read the scripts, they are short.

## Troubleshooting

Test your token and connection directly:

```bash
curl -i -X POST "${COGITATING_API:-https://cogitating-api.pb79e6spzzxx0.eu-north-1.cs.amazonlightsail.com}/v1/hooks/agent-status" \
  -H "Authorization: Bearer $COGITATING_HOOK_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"manual-test","tool":"curl","project":"test","status":"working"}'
```

- `200`: works. Check the agents indicator in the app.
- `401` / `403`: wrong or revoked token; copy it again from the app.
- Nothing happens in Claude Code: run `/hooks` to confirm the entries exist, make sure `COGITATING_HOOK_TOKEN` is in the `env` block, and restart Claude Code.
- Run a hook by hand: `echo '{"session_id":"t1","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit"}' | bash ~/.cogitating/claude-code.sh`
- Run the repo tests: `bash test/smoke.sh` (starts a local fake API) or `bash test/smoke.sh --fake-curl`.

## Use it without the app?

The scripts are just thin `curl` wrappers around two HTTP endpoints, `POST /v1/hooks/agent-status` and `POST /v1/hooks/agent-finished`, authenticated with a Bearer hook token. The token comes from the Cogitating app, so the hooks are only useful together with it (or with your own backend that implements the same two endpoints; point `COGITATING_API` at it).

## Get the app

<!-- TODO: App Store link -->
<!-- TODO: Google Play link -->
<!-- TODO: Landing page link -->
Store links coming soon.

## Contributing

Adding a tool is a small PR: add an example file under `hooks/examples/` (pointing at `~/.cogitating/cogitating-notify.sh`), add a row to the table above, and link the tool's official hook docs in the PR. Please run `bash test/smoke.sh` and `shellcheck` on any script you touch.

## FAQ

**Does this slow down my agent?** No. Each call has a 5-second timeout and failures are ignored.

**Why is only Claude Code "full status"?** Its hooks expose session start, prompts, notifications and stop. The other tools only expose a "finished" event today.

**Will it work offline?** The hook silently does nothing if the API is unreachable.

**Windows?** Not tested. WSL should work; native PowerShell is not supported.

**Do I need python3 or jq?** `install.sh` needs `python3` to edit `settings.json`. The hook itself uses `python3`, `jq` or plain `sed`, whichever is available.

## License

[MIT](LICENSE)
