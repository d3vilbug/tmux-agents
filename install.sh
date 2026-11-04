#!/bin/sh
# tmux-agents installer. Safe to run again: every step checks first, and each
# config file it changes is backed up to <file>.bak-<timestamp>.
#
#   ./install.sh                 install everything that applies
#   ./install.sh --uninstall     undo it
#   ./install.sh --dry-run       show what would change (diffs), change nothing
#   options: --no-tmux --no-claude --no-opencode --no-codex
#
# Steps:
#   tmux      append `run-shell .../tmux-agents.tmux` to the end of tmux.conf
#             and load it into a running tmux server
#   claude    merge the hooks into ~/.claude/settings.json (if Claude Code is installed)
#   codex     merge the hooks into ~/.codex/hooks.json and enable them in
#             ~/.codex/config.toml (if Codex is installed)
#   opencode  add the plugin to ~/.config/opencode/cli.json (if OpenCode is installed)

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="$ROOT/bin/tmux-agents"
ENTRY="$ROOT/tmux-agents.tmux"
# run-shell hands its argument to sh -c: quote the path (it may contain spaces).
ENTRY_SH="'$(printf '%s' "$ENTRY" | sed "s/'/'\\\\''/g")'"
case "$ENTRY" in "$HOME"/*) ENTRY_T="~${ENTRY#"$HOME"}" ;; *) ENTRY_T="$ENTRY" ;; esac
CMD="'$BIN' claude-hook"
CMD_CODEX="'$BIN' codex-hook"
PLUGIN="$ROOT/opencode"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
OPENCODE_CLI="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/cli.json"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_HOOKS="$CODEX_DIR/hooks.json"
CODEX_CONFIG="$CODEX_DIR/config.toml"
STAMP=$(date +%Y%m%d%H%M%S)

mode=install dry=0
do_tmux=1 do_claude=1 do_opencode=1 do_codex=1
for a in "$@"; do
  case "$a" in
    --uninstall) mode=uninstall ;;
    -n | --dry-run) dry=1 ;;
    --no-tmux) do_tmux=0 ;;
    --no-claude) do_claude=0 ;;
    --no-opencode) do_opencode=0 ;;
    --no-codex) do_codex=0 ;;
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$(printf '\033[1m') G=$(printf '\033[32m') Y=$(printf '\033[33m') R=$(printf '\033[31m') C=$(printf '\033[36m') N=$(printf '\033[0m')
else B= G= Y= R= C= N=; fi
step() { printf '\n%s==> %s%s\n' "$B" "$1" "$N"; }
ok() { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
fail() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
# A change: done, or (dry run) would be done.
did() { if [ "$dry" = 1 ]; then printf '  %s~%s would: %s\n' "$C" "$N" "$1"; else ok "$1"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# Scratch files live in one private dir, removed on exit. (tmpfile runs in a
# $(...) subshell, so it must not rely on updating variables.)
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT INT TERM
tmpfile() { mktemp "$TMPD/f.XXXXXX"; }

# put <file> <new content file>: write it (backup first), or show the diff on a
# dry run. Returns 0 when it changed (or would), 1 when nothing would change. Writes in place, so symlinked
# dotfiles and permissions are kept.
put() {
  f=$1 new=$2
  if [ -f "$f" ] && cmp -s "$new" "$f"; then return 1; fi
  if [ "$dry" = 1 ]; then
    old=$f; [ -f "$f" ] || old=/dev/null
    diff -u "$old" "$new" | sed -e '1,2d' -e 's/^/      /' || true
    return 0
  fi
  if [ -f "$f" ]; then cp "$f" "$f.bak-$STAMP" && ok "backup: $f.bak-$STAMP"; fi
  mkdir -p "$(dirname "$f")"
  cat "$new" >"$f"
}

# jq_put <file> <jq args...>: apply a jq filter to <file> ({} if missing).
# Returns like put, or 2 when <file> is not valid JSON (left untouched).
jq_put() {
  f=$1; shift
  src=$f
  if [ ! -s "$f" ]; then src=$(tmpfile); echo '{}' >"$src"; fi
  new=$(tmpfile)
  if ! jq "$@" "$src" >"$new" 2>/dev/null; then
    fail "$f is not valid JSON: fix it, then run again (file left untouched)"
    return 2
  fi
  put "$f" "$new"
}

tmux_conf() {
  x="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
  if [ -f "$HOME/.tmux.conf" ]; then echo "$HOME/.tmux.conf"
  elif [ -f "$x" ]; then echo "$x"
  else echo "$HOME/.tmux.conf"; fi
}
tmux_running() { have tmux && tmux list-sessions >/dev/null 2>&1; }
# Our run-shell line is in <conf> (commented-out lines do not count).
ours_in_conf() { [ -f "$1" ] && grep -v '^[[:space:]]*#' "$1" | grep -qF -e "$ENTRY" -e "$ENTRY_T"; }

# Other tmux-agents installs (another clone) in the same configs: both would
# report every event, so point them out. They are never changed here.
other_installs() {
  step "Other tmux-agents installs"
  found=0
  conf=$(tmux_conf)
  if [ -f "$conf" ]; then
    for l in $(grep -n 'tmux-agents\.tmux' "$conf" | grep -v '^[0-9]*:[[:space:]]*#' | grep -vF -e "$ENTRY" -e "$ENTRY_T" | cut -d: -f1); do
      warn "$conf:$l: $(sed -n "${l}p" "$conf")"; found=1
    done
  fi
  if have jq && [ -s "$CLAUDE_SETTINGS" ]; then
    list=$(jq -r --arg cmd "$CMD" '[.hooks? // {} | .[][]?.hooks[]?.command? // empty
      | select(test("tmux-agents")) | select(. != $cmd)] | group_by(.)[] | "\(length)x \(.[0])"' "$CLAUDE_SETTINGS" 2>/dev/null || true)
    if [ -n "$list" ]; then
      found=1
      printf '%s\n' "$list" | while IFS= read -r h; do warn "$CLAUDE_SETTINGS: hook $h"; done
    fi
  fi
  if have jq && [ -s "$OPENCODE_CLI" ]; then
    list=$(jq -r --arg p "$PLUGIN" '(.plugins? // [])[] | strings | select(test("tmux-agents")) | select(. != $p)' "$OPENCODE_CLI" 2>/dev/null || true)
    if [ -n "$list" ]; then
      found=1
      printf '%s\n' "$list" | while IFS= read -r h; do warn "$OPENCODE_CLI: plugin $h"; done
    fi
  fi
  if have jq && [ -s "$CODEX_HOOKS" ]; then
    list=$(jq -r --arg cmd "$CMD_CODEX" '[.hooks? // {} | .[][]?.hooks[]?.command? // empty
      | select(test("tmux-agents")) | select(. != $cmd)] | group_by(.)[] | "\(length)x \(.[0])"' "$CODEX_HOOKS" 2>/dev/null || true)
    if [ -n "$list" ]; then
      found=1
      printf '%s\n' "$list" | while IFS= read -r h; do warn "$CODEX_HOOKS: hook $h"; done
    fi
  fi
  if [ "$found" = 1 ]; then
    warn "these point to another copy of tmux-agents and are left alone. Remove them (or run that copy's install.sh --uninstall), otherwise every agent event is reported twice"
  else
    ok "none"
  fi
}

# --- install -----------------------------------------------------------------

check_deps() {
  step "Requirements"
  if have tmux; then
    v=$(tmux -V | sed 's/[^0-9.]*\([0-9]*\)\.\([0-9]*\).*/\1 \2/')
    set -- $v
    if [ "${1:-0}" -gt 3 ] 2>/dev/null || { [ "${1:-0}" -eq 3 ] && [ "${2:-0}" -ge 8 ]; } 2>/dev/null; then ok "$(tmux -V)"
    elif [ "${1:-0}" -eq 3 ] 2>/dev/null && [ "${2:-0}" -ge 2 ]; then warn "$(tmux -V): works, but toasts need 3.8+ (status-line fallback)"
    else warn "$(tmux -V): 3.2+ required (3.8+ for toasts)"; fi
  else fail "tmux not found"; exit 1; fi
  if have bun; then ok "bun $(bun --version)"
  else warn "bun not found: the sidebar needs it (macOS: brew install bun, Linux: curl -fsSL https://bun.sh/install | bash)"; fi
  if have jq; then ok "$(jq --version)"
  else warn "jq not found: Claude hooks and this installer need it (macOS: brew install jq, Debian/Kali: sudo apt install jq)"; fi
  [ "$dry" = 1 ] || chmod +x "$BIN" "$ENTRY"
}

