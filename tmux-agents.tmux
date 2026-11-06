#!/bin/sh
# tmux-agents entry point. Load AFTER your theme (it decorates the theme's
# window-status formats and status-right), e.g. at the end of ~/.tmux.conf:
#   run-shell ~/.tmux/plugins/tmux-agents/tmux-agents.tmux
# Defaults live in defaults.conf; override with `set -g @agents-...`.

ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="$ROOT/bin/tmux-agents"

opt() {
  v=$(tmux show -gqv "$1")
  [ -n "$v" ] || v=$(awk -v k="$1" '$1 == k { sub(/^[^ ]+ ?/, ""); print; exit }' "$ROOT/defaults.conf")
  printf '%s' "$v"
}

# Focus events let the hooks know whether the terminal window is focused,
# so a finished agent you are looking at does not notify.
tmux set -g focus-events on
# The global active-border style, so the hook that hides the border can tell a
# per-window style of yours from the global one (kept fresh by sync_borders).
tmux set -g @agents_border_global "$(tmux show -gwv pane-active-border-style)"

# prefix + a: toggle the Agents sidebar.
tmux bind-key "$(opt @agents-key)" run-shell -b "'$BIN' sidebar toggle '#{session_id}' '#{window_id}'"

# prefix + z: zoom that keeps the sidebar visible (opt-in). Off again: back to
# tmux's own zoom, and undo any zoom of ours that is still active.
if [ "$(opt @agents-zoom-keeps-sidebar)" = on ]; then
  tmux bind-key z run-shell -b "'$BIN' zoom toggle '#{window_id}' '#{pane_id}'"
  tmux set -g @agents_zoom_bound 1
elif [ "$(tmux show -gqv @agents_zoom_bound)" = 1 ]; then
  tmux bind-key z resize-pane -Z
  tmux set -gu @agents_zoom_bound
  "$BIN" zoom restore-all
fi

