#!/bin/sh
# Installer tests: runs install.sh in throwaway HOMEs against a private tmux
# server (socket tmux-agents-install-test), never the live one or real configs.
#
#   sh tests/install.sh [shell]     shell that runs install.sh (default: sh)
#
# The repo is copied to a path with spaces, to cover quoting.

SH=${1:-sh}
SRC=$(cd "$(dirname "$0")/.." && pwd)
SOCK=tmux-agents-install-test
REAL_TMUX=$(command -v tmux) || { echo "tmux not found"; exit 1; }
REAL_JQ=$(command -v jq) || { echo "jq not found"; exit 1; }
REAL_BUN=$(command -v bun || true)

W=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agents-test.XXXXXX")
W=$(cd "$W" && pwd) # normalise (macOS TMPDIR ends in /), like install.sh does
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
# Safety net: every tmux started from here (even a real /usr/bin/tmux that
# slips past the PATH wrapper) uses a private socket directory, never the
# default one of the user's live server. Short path: socket paths are limited.
TS=$(mktemp -d /tmp/tmux-agents-sock.XXXXXX)
export TMUX_TMPDIR="$TS"
unset TMUX
SHB=$(command -v "$SH") || { echo "shell not found: $SH"; exit 1; } # absolute: the tests run with a reduced PATH
pass=0 failn=0
t() { if eval "$2"; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "  FAIL [$SH] $1"; sed 's/^/    | /' "$W/out" 2>/dev/null | tail -n 15; fi; }

