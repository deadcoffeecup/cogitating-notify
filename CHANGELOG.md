# Changelog

## 0.1.0 - 2026-10-09

Initial release.

- Claude Code hook with full status: working, waiting for you, finished (`SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`).
- Generic `cogitating-notify.sh` for finished-only notifications.
- Examples for Codex CLI, Cursor, Gemini CLI, Windsurf, Aider, OpenCode and GitHub Copilot CLI.
- Idempotent `install.sh` (with `--uninstall`) for Claude Code.
- Smoke test with a local fake API server.