# Fixed hook indexes (90-96) so re-sourcing replaces instead of duplicating,
# and other plugins' hooks stay untouched.
follow="run-shell -b \"'$BIN' sidebar follow '#{session_id}' '#{window_id}'\""
# The sidebar moves to the new window inside the hook itself, with plain tmux
# commands: tmux runs them before it redraws, so the window never shows up
# without the sidebar. The background follow alone lands ~0.2 s later (a
# visible flash), and so would run-shell -C (it runs on a timer, after a
# redraw). Targets are not format-expanded, so the hook names the sidebar by
# position: the full-height left pane of the window you came from, `!.{top-left}`.
# Only that plain case, else nothing moves here:
# - sidebar on, not the zoom's hidden session;
# - the window you came from: not zoomed (`{top-left}` would be the zoomed
#   pane), more than the sidebar tiled in it (it would close), its top-left
#   pane is the sidebar and no floating pane covers that corner (`{top-left}`
#   would pick the floating one);
# - this window: no sidebar yet, not zoomed, no floating pane in the top-left
#   corner (cannot join next to it), wide enough for the sidebar plus 12.
# Everything else is left to the background follow (which then finds the
# sidebar already in place).
sb_w="#{?@agents_sidebar_width_saved,#{@agents_sidebar_width_saved},$(opt @agents-sidebar-width)}"
sb_float_tl='#{&&:#{pane_floating_flag},#{e|<=:#{pane_left},1},#{e|<=:#{pane_top},1}}'
sb_last="#{W:#{?#{&&:#{window_last_flag},#{!=:#{window_zoomed_flag},1},#{!=:#{P:#{?pane_floating_flag,,1}},1}},#{P:#{?#{&&:#{pane_at_left},#{pane_at_top},#{@agents_sidebar}},S,}#{?$sb_float_tl,F,}},}}"
sb_here="#{P:#{?@agents_sidebar,S,}#{?$sb_float_tl,F,}}"
sb_cond="#{&&:#{@agents_sidebar_on},#{!=:#{session_name},_agents_zoom},#{!=:#{window_zoomed_flag},1},#{e|>=:#{window_width},#{e|+:$sb_w,12}},#{==:$sb_here,},#{==:$sb_last,S}}"
sb_move="join-pane -hbf -d -l \"$sb_w\" -s \"!.{top-left}\" -t \"{top-left}\""
# Borders (see sync_borders in bin/tmux-agents): hide the active border here,
# keeping a border style you set on this window yourself in
# @agents_border_saved (a value equal to the global one is not yours:
# @agents_border_global; the background follow re-checks it) and the style
# set in @agents_border_hidden. Then the window you left gets yours back,
# unless you changed it meanwhile.
sb_move="$sb_move ; if -F \"#{==:#{@agents_border_hidden},}\" {"
sb_move="$sb_move if -F \"#{!=:#{pane-active-border-style},#{@agents_border_global}}\" { set -wF @agents_border_saved \"#{pane-active-border-style}\" }"
sb_move="$sb_move ; set -wF pane-active-border-style \"#{pane-border-style}\" ; set -wF @agents_border_hidden \"#{pane-border-style}\" }"
sb_ours='#{&&:#{@agents_border_hidden},#{||:#{==:#{@agents_border_hidden},1},#{==:#{pane-active-border-style},#{@agents_border_hidden}}}}'
sb_move="$sb_move ; if -F -t \"!\" \"$sb_ours\" { if -F -t \"!\" \"#{@agents_border_saved}\" { set -wF -t \"!\" pane-active-border-style \"#{@agents_border_saved}\" } { set -wu -t \"!\" pane-active-border-style } }"
sb_move="$sb_move ; set -wu -t \"!\" @agents_border_hidden ; set -wu -t \"!\" @agents_border_saved"
follow="if -F '$sb_cond' { $sb_move } ; $follow"
seen="run-shell -b \"'$BIN' seen\""
sweep="run-shell -b \"'$BIN' sweep\""
save="run-shell -b \"'$BIN' sidebar save '#{session_id}' '#{window_id}'\""
tmux set-hook -g 'session-window-changed[90]' "$follow"
tmux set-hook -g 'client-session-changed[90]' "$follow"
tmux set-hook -g 'session-window-changed[91]' "$seen"
tmux set-hook -g 'client-session-changed[91]' "$seen"
tmux set-hook -g 'after-select-pane[91]' "$seen"
tmux set-hook -g 'client-focus-in[91]' "$seen"
# A pane closed: fix tab icons, drop a lonely sidebar.
tmux set-hook -g 'pane-exited[92]' "$sweep"
tmux set-hook -g 'after-kill-pane[92]' "$sweep"
# An agent pane moved to another window (break-pane, join-pane, move-pane,
# swap-pane): its tab icon moves along. tmux has no after-break-pane etc.,
# but fires the window hook pane-moved for each. Panes without an agent (the
# sidebar following you) change no tab, so they run nothing.
tmux set-hook -g 'pane-moved[95]' "if -F '#{@agent_state}' { $sweep }"
# Remember the sidebar width you drag/resize it to.
tmux set-hook -g 'after-resize-pane[93]' "$save"
# The terminal resized: tmux scales every pane, the sidebar too. Give it its
# saved width back (only the plain case: sidebar the top-left pane, nothing
# floating over it, not zoomed, room to spare). resize-pane does not expand
# formats, so the width goes through run-shell -C; its resize-pane fires no
# after-resize-pane, so the saved width stays.
sb_fix="#{&&:#{@agents_sidebar_on},#{!=:#{window_zoomed_flag},1},#{e|>=:#{window_width},#{e|+:$sb_w,12}},#{==:#{P:#{?#{&&:#{pane_at_left},#{pane_at_top},#{@agents_sidebar}},S#{?#{!=:#{pane_width},$sb_w},W,},}#{?$sb_float_tl,F,}},SW}}"
tmux set-hook -g 'window-resized[96]' "if -F '$sb_fix' { run-shell -C \"resize-pane -t '{top-left}' -x $sb_w\" }"
# First run without install.sh (TPM): offer to connect the agents, once.
tmux set-hook -g 'client-attached[94]' "run-shell -b \"'$BIN' setup-prompt '#{client_name}'\""