# The key that toggles the sidebar: @agents-key from tmux.conf (last setting
# wins), else from the running server, else the default from defaults.conf.
agents_key() {
  k=""
  [ -f "$1" ] && k=$(grep -v '^[[:space:]]*#' "$1" |
    sed -n 's/^[[:space:]]*set\(-option\)\{0,1\}[[:space:]]\{1,\}\(-[a-zA-Z]*[[:space:]]\{1,\}\)*@agents-key[[:space:]]\{1,\}//p' |
    tail -n 1 | sed "s/[[:space:]]*#.*//; s/^[\"']//; s/[\"'][[:space:]]*\$//")
  [ -n "$k" ] || { tmux_running && k=$(tmux show -gqv @agents-key 2>/dev/null); } || true
  [ -n "$k" ] || k=$(awk '$1 == "@agents-key" { print $2; exit }' "$ROOT/defaults.conf")
  printf '%s' "${k:-a}"
}

# Warn when prefix + <key> is already bound to something else, in tmux.conf
# or in the running server: tmux-agents loads last, so it would win.
key_conflicts() { # <conf> <key>
  conf=$1 key=$2
  kre=$(printf '%s' "$key" | sed 's/[][\\.*^$/]/\\&/g')
  hits=""
  if [ -f "$conf" ]; then
    hits=$(grep -n '' "$conf" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'tmux-agents' |
      grep -E "^[0-9]+:[[:space:]]*bind(-key)?[[:space:]]+(-r[[:space:]]+)?(-T[[:space:]]*prefix[[:space:]]+)?(-r[[:space:]]+)?['\"]?$kre['\"]?([[:space:]]|\$)" || true)
  fi
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | while IFS= read -r h; do
      warn "prefix + $key is already bound in $conf:${h%%:*}: ${h#*:}"
    done
  elif tmux_running; then
    live=$(tmux list-keys -T prefix "$key" 2>/dev/null | grep -v 'tmux-agents' | head -n 1 || true)
    [ -n "$live" ] || return 0
    cmd=$(printf '%s' "$live" | sed "s/^bind-key[[:space:]]*\(-r[[:space:]]*\)\{0,1\}-T prefix[[:space:]]*[^[:space:]]*[[:space:]]*//")
    warn "prefix + $key is already bound to \"$cmd\" in the running tmux server"
  else
    return 0
  fi
  warn "tmux-agents will override it. To keep it, add \`set -g @agents-key <key>\` above the run-shell line"
}

