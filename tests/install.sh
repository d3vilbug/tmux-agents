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
# The server gets a dummy HOME: a "~" in a config it sources (e.g. TPM's run
# line) must never reach the real home of whoever runs the tests.
tmux_up() { tmux_down; mkdir -p "$W/srvhome"; HOME="$W/srvhome" PATH="$B:/usr/bin:/bin" X -f /dev/null new -d -s t; }
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
t "B tmux hooks 90-93" '[ "$(X show-hooks -g | grep -c "\[9[0-3]\]")" -ge 7 ] && X show-hooks -gw | grep -q "pane-exited\[92\]" && X show-hooks -gw | grep -q "pane-moved\[95\]" && X show-hooks -gw | grep -q "window-resized\[96\].*resize-pane"'
t "B follow hooks move the sidebar in the hook (no flash)" 'X show-hooks -g "session-window-changed[90]" | grep -q "join-pane" && X show-hooks -g "client-session-changed[90]" | grep -q "join-pane" && X show-hooks -g "session-window-changed[90]" | grep -q "sidebar follow"'
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

echo "C2. re-running restarts open sidebars on the new code"
SBX=$(X new-window -d -P -F '#{pane_id}' -t t 'exec sleep 600'); X set -p -t "$SBX" @agents_sidebar 1   # an "old" sidebar
run --dry-run
t "C2 dry run lists the restart" 'grep -q "would: restart 1 open sidebar" "$W/out"'
t "C2 dry run leaves the sidebar alone" 'X display -p -t "$SBX" "#{pane_start_command}" | grep -q "sleep 600"'
run; rc=$?
if [ -n "$REAL_BUN" ]; then
  t "C2 sidebar restarted in place on this copy" '[ $rc = 0 ] && grep -q "restarted 1 open sidebar" "$W/out" && X display -p -t "$SBX" "#{pane_start_command}" | grep -qF "$R/sidebar/sidebar.ts" && [ "$(X display -p -t "$SBX" "#{pane_dead}:#{@agents_sidebar}")" = "0:1" ]'
else
  t "C2 no bun: sidebar left, user told" 'grep -q "bun not found" "$W/out"'
fi
X kill-pane -t "$SBX"

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
# A window whose own border style the sidebar hid: it comes back.
BW=$(X new-window -d -P -F '#{window_id}' -t t: 'exec sleep 600'); X set -w -t "$BW" pane-active-border-style fg=yellow
X set -w -t "$BW" @agents_border_saved fg=yellow; X set -w -t "$BW" pane-active-border-style fg=grey; X set -w -t "$BW" @agents_border_hidden fg=grey
X set -g @agents_flash_id 123; X set -g @agents-notify-on blocked       # runtime + a user setting
# An active sidebar-aware zoom: fake sidebar + 2 panes, the right one moved out.
X set -g @agents-zoom-keeps-sidebar on; X run-shell "'$R/tmux-agents.tmux'"
ZL=$(X new-window -d -P -F '#{pane_id}' -t t: 'exec sleep 600'); ZW=$(X display -p -t "$ZL" '#{window_id}')
ZR=$(X split-window -d -h -P -F '#{pane_id}' -t "$ZL" 'exec sleep 600')
ZS=$(X split-window -hbf -d -l 22 -P -F '#{pane_id}' -t "$ZL" 'exec sleep 600'); X set -p -t "$ZS" @agents_sidebar 1
env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMUX_TMPDIR="$TS" TMUX="$SOCKPATH,1,0" "$R/bin/tmux-agents" zoom toggle "$ZW" "$ZL"
t "E zoom active before uninstall" '[ "$(X display -p -t "$ZR" "#{session_name}")" = _agents_zoom ] && X list-keys -T prefix z | grep -q "zoom toggle"'
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
t "E your own border style back" '[ "$(X show -wv -t "$BW" pane-active-border-style)" = fg=yellow ] && [ -z "$(X show -wqv -t "$BW" @agents_border_saved)" ]'
t "E hidden border restored" '! X list-windows -a -F "#{window_id}" | while read -r w; do X show -wv -t "$w" pane-active-border-style 2>/dev/null; done | grep -q red'
t "E runtime globals cleared" '! X show -g | grep -q -e "^@agents_" -e "^@agents-tab-icon"'
t "E user settings kept" '[ "$(X show -gv @agents-notify-on)" = blocked ]'
t "E zoom undone: moved pane back home" '[ "$(X display -p -t "$ZR" "#{window_id}")" = "$ZW" ] && ! X list-sessions -F "#{session_name}" | grep -qx _agents_zoom'
t "E prefix + z is tmux zoom again" 'X list-keys -T prefix z | grep -q "resize-pane -Z"'
t "E zoom state cleared" '[ -z "$(X display -p -t "$ZW" "#{@agents_zoom}#{@agents_zoom_layout}")$(X show -gqv @agents_zoom_bound)" ]'
t "E restart warning for running Claude sessions" 'grep -q "keep calling the hook until restarted" "$W/out"'
t "E tmux.conf still a symlink" '[ -L "$H/.tmux.conf" ]'
t "E key unbound" '! X list-keys -T prefix a 2>/dev/null | grep -q "sidebar toggle"'
t "E tmux hooks removed" '[ "$(X show-hooks -g | grep -c "\[9[0-3]\]")" = 0 ] && ! X show-hooks -gw | grep -q "\[9[0-6]\]"'
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