# mkbin <dir> [stub...]: PATH dir with a tmux wrapper (private socket), jq,
# bun, and empty stubs (e.g. claude, opencode) that make those "installed".
mkbin() {
  d=$1; shift; mkdir -p "$d"
  printf '#!/bin/sh\nexec "%s" -L %s "$@"\n' "$REAL_TMUX" "$SOCK" >"$d/tmux"; chmod +x "$d/tmux"
  ln -sf "$REAL_JQ" "$d/jq"
  [ -n "$REAL_BUN" ] && ln -sf "$REAL_BUN" "$d/bun"
  for s in "$@"; do printf '#!/bin/sh\nexit 0\n' >"$d/$s"; chmod +x "$d/$s"; done
}
X() { "$REAL_TMUX" -L "$SOCK" "$@"; }
tmux_down() { X kill-server 2>/dev/null; true; }
tmux_up() { tmux_down; PATH="$B:/usr/bin:/bin" X -f /dev/null new -d -s t; }
sums() { find "$H" -type f ! -name '*.bak-*' | sort | while IFS= read -r f; do cksum "$f"; done; }
run() { env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" "$SHB" "$R/install.sh" "$@" >"$W/out" 2>&1; }
# BSD stat takes -f, GNU stat takes -c (on GNU, -f means "filesystem status").
if stat -c %a . >/dev/null 2>&1; then perms() { stat -c %a "$1"; }; else perms() { stat -f %Lp "$1"; }; fi

H=$W/home; B=$W/bin; R="$H/my plugins/tmux-agents"
mkdir -p "$R" && cp -R "$SRC"/. "$R"/
mkbin "$B" claude opencode codex
mkdir -p "$H/.claude" "$H/.config/opencode" "$H/.codex" "$W/dots"
printf 'set -g status-right "S"\nset -g window-status-format "#I #W"\nset -g window-status-current-format "#I #W*"\n' >"$W/dots/tmux.conf"
chmod 640 "$W/dots/tmux.conf"; ln -s "$W/dots/tmux.conf" "$H/.tmux.conf"
echo '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-hook"}]}]}}' >"$H/.claude/settings.json"
cp "$H/.claude/settings.json" "$W/orig-settings.json"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-codex-hook"}]}]}}' >"$H/.codex/hooks.json"
cp "$H/.codex/hooks.json" "$W/orig-codex-hooks.json"
# [features] exists but has no hooks line yet: the installer must insert into it.
printf 'model = "gpt-5"\n\n[features]\nother_feature = true\n\n[tui]\nscroll_acceleration = true\n' >"$H/.codex/config.toml"
cp "$H/.codex/config.toml" "$W/orig-codex-config.toml"
cp "$W/dots/tmux.conf" "$W/orig-tmux.conf"
echo '{"plugins":["/some/other"]}' >"$H/.config/opencode/cli.json"
OURCMD="'$R/bin/tmux-agents' claude-hook"
OURCMDX="'$R/bin/tmux-agents' codex-hook"
tmux_up

echo "A. dry run changes nothing"
s0=$(sums); h0=$(X show-hooks -g | wc -l)
run --dry-run; rc=$?
t "A exit 0" '[ $rc = 0 ]'
t "A files untouched" '[ "$(sums)" = "$s0" ]'
t "A no backups" '! ls "$H"/.claude/*.bak-* >/dev/null 2>&1'
t "A tmux untouched" '[ "$(X show-hooks -g | wc -l)" = "$h0" ]'
t "A shows changes" 'grep -q "would: add the hooks" "$W/out"'
t "A shows codex changes" 'grep -qF "add the hooks to $H/.codex/hooks.json" "$W/out" && grep -qF "enable [features] hooks = true in $H/.codex/config.toml" "$W/out"'

echo "B. install"
run; rc=$?
t "B exit 0" '[ $rc = 0 ]'
t "B symlink kept" '[ -L "$H/.tmux.conf" ]'
t "B permissions kept" '[ "$(perms "$W/dots/tmux.conf")" = 640 ]'
t "B run-shell line is last, quoted" 'tail -n 1 "$W/dots/tmux.conf" | grep -qF "run-shell \"'"'"'$R/tmux-agents.tmux'"'"'\""'
t "B hook on all 7 events" '[ "$(jq --arg c "$OURCMD" "[.hooks[][] | select(.hooks[0].command == \$c)] | length" "$H/.claude/settings.json")" = 7 ]'
t "B other settings and hooks kept" 'jq -e ".model == \"x\" and .hooks.Stop[0].hooks[0].command == \"other-hook\"" "$H/.claude/settings.json" >/dev/null'
t "B opencode plugin appended" 'jq -e --arg p "$R/opencode" ".plugins == [\"/some/other\", \$p]" "$H/.config/opencode/cli.json" >/dev/null'
t "B codex hooks on all 10 events" '[ "$(jq --arg c "$OURCMDX" "[.hooks[][] | select(.hooks[0].command == \$c)] | length" "$H/.codex/hooks.json")" = 10 ]'
t "B codex Interrupt/SessionEnd timeout 3 s (codex clamps higher)" '[ "$(jq "[.hooks.Interrupt[-1].hooks[0].timeout, .hooks.SessionEnd[-1].hooks[0].timeout] | join(\",\")" -r "$H/.codex/hooks.json")" = "3,3" ]'
t "B codex other hooks kept" 'jq -e ".hooks.Stop[0].hooks[0].command == \"other-codex-hook\"" "$H/.codex/hooks.json" >/dev/null'
t "B codex features inserted in section" 'grep -q "^hooks = true$" "$H/.codex/config.toml"'
t "B codex config kept" 'grep -q "^model = \"gpt-5\"$" "$H/.codex/config.toml" && grep -q "^\[tui\]" "$H/.codex/config.toml"'
t "B codex features before next section" '[ "$(grep -n "^hooks = true" "$H/.codex/config.toml" | cut -d: -f1)" -lt "$(grep -n "^\[tui\]" "$H/.codex/config.toml" | cut -d: -f1)" ]'
t "B 5 backups" '[ "$(ls "$H"/.tmux.conf.bak-* "$H"/.claude/settings.json.bak-* "$H"/.config/opencode/cli.json.bak-* "$H"/.codex/hooks.json.bak-* "$H"/.codex/config.toml.bak-* 2>/dev/null | wc -l | tr -d " ")" = 5 ]'
t "B key bound" 'X list-keys -T prefix a | grep -q "sidebar toggle"'
t "B tmux hooks 90-93" '[ "$(X show-hooks -g | grep -c "\[9[0-3]\]")" -ge 7 ] && X show-hooks -gw | grep -q "pane-exited\[92\]"'
t "B status-right sweep" 'X show -gv status-right | grep -q "sweep status"'
t "B tab icon in formats" 'X show -gwv window-status-format | grep -q "@agents-tab-icon"'
t "B no key conflict reported" '! grep -q "already bound" "$W/out"'
# A sidebar frame with an empty OpenCode part: tmux's s/// then yields the bare
# group number ("2"/"3"), which must show the hourglass, not a digit.
HG=$(awk '$1 == "@agents-tab-icon-working" { print $2 }' "$R/defaults.conf")
X new-window -d -t t 'exec sleep 600'; FW=$(X list-windows -t t -F '#{window_id}' | tail -n 1); FP=$(X list-panes -t "$FW" -F '#{pane_id}')
X set -p -t "$FP" @agents_sidebar 1; X select-pane -t "$FP" -T 'agents=x|||'
X set -w -t "$FW" @agent_win_state working; X set -w -t "$FW" @agent_win_agent opencode
TAB=$(X display -p -t "$FW" '#{E:@agents-tab-icon}')
t "B opencode tab: empty frame shows the hourglass" 'printf "%s" "$TAB" | grep -qF "$HG" && ! printf "%s" "$TAB" | grep -qE " [23](#|\$)"'
X kill-window -t "$FW"

echo "C. second run is a no-op"
s1=$(sums); nb=$(ls "$H"/.claude/*.bak-* | wc -l)
sleep 1; run; rc=$?
t "C exit 0" '[ $rc = 0 ]'
t "C no changes" '[ "$(sums)" = "$s1" ]'
t "C no new backups" '[ "$(ls "$H"/.claude/*.bak-* | wc -l)" = "$nb" ]'
t "C reports already" 'grep -q "hooks already in" "$W/out" && grep -q "already in $H/.tmux.conf" "$W/out" && grep -qF "hooks already in $H/.codex/hooks.json" "$W/out"'
t "C no other installs" 'grep -A1 "Other tmux-agents" "$W/out" | grep -q none'
t "C own live binding is no conflict" '! grep -q "already bound" "$W/out"'

echo "D. the installed hook drives tmux state"
P=$(X list-panes -t t -F "#{pane_id}")
SOCKPATH=$(X display -p '#{socket_path}')
HOOK=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$H/.claude/settings.json")
hook() { echo "{\"hook_event_name\":\"$1\",\"prompt\":\"SECRET\"}" | env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMUX_PANE="$P" TMUX_TMPDIR="$TS" TMUX="$SOCKPATH,1,0" sh -c "$HOOK"; }
hook SessionStart; hook UserPromptSubmit
t "D prompt -> working" '[ "$(X display -p -t "$P" "#{@agent}:#{@agent_state}")" = claude:working ]'
t "D window state" '[ "$(X display -p -t "$P" "#{@agent_win_state}")" = working ]'
t "D prompt text never stored" '! X show -p -t "$P" | grep -q SECRET'
hook Stop; st=$(X display -p -t "$P" "#{@agent_state}")
t "D Stop -> done/idle" '[ "$st" = done ] || [ "$st" = idle ]'
hook SessionEnd
t "D SessionEnd clears" '[ -z "$(X display -p -t "$P" "#{@agent}")" ]'

echo "D2. the installed codex hook drives the same state"
HOOKX=$(jq -r '.hooks.PermissionRequest[-1].hooks[0].command' "$H/.codex/hooks.json")
hookx() { echo "{\"hook_event_name\":\"$1\",\"prompt\":\"SECRET\"}" | env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMUX_PANE="$P" TMUX_TMPDIR="$TS" TMUX="$SOCKPATH,1,0" sh -c "$HOOKX"; }
hookx UserPromptSubmit
t "D2 codex prompt -> working" '[ "$(X display -p -t "$P" "#{@agent}:#{@agent_state}")" = codex:working ]'
hookx PermissionRequest
t "D2 permission -> blocked" '[ "$(X display -p -t "$P" "#{@agent}:#{@agent_state}")" = codex:blocked ]'
t "D2 codex payload never stored" '! X show -p -t "$P" | grep -q SECRET'
hookx Stop
t "D2 Stop -> done" '[ "$(X display -p -t "$P" "#{@agent_state}")" = done ]'
hookx Interrupt
t "D2 Interrupt -> idle" '[ "$(X display -p -t "$P" "#{@agent_state}")" = idle ]'
# A failed model request ends the turn without Stop: it must not stay "working".
hookx UserPromptSubmit
echo '{"hook_event_name":"PostModelRequest","status":"succeeded","error":"SECRET"}' | env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMUX_PANE="$P" TMUX_TMPDIR="$TS" TMUX="$SOCKPATH,1,0" sh -c "$HOOKX"
t "D2 successful request changes nothing" '[ "$(X display -p -t "$P" "#{@agent_state}")" = working ]'
echo '{"hook_event_name":"PostModelRequest","status":"failed","error":"SECRET"}' | env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMUX_PANE="$P" TMUX_TMPDIR="$TS" TMUX="$SOCKPATH,1,0" sh -c "$HOOKX"
t "D2 failed request -> blocked" '[ "$(X display -p -t "$P" "#{@agent_state}|#{@agent_note}")" = "blocked|request failed" ]'
t "D2 error text never stored" '! X show -p -t "$P" | grep -q SECRET'
hookx PreModelRequest
t "D2 retry (PreModelRequest) -> working" '[ "$(X display -p -t "$P" "#{@agent_state}")" = working ]'
hookx Stop; hookx PreModelRequest
t "D2 request outside a turn does not revive a finished card" '[ "$(X display -p -t "$P" "#{@agent_state}")" = done ]'
hookx SessionEnd
t "D2 SessionEnd clears" '[ -z "$(X display -p -t "$P" "#{@agent}")" ]'

echo "E. uninstall restores the originals and clears runtime state"
hook SessionStart; hook UserPromptSubmit                         # live agent state
hookx UserPromptSubmit                                           # live codex state
X new-window -d -t t 'exec sleep 600'; SB=$(X list-panes -a -F '#{pane_id}' | tail -n 1)
X set -p -t "$SB" @agents_sidebar 1; X set -g @agents_sidebar_on 1      # fake open sidebar
X split-window -d -t t 'exec sleep 600'; TO=$(X list-panes -t t -F '#{pane_id}' | tail -n 1)
X set -p -t "$TO" @agents_toast 1                                       # fake toast
WIN=$(X display -p -t "$SB" '#{window_id}'); X set -w -t "$WIN" pane-active-border-style fg=red; X set -w -t "$WIN" @agents_border_hidden 1
X set -g @agents_flash_id 123; X set -g @agents-notify-on blocked       # runtime + a user setting
run --uninstall; rc=$?
t "E exit 0" '[ $rc = 0 ]'
t "E settings.json restored" '[ "$(jq -cS . "$H/.claude/settings.json")" = "$(jq -cS . "$W/orig-settings.json")" ]'
t "E codex hooks.json restored" '[ "$(jq -cS . "$H/.codex/hooks.json")" = "$(jq -cS . "$W/orig-codex-hooks.json")" ]'
t "E codex features left enabled" 'grep -q "^hooks = true$" "$H/.codex/config.toml" && grep -q "^model = \"gpt-5\"$" "$H/.codex/config.toml"'
t "E cli.json restored" 'jq -e ".plugins == [\"/some/other\"]" "$H/.config/opencode/cli.json" >/dev/null'
t "E tmux.conf line removed" '! grep -q tmux-agents "$W/dots/tmux.conf"'
t "E tmux.conf byte-identical to original" 'cmp -s "$W/dots/tmux.conf" "$W/orig-tmux.conf"'
t "E sidebar and toast panes closed" '! X list-panes -a -F "#{pane_id}" | grep -qx -e "$SB" -e "$TO"'
t "E pane state cleared" '[ -z "$(X display -p -t "$P" "#{@agent}#{@agent_state}#{@agent_since}")" ]'
t "E window state cleared" '[ -z "$(X list-windows -a -F "#{@agent_win_state}#{@agent_win_agent}#{@agents_border_hidden}" | tr -d "\n")" ]'
t "E hidden border restored" '! X list-windows -a -F "#{window_id}" | while read -r w; do X show -wv -t "$w" pane-active-border-style 2>/dev/null; done | grep -q red'
t "E runtime globals cleared" '! X show -g | grep -q -e "^@agents_" -e "^@agents-tab-icon"'
t "E user settings kept" '[ "$(X show -gv @agents-notify-on)" = blocked ]'
t "E restart warning for running Claude sessions" 'grep -q "keep calling the hook until restarted" "$W/out"'
t "E tmux.conf still a symlink" '[ -L "$H/.tmux.conf" ]'
t "E key unbound" '! X list-keys -T prefix a 2>/dev/null | grep -q "sidebar toggle"'
t "E tmux hooks removed" '[ "$(X show-hooks -g | grep -c "\[9[0-3]\]")" = 0 ]'
run --uninstall; rc=$?
t "E second uninstall is harmless" '[ $rc = 0 ] && grep -q "not in" "$W/out"'

echo "F. fresh HOME, tmux not running, no agents installed"
Bfull=$B; B=$W/bin-bare; mkbin "$B"; H=$W/fresh; mkdir -p "$H"; tmux_down
run; rc=$?
t "F exit 0" '[ $rc = 0 ]'
t "F tmux.conf created" 'grep -qF "$R/tmux-agents.tmux" "$H/.tmux.conf"'
t "F claude skipped" '[ ! -e "$H/.claude" ] && grep -q "not installed, skipped" "$W/out"'
t "F codex skipped" '[ ! -e "$H/.codex" ]'
t "F says tmux not running" 'grep -q "tmux is not running" "$W/out"'
B=$Bfull

echo "G. invalid JSON is reported and left alone"
H=$W/bad; mkdir -p "$H/.claude" "$H/.config/opencode" "$H/.codex"
printf '{ "hooks": { broken\n' >"$H/.claude/settings.json"; cp "$H/.claude/settings.json" "$W/bad.json"
printf '{ broken\n' >"$H/.codex/hooks.json"; cp "$H/.codex/hooks.json" "$W/bad-codex-hooks.json"
echo 'model = "gpt-5"' >"$H/.codex/config.toml"
echo '{}' >"$H/.config/opencode/cli.json"
run; rc=$?
t "G exit 0" '[ $rc = 0 ]'
t "G error reported" 'grep -q "is not valid JSON" "$W/out"'
t "G not claimed as installed" '! grep -q "hooks already in" "$W/out"'
t "G file untouched" 'cmp -s "$H/.claude/settings.json" "$W/bad.json"'
t "G codex hooks untouched" 'cmp -s "$H/.codex/hooks.json" "$W/bad-codex-hooks.json"'
t "G codex features skipped after bad JSON" '! grep -q "\[features\]" "$H/.codex/config.toml"'
t "G later steps still run" 'jq -e --arg p "$R/opencode" ".plugins == [\$p]" "$H/.config/opencode/cli.json" >/dev/null'

echo "H. other copies, commented lines, ~ form"
H=$W/old; mkdir -p "$H/.claude" "$H/.codex"
printf '# run-shell "%s/tmux-agents.tmux"\nrun-shell ~/old/tmux-agents/tmux-agents.tmux\n' "$R" >"$H/.tmux.conf"
echo "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"'/x/old/tmux-agents/bin/tmux-agents' claude-hook\"}]}]}}" >"$H/.claude/settings.json"
echo "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"'/x/old/tmux-agents/bin/tmux-agents' codex-hook\"}]}]}}" >"$H/.codex/hooks.json"
printf 'model = "x"\n' >"$H/.codex/config.toml"
run --no-opencode; rc=$?
t "H exit 0" '[ $rc = 0 ]'
t "H commented line does not count" '[ "$(grep -c "^run-shell" "$H/.tmux.conf")" = 2 ]'
t "H old tmux line reported" 'grep -q "old/tmux-agents/tmux-agents.tmux" "$W/out"'
t "H old hook reported" 'grep -q "hook 1x .*/x/old/tmux-agents" "$W/out"'
t "H old hook left alone" 'jq -e ".hooks.Stop[0].hooks[0].command | test(\"/x/old/\")" "$H/.claude/settings.json" >/dev/null'
t "H old codex hook left alone" 'jq -e ".hooks.Stop[0].hooks[0].command | test(\"/x/old/\")" "$H/.codex/hooks.json" >/dev/null'
t "H codex features appended" 'grep -q "^\[features\]" "$H/.codex/config.toml" && grep -q "^hooks = true" "$H/.codex/config.toml" && grep -q "^model = \"x\"$" "$H/.codex/config.toml"'
H=$W/tilde; mkdir -p "$H"; R_T="~${R#"$W/home"}"
H=$W/home; printf 'run-shell "%s/tmux-agents.tmux"\n' "$R_T" >"$W/dots/tmux.conf"
run --no-claude --no-opencode
t "H ~ form recognised" 'grep -q "already in" "$W/out"'

echo "I. XDG tmux.conf"
H=$W/xdg; mkdir -p "$H/.config/tmux"; echo 'set -g mouse on' >"$H/.config/tmux/tmux.conf"
run --no-claude --no-opencode
t "I XDG config used" 'grep -qF "$R/tmux-agents.tmux" "$H/.config/tmux/tmux.conf" && [ ! -e "$H/.tmux.conf" ]'

echo "J. key conflicts"
H=$W/keys; mkdir -p "$H"
printf 'set -g mouse on\nbind a last-window\nbind -n a display root\nbind -T copy-mode a display copy\n' >"$H/.tmux.conf"
run --dry-run --no-claude --no-opencode
t "J conf binding reported with line" 'grep -q "prefix + a is already bound in $H/.tmux.conf:2: bind a last-window" "$W/out"'
t "J root and copy-mode tables ignored" '[ "$(grep -c "already bound" "$W/out")" = 1 ]'
t "J hint shown" 'grep -q "set -g @agents-key <key>" "$W/out"'
printf 'set -g @agents-key "A"\nbind a last-window\n' >"$H/.tmux.conf"
run --no-claude --no-opencode
t "J custom key: no conflict" '! grep -q "already bound" "$W/out"'
t "J custom key in messages" 'grep -q "Press prefix + A" "$W/out"'
H=$W/keys2; mkdir -p "$H"; echo 'set -g mouse on' >"$H/.tmux.conf"
tmux_up; X bind-key a display-message hi
run --dry-run --no-claude --no-opencode
t "J live binding reported" 'grep -q "prefix + a is already bound to \"display-message hi\" in the running tmux server" "$W/out"'
printf '# bind a last-window\n' >>"$H/.tmux.conf"; X unbind-key a
run --dry-run --no-claude --no-opencode
t "J commented binding ignored" '! grep -q "already bound" "$W/out"'

echo "J2. codex config.toml shapes"
CX="--no-tmux --no-claude --no-opencode"
# hooks = true in another table must not count as "enabled".
H=$W/cx1; mkdir -p "$H/.codex"; printf '[mcp_servers.x]\nhooks = true\n' >"$H/.codex/config.toml"
run $CX
t "J2 hooks = true in another table does not count" 'grep -q "^\[features\]" "$H/.codex/config.toml" && [ "$(grep -c "^hooks = true" "$H/.codex/config.toml")" = 2 ]'
# Multi-line array lines that start with [ are not table headers.
H=$W/cx2; mkdir -p "$H/.codex"; printf '[features]\nlist = [\n  ["a", "b"],\n  ["c", "d"],\n]\n\n[tui]\nx = 1\n' >"$H/.codex/config.toml"
run $CX
t "J2 array lines are not headers: hooks after the array" '[ "$(grep -n "^hooks = true" "$H/.codex/config.toml" | cut -d: -f1)" -gt "$(grep -n "^\]" "$H/.codex/config.toml" | cut -d: -f1)" ] && [ "$(grep -n "^hooks = true" "$H/.codex/config.toml" | cut -d: -f1)" -lt "$(grep -n "^\[tui\]" "$H/.codex/config.toml" | cut -d: -f1)" ]'
# features = false flipped, the rest kept; already true -> untouched, no backup.
H=$W/cx3; mkdir -p "$H/.codex"; printf '[features]\nhooks = false # off\nother = 1\n' >"$H/.codex/config.toml"
run $CX
t "J2 hooks = false flipped" 'grep -q "^hooks = true" "$H/.codex/config.toml" && grep -q "^other = 1" "$H/.codex/config.toml" && ! grep -q "hooks = false" "$H/.codex/config.toml"'
cp "$H/.codex/config.toml" "$W/cx3.toml"; sleep 1; run $CX
t "J2 already true: file untouched" 'cmp -s "$H/.codex/config.toml" "$W/cx3.toml" && [ "$(ls "$H"/.codex/config.toml.bak-* | wc -l | tr -d " ")" = 1 ]'
# Dotted key / inline table: never a second [features] table.
H=$W/cx4; mkdir -p "$H/.codex"; printf 'features.other = true\n' >"$H/.codex/config.toml"; cp "$H/.codex/config.toml" "$W/cx4.toml"
run $CX
t "J2 dotted features: left alone, user told" 'cmp -s "$H/.codex/config.toml" "$W/cx4.toml" && grep -q "dotted key or inline table" "$W/out"'
H=$W/cx5; mkdir -p "$H/.codex"; printf 'features.hooks = true\n' >"$H/.codex/config.toml"; cp "$H/.codex/config.toml" "$W/cx5.toml"
run $CX
t "J2 features.hooks = true: already enabled" 'cmp -s "$H/.codex/config.toml" "$W/cx5.toml" && grep -q "features.hooks = true already" "$W/out"'
# Uninstall only drops what it emptied, and a file it created.
H=$W/cx6; mkdir -p "$H/.codex"; echo '{"hooks":{"PreCompact":[]}}' >"$H/.codex/hooks.json"
run $CX; run --uninstall $CX
t "J2 uninstall keeps an unrelated empty list, drops what it emptied" 'jq -e "(.hooks | keys) == [\"PreCompact\"] and .hooks.PreCompact == []" "$H/.codex/hooks.json" >/dev/null'
H=$W/cx7; mkdir -p "$H/.codex"
run $CX; run --uninstall $CX
t "J2 uninstall removes a hooks.json it created" '[ ! -e "$H/.codex/hooks.json" ] && grep -q "removed the now empty" "$W/out"'
t "J2 new config.toml has no leading blank line" '[ ! -e "$H/.codex/config.toml" ] || [ "$(head -n 1 "$H/.codex/config.toml")" = "[features]" ]'
H=$W/cx8; mkdir -p "$H/.codex" "$W/cx8dots"; echo '{}' >"$W/cx8dots/hooks.json"; ln -s "$W/cx8dots/hooks.json" "$H/.codex/hooks.json"
run $CX; run --uninstall $CX
t "J2 uninstall keeps a symlinked hooks.json" '[ -L "$H/.codex/hooks.json" ] && jq -e ".hooks == {}" "$W/cx8dots/hooks.json" >/dev/null'
# Tidy: hooks = true right after the table's last entry, before blank lines.
H=$W/cx10; mkdir -p "$H/.codex"; printf 'a = 1\n\n[features]\nx = true\n\n\n[features.sub]\ny = 1\n' >"$H/.codex/config.toml"
run $CX
t "J2 hooks = true right after the last entry" '[ "$(cat "$H/.codex/config.toml")" = "$(printf "a = 1\n\n[features]\nx = true\nhooks = true\n\n\n[features.sub]\ny = 1")" ]'
H=$W/cx11; mkdir -p "$H/.codex"; printf '[features]\nx = true\n\n' >"$H/.codex/config.toml"
run $CX
t "J2 table at end of file: blank lines kept after hooks" '[ "$(od -c "$H/.codex/config.toml" | tr -s " " | tr -d "\n")" = "$(printf "[features]\nx = true\nhooks = true\n\n" | od -c | tr -s " " | tr -d "\n")" ]'
H=$W/cx9; mkdir -p "$H/.codex"; run $CX
t "J2 created config.toml starts with [features]" '[ "$(head -n 1 "$H/.codex/config.toml")" = "[features]" ]'

echo "K. errors and options"
H=$W/notmux; mkdir -p "$H"; Bfull=$B
# A PATH with no tmux at all (Linux ships one in /usr/bin; a stock macOS does
# not): just the four tools install.sh needs before it can exit.
B=$W/bin-notmux; mkdir -p "$B"
for tool in sh dirname sed date mktemp rm; do ln -sf "$(command -v "$tool")" "$B/$tool"; done
env -i HOME="$H" PATH="$B" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" "$SHB" "$R/install.sh" >"$W/out" 2>&1; rc=$?
t "K no tmux: exit 1" '[ $rc = 1 ] && grep -q "tmux not found" "$W/out"'
B=$Bfull
run --bogus; rc=$?
t "K bad option: exit 2" '[ $rc = 2 ]'
run --help
t "K help" 'grep -q -- "--dry-run" "$W/out"'

echo "L. cleanup"
t "L no temp files left" '[ -z "$(ls -A "$TMPDIR")" ]'

tmux_down
echo "[$SH] passed $pass, failed $failn"
rm -rf "$W" "$TS"
[ "$failn" = 0 ]
