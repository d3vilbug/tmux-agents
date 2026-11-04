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

# prefix + a: toggle the Agents sidebar.
tmux bind-key "$(opt @agents-key)" run-shell -b "'$BIN' sidebar toggle '#{session_id}' '#{window_id}'"

# Fixed hook indexes (90+) so re-sourcing replaces instead of duplicating,
# and other plugins' hooks stay untouched.
follow="run-shell -b \"'$BIN' sidebar follow '#{session_id}' '#{window_id}'\""
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
# Remember the sidebar width you drag/resize it to.
tmux set-hook -g 'after-resize-pane[93]' "$save"

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
tmux set -g @agents-tab-icon "$icon}}}}"

for f in window-status-format window-status-current-format; do
  # Drop a previous injection (any position), then add it after the name.
  fmt=$(tmux show -gwv "$f" | sed 's/#{E:@agents-tab-icon}//g')
  case "$fmt" in
    *'#W'*) fmt=$(printf '%s' "$fmt" | sed 's/#W/#W#{E:@agents-tab-icon}/') ;;
    *) fmt="$fmt#{E:@agents-tab-icon}" ;;
  esac
  tmux set -gw "$f" "$fmt"
done