echo "T. TPM: plugin line, setup popup, uninstall"
TPMCONF='set -g @plugin '"'"'tmux-plugins/tpm'"'"'\nset -g @plugin '"'"'d3vilbug/tmux-agents'"'"'\nrun '"'"'~/.tmux/plugins/tpm/tpm'"'"'\n'
H=$W/tpm; mkdir -p "$H/.claude"; printf "$TPMCONF" >"$H/.tmux.conf"; cp "$H/.tmux.conf" "$W/tpm.conf"
run --no-claude --no-codex --no-opencode
t "T TPM-managed: no run-shell line added" 'cmp -s "$H/.tmux.conf" "$W/tpm.conf" && grep -q "loaded by TPM" "$W/out"'
printf 'run-shell "%s/tmux-agents.tmux"\n' "$R" >>"$H/.tmux.conf"
run --no-claude --no-codex --no-opencode
t "T TPM plus run-shell line: warned it loads twice" 'grep -q "it loads twice" "$W/out"'
cp "$W/tpm.conf" "$H/.tmux.conf"
env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" "$SHB" "$R/install.sh" --check-setup; rc=$?
t "T check-setup: hooks missing -> 0" '[ $rc = 0 ]'
printf 'n\n\n' | run --setup
t "T setup, not now: nothing changed" '! grep -q tmux-agents "$H/.claude/settings.json" 2>/dev/null && cmp -s "$H/.tmux.conf" "$W/tpm.conf" && grep -q "Not now" "$W/out"'
printf 'y\n\n' | run --setup
t "T setup, yes: claude hooks added" '[ "$(jq --arg c "$OURCMD" "[.hooks[][] | select(.hooks[0].command == \$c)] | length" "$H/.claude/settings.json")" = 7 ]'
t "T setup, yes: tmux.conf untouched" 'cmp -s "$H/.tmux.conf" "$W/tpm.conf"'
env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" "$SHB" "$R/install.sh" --check-setup; rc=$?
t "T check-setup: all connected -> 1" '[ $rc = 1 ]'
printf '\n' | run --setup
t "T setup with nothing to do says so" 'grep -q "Nothing to do" "$W/out"'
H=$W/tpm2; mkdir -p "$H/.claude"; printf "$TPMCONF" >"$H/.tmux.conf"
printf 'x\n\n' | run --setup
t "T setup, never: opt-out line before the TPM run line" '[ "$(grep -n "@agents-setup-prompt off" "$H/.tmux.conf" | cut -d: -f1)" -lt "$(grep -n "tpm/tpm" "$H/.tmux.conf" | cut -d: -f1)" ] && ! [ -s "$H/.claude/settings.json" ]'
# The popup trigger (bin/tmux-agents setup-prompt) against the test server.
tmux_up
SP() { env -i HOME="$H" PATH="$B:/usr/bin:/bin" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" TMUX="$(X display -p '#{socket_path}'),1,0" "$R/bin/tmux-agents" setup-prompt nosuchclient; }
H=$W/tpm3; mkdir -p "$H/.claude"; printf "$TPMCONF" >"$H/.tmux.conf"
SP
t "T prompt: TPM user with hooks missing is asked (once)" '[ "$(X show -gqv @agents_setup_prompted)" = 1 ]'
X set -gu @agents_setup_prompted; X set -g @agents-setup-prompt off; SP
t "T prompt: opted out -> not asked" '[ -z "$(X show -gqv @agents_setup_prompted)" ]'
X set -gu @agents-setup-prompt
printf 'run-shell "%s/tmux-agents.tmux"\n' "$R" >"$H/.tmux.conf"; SP
t "T prompt: install.sh user -> not asked" '[ -z "$(X show -gqv @agents_setup_prompted)" ]'
# A fake TPM that does what TPM does: run every plugin's *.tmux file.
H=$W/tpm; mkdir -p "$H/.tmux/plugins/tpm"; printf '#!/bin/sh\n"%s/tmux-agents.tmux"\n' "$R" >"$H/.tmux/plugins/tpm/tpm"; chmod +x "$H/.tmux/plugins/tpm/tpm"
# Its run line by absolute path (the server's ~ is the dummy HOME).
printf 'set -g @plugin %s\nrun %s\n' "'d3vilbug/tmux-agents'" "'$H/.tmux/plugins/tpm/tpm'" >"$H/.tmux.conf"
tmux_up; X source-file "$H/.tmux.conf"
t "T loaded through (fake) TPM: key, hooks, in-hook sidebar move" 'X list-keys -T prefix a | grep -q "sidebar toggle" && X show-hooks -g "session-window-changed[90]" | grep -q "join-pane" && X show-hooks -g | grep -q "client-attached\[94\]"'
run --uninstall --no-claude --no-codex --no-opencode
t "T uninstall: told to remove the @plugin line" 'grep -q "remove the @plugin line" "$W/out"'
t "T uninstall: client-attached hook removed" '! X show-hooks -g | grep -q "client-attached\[94\]"'
t "T uninstall with the @plugin line still there: not reloaded by TPM" '! X list-keys -T prefix a 2>/dev/null | grep -q "sidebar toggle" && [ "$(X show-hooks -g | grep -c "\[9[0-4]\]")" = 0 ] && ! X show -gv status-right | grep -q "sweep status" && ! X show -gwv window-status-format | grep -q agents-tab-icon'
# --setup --dry-run writes nothing; x twice adds the opt-out line once.
H=$W/tpm4; mkdir -p "$H/.claude"; printf "$TPMCONF" >"$H/.tmux.conf"; cp "$H/.tmux.conf" "$W/tpm4.conf"
printf 'y\n\n' | run --setup --dry-run
t "T setup --dry-run, yes: nothing written" '! [ -s "$H/.claude/settings.json" ] && cmp -s "$H/.tmux.conf" "$W/tpm4.conf"'
printf 'x\n\n' | run --setup --dry-run
t "T setup --dry-run, never: tmux.conf untouched" 'cmp -s "$H/.tmux.conf" "$W/tpm4.conf"'
printf 'x\n\n' | run --setup; printf 'x\n\n' | run --setup
t "T setup, never twice: one opt-out line" '[ "$(grep -c "@agents-setup-prompt off" "$H/.tmux.conf")" = 1 ] && grep -q "already off" "$W/out"'
# Another plugin whose name only starts with tmux-agents is not this one.
H=$W/tpm5; mkdir -p "$H"; printf "set -g @plugin 'someone/tmux-agents-extra'\n" >"$H/.tmux.conf"
run --no-claude --no-codex --no-opencode
t "T @plugin of tmux-agents-extra is not TPM-managed" 'grep -qF "run-shell" "$H/.tmux.conf" && ! grep -q "loaded by TPM" "$W/out"'
tmux_down

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

echo "M. edge cases: read-only files, whitespace JSON, XDG elsewhere, no jq, if-shell @plugin, CRLF, a key bound by hand"
H=$W/ro; mkdir -p "$H/.claude"; echo '{}' >"$H/.claude/settings.json"; chmod 444 "$H/.claude/settings.json"
run --no-tmux --no-codex --no-opencode; rc=$?
t "M read-only settings.json: exit 1, says so, no false success" '[ $rc = 1 ] && grep -q "cannot write $H/.claude/settings.json" "$W/out" && ! grep -q "✓ add the Claude hooks\|✓ hooks already" "$W/out" && [ "$(cat "$H/.claude/settings.json")" = "{}" ]'
chmod 644 "$H/.claude/settings.json"
H=$W/ws; mkdir -p "$H/.claude"; printf '\n  \n' >"$H/.claude/settings.json"
run --no-tmux --no-codex --no-opencode
t "M whitespace-only settings.json: hooks added in one run" '[ "$(jq --arg c "$OURCMD" "[.hooks[][] | select(.hooks[0].command == \$c)] | length" "$H/.claude/settings.json")" = 7 ]'
H=$W/xdg2; mkdir -p "$H/.config/tmux" "$H/xdg"; echo 'set -g mouse on' >"$H/.config/tmux/tmux.conf"
env -i HOME="$H" XDG_CONFIG_HOME="$H/xdg" PATH="$B:/usr/bin:/bin" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" "$SHB" "$R/install.sh" --no-claude --no-codex --no-opencode >"$W/out" 2>&1
t "M XDG_CONFIG_HOME elsewhere: ~/.config/tmux/tmux.conf used, no new ~/.tmux.conf" 'grep -qF "$R/tmux-agents.tmux" "$H/.config/tmux/tmux.conf" && [ ! -e "$H/.tmux.conf" ]'
# No jq: a PATH with only the tools install.sh needs (some systems ship /usr/bin/jq).
H=$W/nojq; mkdir -p "$H/.claude"; run --no-tmux --no-codex --no-opencode
B2=$W/bin-nojq; mkdir -p "$B2"; cp "$B/tmux" "$B2/tmux"
for tool in sh dirname sed date mktemp rm grep cat cp mkdir cmp diff tr cut head tail wc awk printf ls sort; do p=$(command -v "$tool") && [ "${p#/}" != "$p" ] && ln -sf "$p" "$B2/$tool"; done
env -i HOME="$H" PATH="$B2" TMPDIR="$TMPDIR" TMUX_TMPDIR="$TS" "$SHB" "$R/install.sh" --uninstall --no-tmux --no-codex --no-opencode >"$W/out" 2>&1; rc=$?
t "M uninstall without jq: not reported done, hooks kept, exit 1" '[ $rc = 1 ] && grep -q "jq is needed" "$W/out" && grep -q "Not fully uninstalled" "$W/out" && ! grep -q "can be deleted" "$W/out" && grep -q tmux-agents "$H/.claude/settings.json"'
H=$W/ifshell; mkdir -p "$H"; printf '%s\n' "if-shell 'true' \"set -g @plugin 'd3vilbug/tmux-agents'\"" >"$H/.tmux.conf"
run --no-claude --no-codex --no-opencode
t "M @plugin inside if-shell is not a TPM install: run-shell line added" 'grep -qF "$R/tmux-agents.tmux" "$H/.tmux.conf"'
H=$W/crlf; mkdir -p "$H"; printf 'set -g @agents-key A\r\nbind A last-window\r\n' >"$H/.tmux.conf"
run --dry-run --no-claude --no-codex --no-opencode
t "M CRLF tmux.conf: key read without the CR, conflict found" 'grep -q "prefix + A is already bound" "$W/out" && ! grep -q "prefix + A$(printf "\r")" "$W/out"'
tmux_up; X bind-key a display-message mine
H=$W/neverinst; mkdir -p "$H"; run --uninstall --no-claude --no-codex --no-opencode
t "M uninstall when never installed: a prefix + a bound by hand stays" 'X list-keys -T prefix a | grep -q "display-message mine"'

echo "L. cleanup"
t "L no temp files left" '[ -z "$(ls -A "$TMPDIR")" ]'

tmux_down
echo "[$SH] passed $pass, failed $failn"
rm -rf "$W" "$TS"
[ "$failn" = 0 ]