install_tmux() {
  step "tmux"
  conf=$(tmux_conf)
  if ours_in_conf "$conf"; then
    ok "already in $conf"
  else
    new=$(tmpfile)
    [ -f "$conf" ] && cat "$conf" >"$new"
    printf '\n# tmux-agents: Agents sidebar (prefix + a), tab state icons, notifications.\n# Keep this at the end, after your theme and TPM.\nrun-shell "%s"\n' "$ENTRY_SH" >>"$new"
    put "$conf" "$new" || true
    did "add the run-shell line to the end of $conf"
  fi
  key=$(agents_key "$conf")
  key_conflicts "$conf" "$key"
  if ! tmux_running; then ok "tmux is not running: it loads on the next start"
  elif [ "$dry" = 1 ]; then did "load $ENTRY into the running tmux server"
  elif tmux run-shell "$ENTRY_SH"; then ok "loaded into the running tmux server (prefix + $key opens the sidebar)"
  else warn "could not load it into the running tmux server: run 'tmux source ~/.tmux.conf'"; fi
}

install_claude() {
  step "Claude Code"
  if ! have claude && [ ! -d "$(dirname "$CLAUDE_SETTINGS")" ]; then warn "not installed, skipped"; return; fi
  have jq || { fail "jq missing, skipped"; return; }
  rc=0
  jq_put "$CLAUDE_SETTINGS" --arg cmd "$CMD" '
    def entry: {hooks: [{type: "command", command: $cmd, timeout: 5}]};
    .hooks //= {} |
    reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse",
            "Notification","Stop","SessionEnd") as $e
      (.; .hooks[$e] = ((.hooks[$e] // [])
            | map(select(any(.hooks[]?; .command == $cmd) | not))) + [entry])' || rc=$?
  case $rc in
  0)
    did "add the hooks to $CLAUDE_SETTINGS (new Claude sessions pick them up)"
    ;;
  1)
    ok "hooks already in $CLAUDE_SETTINGS"
    ;;
  esac
}

