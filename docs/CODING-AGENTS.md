# Capturing vibe coding

How Margin turns work with coding agents into iterations, and how other
tools join after Claude Code.

## The unit: one instruction, one iteration

A turn starts when you send a prompt and ends when the agent stops. Margin
records each turn that changed your project:

| Kept | From |
| --- | --- |
| Your instruction, word for word | the agent's prompt event |
| The code after the turn | a hidden git history of Margin's own (`~/Library/Application Support/Margin/Archive/code`), never your repo |
| What changed | diff between the versions before and after the turn |
| A picture of the running app | the project's dev server (found by its folder) or its `index.html`, rendered off screen |
| The agent's own summary | its final message, kept apart from your words |
| Your expectation and verdict | the reflection cards |

**Coding vs. research.** A turn counts only if files in the project changed.
Margin snapshots before and after; identical means the turn was a question,
research or planning, and nothing is saved. Sessions outside a project folder
(home, Desktop, Downloads) are never copied.

**The downtime.** On turns that edit files and run longer than 15 seconds,
a card asks what you expect to see. When the agent stops, a card shows
before → after and asks Keep / Not quite / Dead end. Ignore the first card
twice in a row and Margin stays quiet for 30 minutes.

**Old versions.** Every iteration can run again: Margin writes that version
to `~/Library/Application Support/Margin/Archive/versions`, borrows `node_modules` and `.env` from the
live project, starts its dev server (npm, pnpm, yarn or bun) or serves static
HTML, and opens it on localhost.

## Claude Code (built)

Hooks in `~/.claude/settings.json`, added by Settings → Claude Code → Connect:
`UserPromptSubmit`, `PostToolUse` (Edit, Write, MultiEdit, NotebookEdit, Bash),
`Stop`, `SessionEnd`. Each runs `~/.margin/claude-hook.sh` asynchronously, which
posts the event to Margin on `127.0.0.1:47821`. Claude is never slowed down, and
nothing happens when Margin isn't running. Covers the terminal, the desktop
app's local sessions and the editor extensions. Cloud sessions (claude.ai/code)
don't run local hooks.

Verified against real Claude Code 2.1.302 runs: payload shapes, the script,
and that Claude runs normally with Margin off.

## Other tools: the plan

Everything below plugs into the same pipeline: an adapter turns the tool's
signals into `HookEvent`s (prompt, edit, stop), and `CodingTurnTracker` does the
rest. Effort is for one adapter, including tests.

| Tool | Signals | Adapter | Effort |
| --- | --- | --- | --- |
| **Cursor** (agent) | Hooks in `~/.cursor/hooks.json`: `beforeSubmitPrompt` (prompt), `afterFileEdit` (file, edits), `stop`; payload has `conversation_id`, `workspace_roots` | Same script idea, mapped fields, Connect button | ~1 day |
| **Codex CLI** | Experimental hooks (`codex_hooks = true`): `SessionStart`, `UserPromptSubmit`, `Stop`; command hooks only; no edit event, which is fine because the before/after snapshot decides | Same as Claude Code, field mapping; transcript in `~/.codex/sessions` for the summary | ~1 day, depends on hook stability |
| **Windsurf, Zed, Copilot agent, others without hooks** | Files change in a project while the app is in front | Folder watcher (FSEvents) groups bursts of changes into turns; no prompt text, so the reflection card asks "What did you just ask for?" | ~2–3 days |
| **Lovable, Bolt, v0, Replit** (web) | No local files | Their GitHub sync: each commit is an iteration (prompt often in the commit message); or a browser extension that sees the prompt box and the preview | GitHub: ~2 days. Extension: a week+ |
| **Claude.ai artifacts** | In the browser | Browser extension, later | later |

Order: Cursor, then Codex, then the folder watcher as the catch-all.
