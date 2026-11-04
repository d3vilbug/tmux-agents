# tmux-agents — development notes

User docs: [`README.md`](README.md) only (install, usage, options, troubleshooting, contributing). There is no separate INSTALL file.

Tested on macOS and Kali Linux. Keep everything portable across both: POSIX `sh`, and no GNU-only or BSD-only flags (`sed -i`, `date`, `stat`, `readlink -f` differ).

## Layout

| File | Role |
|---|---|
| `bin/tmux-agents` | POSIX sh. `report`/`clear`/`seen`/`sweep`, `claude-hook`/`codex-hook` (one shared `cmd_agent_hook`), `sidebar …`, `toast`/`toast-body` |
| `sidebar/sidebar.ts` | Bun renderer running inside the sidebar pane (no deps) |
| `opencode/tui.js` | OpenCode V2 TUI plugin (plain JS, no deps) |
| `tmux-agents.tmux` | Entry: key, hooks (indexes 90-93), tab icons, status-line sweep |
| `defaults.conf` | Single source of colors, icons and sizes, read by all three above |
| `install.sh` | POSIX sh installer/uninstaller: tmux.conf line, Claude hooks, Codex `hooks.json` + `[features] hooks = true`, OpenCode `cli.json`. Idempotent, backs up, edits files in place (symlinked dotfiles). Keep in sync with README › How to Install (Manual Install) and the hook indexes |
| `tests/opencode.test.ts` | `tui.js` against a fake host API and a private tmux server |
| `tests/install.sh` | Installer tests (dry run, install, rerun, end-to-end hook, uninstall, fresh HOME, invalid JSON, other copies, XDG, key conflicts), throwaway HOMEs + private socket `tmux-agents-install-test` in a private `TMUX_TMPDIR` (so even a real `/usr/bin/tmux` that slips past the PATH wrapper cannot reach the live server; keep every `env -i` call passing it). `tests/install.test.ts` runs it under `sh` and `dash`. Add a case here for every installer change |
| `README.md` | User docs; embeds the demos in `assets/` (`tmux-agents.gif`, `tmux-agents-sidebar.gif`) |
| `LICENSE`, `package.json` | MIT, copyright "d3vil bug" (keep the README License section the same); scripts `check`, `test`, `sidebar` |

State is only tmux options (`@agent*` per pane, `@agent_win_state` per window, `@agents_*` globals). There is no daemon and no file state.

## Rules

- **Never touch the user's live tmux server while testing.** Use `tmux -L agtest` (look at it from a second terminal with `TMUX= tmux -L agtest attach`, see README › Contribution). Apply to the live server only when done: `tmux run-shell …/tmux-agents.tmux`, then respawn an open sidebar (`tmux respawn-pane -k -t <sidebar> "exec bun '…/sidebar/sidebar.ts'"`).
- **Hook path speed.** `claude-hook` and `codex-hook` run on every tool call. Keep the no-change path to `jq` plus one `tmux display`, about 25 ms. Do expensive work (toasts) only on a state change, backgrounded, with output sent to `/dev/null` so Claude does not wait on the pipe.
- **Never read the prompt or any agent text.** It is a promise in the README Disclaimer: change code and Disclaimer together. The jq filter takes only `hook_event_name`, `tool_name`, `notification_type` and `status` (Codex request status, a plain word). Never `prompt`, `error`, `last_assistant_message` or similar.
- **Nerd Font glyphs belong in `defaults.conf`, not in code.** Some glyphs (e.g. U+F06E, the eye) get silently dropped when written through tooling. Check with `od -c` after editing.
- New tmux hooks need a fixed index (`'name[9x]'`) so re-sourcing replaces them instead of piling up, and other plugins' hooks stay untouched.
- Decorations of theme options (`window-status*-format`, `status-right`) must strip a previous injection first, so they stay idempotent across `tmux source`.
- In heredocs that contain an `EOF` line, use a different outer delimiter.
- **Public repo: no personal data.** No usernames, home paths, hostnames, emails or internal project names in code, docs or comments. Example paths use `~/.tmux/plugins/tmux-agents` (or `/path/to/tmux-agents/...` where an absolute path is required).
- **Docs: one line per paragraph or list item**, no hard wrapping (some Markdown editors show every newline as a line break). Keep the README anchors `#tested-on` and `#configuration` stable, since other sections link to them. Links into `<details>` blocks do not open them, so spell out short instructions instead of linking there. No Nerd Font glyphs in the README (readers without the font see boxes).

## Gotchas found the hard way

- tmux 3.8 `new-pane` (floating): `-y` includes the border, so a 2-line toast is `-y 4`; `-B` accepts `single|double|heavy|simple|number`, not `rounded`. Create toasts with `-d` so they never take focus.
- Raw-mode input arrives batched (`"j\r"` in one chunk): tokenize before matching keys.
- `switch-client` fails with no client; run `select-window`/`select-pane` first, then `switch-client` separately.
- `pane-exited` is a window-level hook: `show-hooks -gw`, not `-g`.
- `#{automatic-rename}` is `0` once the user renamed a window, so it tells a user-chosen tab name from an auto one.
- OpenCode V2 events: `session.execution.{started,succeeded,interrupted,failed}`, `permission.{asked,replied}`, `form.{created,replied,cancelled}` (`form.created` carries `data.form.sessionID`). TUI API: `api.data.listen`, `api.ui.router.current()`, `api.data.session.{get,status,family,permission.list,form.list}`. herdr's `herdr-tui-session.js` is a good reference.
- OpenCode TUI plugins can `spawn` processes and read `process.env` (`TMUX_PANE`). Changes need the full service + TUI restart.
- Codex (0.166) hooks: `~/.codex/hooks.json`, same nested shape as Claude's, only read with `[features] hooks = true`; the hook gets JSON on stdin. Codex asks the user to trust new or changed hooks on the next start ("Trust all and continue"), and a running session keeps its old hooks. It clamps the timeout of `Interrupt` and `SessionEnd` to 3 s (and warns above that).
- Codex fires no `Stop` for a turn that fails: `PreModelRequest`, then `PostModelRequest` with `status: "failed"`. That is mapped to blocked "request failed"; `PreModelRequest` only revives a blocked card (requests outside a turn must not). An Esc fires `Interrupt`. `PermissionRequest` is the approval prompt and `request_user_input` the ask-the-user tool (seen in `PreToolUse`).
- Test Codex end to end on a private server: `tmux -L cxtest new -d "codex"` (add `--profile <name>` for a local model; use a copy of `~/.codex` via `CODEX_HOME` to log hook payloads). A local backend that rejects Codex's `namespace` tools fails every turn: that exercises the failure path, not tools, approvals or Stop.
- The sidebar's pane title is `agents=<claude>|<oc inactive>|<oc current>|<codex>`. The tab format's regex keeps the last part optional so a sidebar started before an upgrade still matches; after changing the protocol, respawn open sidebars.

- tmux `#{s/re/\N/:...}` prints the group number itself (`1`, `5`) when the group is empty or missing, so tab formats must treat a bare digit as "no frame" and fall back to the still icon.
- `install.sh` holds awk programs in single quotes: an apostrophe in a comment inside one ends the program (`sh -n` catches it).
- The sidebar bottom is the key hints (only while focused) above a credit row (`by d3vilbug`). Row math: `body = H - (footer ? 3 : 2) - banner rows`; change both together.

## Checks

```sh
bun run check   # sh -n on the scripts (incl. install.sh, tests/install.sh) + bun build of sidebar and tui.js
bun test        # OpenCode reporter + installer tests (private tmux servers, sh and dash)
```

Commit straight to `master`.