install_codex() {
  step "Codex"
  if ! have codex && [ ! -d "$CODEX_DIR" ]; then warn "not installed, skipped"; return; fi
  have jq || { fail "jq missing, skipped"; return; }
  # hooks.json uses the same nested shape as Claude's settings.json.
  rc=0
  jq_put "$CODEX_HOOKS" --arg cmd "$CMD_CODEX" '
    # Codex caps the timeout of Interrupt and SessionEnd at 3 s (and warns above).
    def entry($t): {hooks: [{type: "command", command: $cmd, timeout: $t}]};
    .hooks //= {} |
    reduce ("SessionStart","UserPromptSubmit","PreToolUse","PostToolUse",
            "PermissionRequest","PreModelRequest","PostModelRequest",
            "Stop","Interrupt","SessionEnd") as $e
      (.; .hooks[$e] = ((.hooks[$e] // [])
            | map(select(any(.hooks[]?; .command == $cmd) | not)))
            + [entry(if $e == "Interrupt" or $e == "SessionEnd" then 3 else 5 end)])' || rc=$?
  [ "$rc" = 2 ] && return
  case $rc in
  0) did "add the hooks to $CODEX_HOOKS (new Codex sessions pick them up)" ;;
  1) ok "hooks already in $CODEX_HOOKS" ;;
  esac
  # hooks.json is only read while the feature is enabled.
  if [ -f "$CODEX_CONFIG" ]; then
    live=$(grep -v '^[[:space:]]*#' "$CODEX_CONFIG")
    if printf '%s\n' "$live" | grep -q '^[[:space:]]*features\.hooks[[:space:]]*=[[:space:]]*true'; then
      ok "features.hooks = true already in $CODEX_CONFIG"
      return
    fi
    # A dotted key or an inline table cannot be edited by adding a second
    # [features] table (invalid TOML): leave the file alone.
    if printf '%s\n' "$live" | grep -q '^[[:space:]]*features[[:space:]]*[.=]'; then
      warn "$CODEX_CONFIG sets features as a dotted key or inline table: add \`hooks = true\` to it yourself, or the hooks are ignored"
      return
    fi
  fi
  new=$(tmpfile)
  src=$CODEX_CONFIG; [ -f "$src" ] || src=/dev/null
  # Set hooks = true inside the [features] table (before the next table header,
  # or at the end), flipping a hooks = false; add the table when there is none.
  # A header is a line that is only [name] or [[name]]: lines of a multi-line
  # array that start with "[" are not.
  awk '
    function header(l) { return l ~ /^[[:space:]]*\[[^][]*\][[:space:]]*(#.*)?$/ || l ~ /^[[:space:]]*\[\[[^][]*\]\][[:space:]]*(#.*)?$/ }
    # Blank lines inside [features] are held back, so hooks = true lands right
    # after the last entry of the table, not after the blank lines before the next.
    function flush() { printf "%s", held; held = "" }
    header($0) {
      if (infeat && !done) { print "hooks = true"; done = 1 }
      flush()
      infeat = ($0 ~ /^[[:space:]]*\[features\][[:space:]]*(#.*)?$/)
      if (infeat) seen = 1
      print; next
    }
    infeat && !done && /^[[:space:]]*$/ { held = held $0 "\n"; next }
    infeat && !done && /^[[:space:]]*hooks[[:space:]]*=/ {
      if ($0 !~ /=[[:space:]]*true([[:space:]]|#|$)/) sub(/=.*/, "= true")
      done = 1
    }
    { flush(); print }
    END {
      if (infeat && !done) print "hooks = true"
      flush()
      if (!seen) printf "%s[features]\nhooks = true\n", (NR ? "\n" : "")
    }
  ' "$src" >"$new"
  if put "$CODEX_CONFIG" "$new"; then
    did "enable [features] hooks = true in $CODEX_CONFIG"
  else
    ok "[features] hooks = true already in $CODEX_CONFIG"
  fi
}

install_opencode() {
  step "OpenCode"
  if ! have opencode && [ ! -d "$(dirname "$OPENCODE_CLI")" ]; then warn "not installed, skipped"; return; fi
  have jq || { fail "jq missing, skipped"; return; }
  rc=0
  jq_put "$OPENCODE_CLI" --arg p "$PLUGIN" '.plugins = ((.plugins // []) | map(select(. != $p)) + [$p])' || rc=$?
  case $rc in
  0)
    did "add the plugin to $OPENCODE_CLI"
    warn "then restart OpenCode fully: close every TUI, run 'opencode service restart', reopen"
    ;;
  1)
    ok "plugin already in $OPENCODE_CLI"
    ;;
  esac
}

# --- uninstall ---------------------------------------------------------------

uninstall_tmux() {
  step "tmux"
  conf=$(tmux_conf)
  if ours_in_conf "$conf"; then
    new=$(tmpfile)
    # Drop our lines, plus the blank line the installer put before its block,
    # so the file ends up exactly as it was. (ENVIRON: no escape processing.)
    E="$ENTRY" T="$ENTRY_T" awk '
      function ours(l) { return index(l, ENVIRON["E"]) || index(l, ENVIRON["T"]) ||
        index(l, "# tmux-agents: Agents sidebar") || index(l, "# Keep this at the end, after your theme and TPM.") }
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) if (ours(line[i])) {
          drop[i] = 1
          if (index(line[i], "# tmux-agents: Agents sidebar") && i > 1 && line[i-1] == "") drop[i-1] = 1
        }
        for (i = 1; i <= NR; i++) if (!drop[i]) print line[i]
      }' "$conf" >"$new"
    put "$conf" "$new" || true
    did "remove the run-shell line from $conf"
  else
    ok "not in $conf"
  fi
  if ! tmux_running; then return; fi
  if [ "$dry" = 1 ]; then
    did "remove the key and hooks (indexes 90-93) from the running tmux server"
    n=$(tmux list-panes -a -f '#{||:#{@agents_sidebar},#{@agents_toast}}' -F x 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = 0 ] || did "close $n open sidebar/toast pane(s)"
    did "clear the plugin's pane, window and global state (@agent*, @agents_*)"
    return
  fi
  set +e
  # The key and hooks go first: closing the panes below would otherwise fire
  # after-kill-pane, and its background sweep could set window state again
  # after it was cleared.
  key=$(tmux show -gqv @agents-key); tmux unbind-key "${key:-a}" 2>/dev/null
  for h in session-window-changed client-session-changed after-select-pane client-focus-in; do
    tmux set-hook -gu "$h[90]"; tmux set-hook -gu "$h[91]"
  done
  tmux set-hook -gu 'pane-exited[92]'; tmux set-hook -gu 'after-kill-pane[92]'
  tmux set-hook -gu 'after-resize-pane[93]'
  # Sidebars and toasts next: a running sidebar would keep writing state.
  for p in $(tmux list-panes -a -f '#{||:#{@agents_sidebar},#{@agents_toast}}' -F '#{pane_id}' 2>/dev/null); do
    tmux kill-pane -t "$p" 2>/dev/null
  done
  # Runtime state, in one batch: per pane, per window (incl. the border the
  # sidebar hid), and globals. User settings (@agents-...) are left alone.
  {
    for p in $(tmux list-panes -a -F '#{pane_id}' 2>/dev/null); do
      for o in @agent @agent_state @agent_since @agent_note @agent_shell_since; do echo "set -pqu -t $p $o"; done
    done
    tmux list-windows -a -F '#{window_id} #{@agents_border_hidden}' 2>/dev/null | while read -r w hidden; do
      echo "set -wqu -t $w @agent_win_state"; echo "set -wqu -t $w @agent_win_agent"
      [ "$hidden" = 1 ] && { echo "set -wqu -t $w pane-active-border-style"; echo "set -wqu -t $w @agents_border_hidden"; }
    done
    tmux show -g 2>/dev/null | awk '$1 ~ /^@agents_/ || $1 == "@agents-tab-icon" { print "set -gqu " $1 }'
  } | tmux source-file - 2>/dev/null
  tmux source-file "$conf" 2>/dev/null
  set -e
  ok "key, hooks, sidebars and state removed from the running tmux server (theme reloaded)"
}

uninstall_claude() {
  step "Claude Code"
  { [ -f "$CLAUDE_SETTINGS" ] && have jq; } || { ok "nothing to do"; return; }
  rc=0
  jq_put "$CLAUDE_SETTINGS" --arg cmd "$CMD" '
    if .hooks then .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; .command == $cmd) | not)))
                             | with_entries(select(.value | length > 0))) else . end' || rc=$?
  case $rc in
  0)
    did "remove the hooks from $CLAUDE_SETTINGS"
    warn "Claude sessions that are already running keep calling the hook until restarted: restart them before deleting $ROOT"
    ;;
  1)
    ok "no hooks of this copy in $CLAUDE_SETTINGS"
    ;;
  esac
}

