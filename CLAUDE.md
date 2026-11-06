# tmux-agents — development notes

User docs: [`README.md`](README.md) only (install, usage, options, troubleshooting, contributing). There is no separate INSTALL file.

Tested on macOS and Kali Linux. Keep everything portable across both: POSIX `sh`, and no GNU-only or BSD-only flags (`sed -i`, `date`, `stat`, `readlink -f` differ).

## Layout

| File | Role |
|---|---|
| `bin/tmux-agents` | POSIX sh. `report`/`clear`/`seen`/`sweep`, `claude-hook`/`codex-hook` (one shared `cmd_agent_hook`), `sidebar …`, `zoom toggle/restore/restore-all`, `toast`/`toast-body` |
| `sidebar/sidebar.ts` | Bun renderer running inside the sidebar pane (no deps) |
| `opencode/tui.js` | OpenCode V2 TUI plugin (plain JS, no deps) |
| `tmux-agents.tmux` | Entry: key, hooks (indexes 90-96), tab icons, status-line sweep, first-run setup popup |
| `defaults.conf` | Single source of colors, icons and sizes, read by all three above |
| `install.sh` | POSIX sh installer/uninstaller: tmux.conf line, Claude hooks, Codex `hooks.json` + `[features] hooks = true`, OpenCode `cli.json`. Idempotent, backs up, edits files in place (symlinked dotfiles). Restarts open sidebars (`respawn-pane`, same pane) after reloading, so an update applies at once. Keep in sync with README › How to Install (Manual Install) and the hook indexes |
| `tests/opencode.test.ts` | `tui.js` against a fake host API and a private tmux server |
| `tests/zoom.test.ts` | Sidebar-aware zoom on a private server with a fake sidebar pane: layout restored exactly, no-sidebar fallback, closing the zoomed pane or window, option off, toasts, double press, interrupted zoom, no sidebar in the hidden session, destroy-unattached, home-tab state |
| `tests/follow.test.ts` | The in-hook sidebar move on a window switch (background follow stripped): select/next/previous/last/new-window, saved width, borders, and the cases it must leave alone (off, zoomed here or in the window you left, floating panes in the top-left corner, sidebar alone or not the left pane, a sidebar already there, too narrow, the hidden session), your own per-window border style kept, and the width restored after a terminal resize |
| `tests/state.test.ts` | Hooks, report and toasts on a private server (control-mode client for toasts): gone pane, concurrent toasts, names with quotes/`;`, control characters in notes, `@agents-notify-on off`, long names in toasts, tab state after `break-pane`/`move-pane` |
| `tests/sidebar.test.ts` | The real sidebar (bun) on a private server, checked with `capture-pane`: control characters in fields, wide/emoji text never wraps, tiny widths, footer fits, `pane-base-index 1`, the cursor on the card you look at when the sidebar gets focus |
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
- **Docs: one line per paragraph or list item**, no hard wrapping (some Markdown editors show every newline as a line break). Keep the README anchors `#tested-on`, `#configuration` and `#zoom-with-the-sidebar` stable, since other sections link to them. Links into `<details>` blocks do not open them, so spell out short instructions instead of linking there. No Nerd Font glyphs in the README (readers without the font see boxes).

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
- Sidebar-aware zoom (`@agents-zoom-keeps-sidebar on`, `prefix + z`): tmux cannot zoom "all but one pane", so the other real panes move into one window of the hidden session `_agents_zoom` and come back in their old order, then `select-layout` re-applies the saved `#{window_layout}` (exact when the panes match; else only the sidebar width is restored). State: window `@agents_zoom` (pane list), `@agents_zoom_layout`; pane `@agents_zoom_from`; global `@agents_zoom_bound`. `sweep` rescues moved panes when the zoomed pane or window is gone. The sidebar shows moved panes at their home window and unzooms before jumping to one. Uninstall and turning the option off undo every zoom.
- Sidebar follow without a flash: `session-window-changed[90]` first moves the sidebar with plain tmux commands (`if -F … { join-pane … }`), which tmux runs before it redraws; the background `sidebar follow` after it only handles the rest. Anything backgrounded or `run-shell -C` (it runs on a timer) lands after a redraw: the window shows up without the sidebar for a frame. Targets (`-s`/`-t`) are not format-expanded (`-l` is), so the hook names the sidebar by position, `!.{top-left}` (the full-height left pane of the window you came from). It must not move when `{top-left}` would be something else: the last window natively zoomed (resolves to the zoomed pane, while the hidden sidebar keeps `pane_at_left`), a floating pane whose border covers (0,0) (floating panes report `pane_at_left` 0, so test `pane_left`/`pane_top` <= 1), the sidebar the only tiled pane there (the window would close); nor into a window with a top-left floating pane or too narrow. Check frames with `script -q -F out tmux attach` (macOS `script`; `-F` flushes every write) and look at where a marker line is drawn.
- `resize-pane -x` does not format-expand (unlike `join-pane -l`), so the `window-resized[96]` hook sets the sidebar width through `run-shell -C "resize-pane … -x #{…}"`. Commands run from a hook fire no `after-*` hooks, so that resize does not trigger the width save (`after-resize-pane[93]`); a terminal resize does not fire `after-resize-pane` either.
- Border hiding keeps a per-window `pane-active-border-style` of the user's: `@agents_border_saved` holds it, `@agents_border_hidden` the style set (old versions: `1`), and it is restored only when the window still has that style. The in-hook move cannot tell a window value from the global one, so it compares with `@agents_border_global` (set at load, refreshed by `sync_borders`). tmux 3.8's default `pane-active-border-style` is itself a format; `#{pane-active-border-style}` and `set -F` copy it raw (not expanded again).
- `tmux display -t <pane or window>` does not fail for one that is gone (it falls back to another), so check existence against `list-panes -a` / `list-windows -a`.
- `tmux display -p -t %<gone pane id>` exits 0 and prints the format with every field empty: put `#{pane_id}` in the format and treat empty as gone (no extra call on the hook path).
- tmux 3.8 has no `after-break-pane` / `after-join-pane` / `after-move-pane` hooks (`set-hook` says invalid option). The window hook `pane-moved` fires for break-, join-, move- and swap-pane, with the moved pane as the format target.
- Taking a pane out of a tmux-zoomed window (`join-pane -s`, `break-pane`) unzooms it: zoom it again in the same command.
- Tests that need a client (toasts) use a control-mode client, `tmux -L <sock> -C attach` with a stdin pipe; a normal client attached from a pane of a second private server crashed that server (tmux 3.8).
- Zoom robustness: zoom operations (and the sweep's rescue) hold a `mkdir` lock next to the tmux socket; zoom state is written only after the panes moved. Toasts are floating panes inside `#{window_layout}` (tmux 3.8 JSON), so they are closed before saving and before restoring, and the layout is re-applied only when its pane ids equal the window's. A zoomed window that is gone sends its hidden window back to the panes' own session (`@agents_zoom_session`). The sidebar never opens in `_agents_zoom`, and sweep never kills the sidebar of a zoomed window. Moved panes report against their home window (tab state, toast "where", card name).
- `set-option -t` takes a pane-style target: an exact session is `=name:` (with the colon); `=name` fails. `has-session`, `list-panes -s`, `rename-session` take `=name`.
- `destroy-unattached on` destroys every session without a client, so the zoom's hidden session gets it set off, and tests must exempt their own (unattached) sessions.
- Uninstall with the TPM `@plugin` line still present must not `source-file` tmux.conf (TPM would load the plugin again): it strips the injections instead.
- Tests: give a private tmux server a dummy `HOME`, or a `~` in a config it sources (TPM's `run '~/.tmux/plugins/tpm/tpm'`) runs the real user's files.

- TPM: tmux-agents is TPM-loadable as is (TPM runs `tmux-agents.tmux` in `@plugin` order, so it must come after the theme). TPM has no post-install step, so `client-attached[94]` plus a call at load run `tmux-agents setup-prompt`: once per tmux run, only with a client, only when `install.sh --check-setup` finds missing hooks, never with `@agents-setup-prompt off` or when the `install.sh` run-shell line is in `tmux.conf`. The popup runs `install.sh --setup` (dry-run diff, then y / n / x; x writes the opt-out line before the TPM run line). `install.sh` adds no run-shell line when an `@plugin` line for tmux-agents exists.
- Testing TPM in a sandbox HOME: run tmux with `env -i` and `-f <conf>`. From inside a real tmux, `TMUX_PLUGIN_MANAGER_PATH` is inherited and points TPM at the real `~/.tmux/plugins`, and Homebrew's system `tmux.conf` is read too.

## Checks

```sh
bun run check   # sh -n on the scripts (incl. install.sh, tests/install.sh) + bun build of sidebar and tui.js
bun test        # OpenCode reporter, zoom and installer tests (private tmux servers, sh and dash)
```

Commit straight to `master`.