# Periodic sweep (agents that died without a hook) piggybacks on the status
# line refresh: #() runs every status-interval and prints nothing. "status"
# makes it a no-op while a sidebar is open (the sidebar sweeps every second),
# which matters because tab animations make tmux rerun #() jobs every second.
right=$(tmux show -gv status-right | sed "s|#('[^']*/tmux-agents' sweep[^)]*)||g")
tmux set -g status-right "$right#('$BIN' sweep status)"

# Window tab icon after the name: "2 Plugin-Dev 󰔟" (most urgent agent state).
icon=""
for s in blocked done working idle; do
  c=$(opt "@agents-color-$s")
  if [ "$s" = working ]; then
    # Working tab icons animated like the agents' own spinners. The frames
    # come from the session's sidebar pane title, set by sidebar.ts:
    #   agents=<claude>|<opencode, inactive tab>|<opencode, current tab>|<codex>
    # With no sidebar open: Claude and Codex blink a still icon, others the
    # hourglass.
    frame() { printf '#{W:#{P:#{?#{&&:#{@agents_sidebar},#{&&:#{==:#{pane_dead},0},#{m:agents=*,#{pane_title}}}},#{s/^agents=([^|]*)[|]([^|]*)[|]([^|]*)([|](.*))?$/\\%s/:pane_title},}}}' "$1"; }
    fc=$(frame 1)
    fo="#{?window_active,$(frame 3),$(frame 2)}"
    fx=$(frame 5) # group 4 is the optional "|codex" part; a sidebar from before codex support sends none
    hour="#[fg=$c] $(opt @agents-tab-icon-working)"
    still="#[$(opt @agents-tab-claude-working-style)] $(opt @agents-tab-icon-claude-working)#[noblink]"
    cstill="#[$(opt @agents-tab-codex-working-style)] $(opt @agents-tab-icon-codex-working)#[noblink]"
    # tmux's s/// prints the group number itself ("1", "5") for an empty or
    # missing group, so a bare digit means "no frame yet": show the still icon.
    claude="#[fg=$(opt @agents-color-claude)]#{?#{==:$fc,1},$still,#{?$fc, $fc,$still}}"
    codex="#[fg=$(opt @agents-color-codex)]#{?#{==:$fx,5},$cstill,#{?$fx, $fx,$cstill}}"
    # Same for OpenCode's groups 2 and 3: a bare "2" or "3" is no frame.
    opencode="#{?#{||:#{==:$fo,2},#{==:$fo,3}},$hour,#{?$fo, $fo,$hour}}"
    i="#{?#{==:#{@agent_win_agent},claude},$claude,#{?#{==:#{@agent_win_agent},opencode},$opencode,#{?#{==:#{@agent_win_agent},codex},$codex,$hour}}}"
    icon="$icon#{?#{==:#{@agent_win_state},$s},$i#[fg=default],"
    continue
  fi
  i=$(opt "@agents-icon-$s")
  icon="$icon#{?#{==:#{@agent_win_state},$s},#[fg=$c] $i#[fg=default],"
done
# A window zoomed by the sidebar-aware zoom gets a marker (tmux shows none).
zoom="#{?#{@agents_zoom},#[fg=$(opt @agents-color-muted)] $(opt @agents-tab-icon-zoom)#[fg=default],}"
tmux set -g @agents-tab-icon "$zoom$icon}}}}"

for f in window-status-format window-status-current-format; do
  # Drop a previous injection (any position), then add it after the name.
  fmt=$(tmux show -gwv "$f" | sed 's/#{E:@agents-tab-icon}//g')
  case "$fmt" in
    *'#W'*) fmt=$(printf '%s' "$fmt" | sed 's/#W/#W#{E:@agents-tab-icon}/') ;;
    *) fmt="$fmt#{E:@agents-tab-icon}" ;;
  esac
  tmux set -gw "$f" "$fmt"
done

# Already attached (TPM's prefix + I): ask now, in the background.
"$BIN" setup-prompt >/dev/null 2>&1 &