uninstall_codex() {
  step "Codex"
  { [ -f "$CODEX_HOOKS" ] && have jq; } || { ok "nothing to do"; return; }
  rc=0
  # Only events this removal emptied are dropped; an empty list the user had stays.
  jq_put "$CODEX_HOOKS" --arg cmd "$CMD_CODEX" '
    if .hooks then .hooks |= with_entries(
      (.value | length) as $n
      | .value |= map(select(any(.hooks[]?; .command == $cmd) | not))
      | select((.value | length) > 0 or $n == 0)) else . end' || rc=$?
  case $rc in
  0)
    did "remove the hooks from $CODEX_HOOKS"
    # A hooks.json that only held our hooks (the installer created it): remove it too.
    # Not a symlink: that is the user's dotfiles setup, keep the link.
    if [ "$dry" != 1 ] && [ ! -L "$CODEX_HOOKS" ] && jq -e '. == {"hooks": {}}' "$CODEX_HOOKS" >/dev/null 2>&1; then
      rm -f "$CODEX_HOOKS" && ok "removed the now empty $CODEX_HOOKS"
    fi
    warn "Codex sessions that are already running keep calling the hook until restarted"
    warn "[features] hooks = true is left in $CODEX_CONFIG (your own hooks may need it)"
    ;;
  1)
    ok "no hooks of this copy in $CODEX_HOOKS"
    ;;
  esac
}

uninstall_opencode() {
  step "OpenCode"
  { [ -f "$OPENCODE_CLI" ] && have jq; } || { ok "nothing to do"; return; }
  rc=0
  jq_put "$OPENCODE_CLI" --arg p "$PLUGIN" 'if .plugins then .plugins |= map(select(. != $p)) else . end' || rc=$?
  case $rc in
  0)
    did "remove the plugin from $OPENCODE_CLI"
    warn "then restart OpenCode fully: close every TUI, run 'opencode service restart', reopen"
    ;;
  1)
    ok "plugin of this copy not in $OPENCODE_CLI"
    ;;
  esac
}

# --- main --------------------------------------------------------------------

[ "$dry" = 1 ] && printf '%sDry run:%s nothing is written, tmux is not touched.\n' "$B" "$N"
printf 'tmux-agents at %s\n' "$ROOT"
if [ "$mode" = install ]; then
  check_deps
  if [ "$do_tmux" = 1 ]; then install_tmux; fi
  if [ "$do_claude" = 1 ]; then install_claude; fi
  if [ "$do_codex" = 1 ]; then install_codex; fi
  if [ "$do_opencode" = 1 ]; then install_opencode; fi
  other_installs
  if [ "$dry" = 1 ]; then printf '\n%sDry run done.%s Run without --dry-run to apply.\n' "$B" "$N"
  else printf '\n%sDone.%s Press prefix + %s for the Agents sidebar.\n' "$B" "$N" "$(agents_key "$(tmux_conf)")"; fi
else
  if [ "$do_tmux" = 1 ]; then uninstall_tmux; fi
  if [ "$do_claude" = 1 ]; then uninstall_claude; fi
  if [ "$do_codex" = 1 ]; then uninstall_codex; fi
  if [ "$do_opencode" = 1 ]; then uninstall_opencode; fi
  other_installs
  if [ "$dry" = 1 ]; then printf '\n%sDry run done.%s Run without --dry-run to apply.\n' "$B" "$N"
  else printf '\n%sUninstalled.%s The folder %s can be deleted.\n' "$B" "$N" "$ROOT"; fi
fi
