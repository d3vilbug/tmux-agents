// The sidebar follows you to another window inside the tmux hook itself (no
// flash): tmux-agents.tmux puts plain tmux commands in front of the background
// follow in session-window-changed[90]. These tests strip the background part,
// so they check only the in-hook move, against a private tmux server in a
// private TMUX_TMPDIR with a fake sidebar pane (a sleep marked @agents_sidebar),
// including every case where `{top-left}` would not be the sidebar.
// Run from the repo root: bun test

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"

const ROOT = `${import.meta.dir}/..`
const SOCK = "tmux-agents-follow-test"
const TMPDIR = mkdtempSync("/tmp/tmux-agents-follow.")
const env = { ...process.env, TMUX_TMPDIR: TMPDIR, TMUX: "", TMUX_PANE: "", HOME: TMPDIR }

const tmux = (...args: string[]) =>
  Bun.spawnSync(["tmux", "-L", SOCK, ...args], { env, stderr: "ignore" }).stdout.toString().trim()
const sleep = () => "exec sleep 600"
// bin/tmux-agents talks to tmux through $TMUX, like inside a pane.
const bin = (...args: string[]) =>
  Bun.spawnSync([`${ROOT}/bin/tmux-agents`, ...args], { env: { ...env, TMUX: `${tmux("display", "-p", "#{socket_path}")},1,0` } }).exitCode

let sb = ""
let w: string[] = []
const where = (p = sb) => tmux("display", "-p", "-t", p, "#{window_id}")
const sidebars = () => tmux("list-panes", "-a", "-f", "#{@agents_sidebar}", "-F", "#{pane_id}").split("\n").filter(Boolean)

beforeAll(() => {
  tmux("-f", "/dev/null", "new-session", "-d", "-s", "keep", sleep())
  tmux("run-shell", `${ROOT}/tmux-agents.tmux`)
  // Keep only the in-hook move: drop the background follow after it.
  for (const h of ["session-window-changed[90]", "client-session-changed[90]"]) {
    const cmd = tmux("show-hooks", "-g", h).replace(/^\S+ /, "")
    expect(cmd).toContain("join-pane")
    tmux("set-hook", "-g", h, cmd.replace(/ ; run-shell -b .*$/, ""))
  }
})
beforeEach(() => {
  tmux("kill-session", "-t", "=s")
  tmux("set", "-g", "@agents_sidebar_on", "1")
  tmux("set", "-gu", "@agents_sidebar_width_saved")
  tmux("new-session", "-d", "-s", "s", "-x", "120", "-y", "30", sleep())
  tmux("new-window", "-d", "-t", "=s:", sleep())
  tmux("new-window", "-d", "-t", "=s:", sleep())
  tmux("split-window", "-d", "-h", "-t", "=s:2", sleep())
  w = tmux("list-windows", "-t", "=s", "-F", "#{window_id}").split("\n")
  sb = tmux("split-window", "-hbf", "-d", "-l", "22", "-P", "-F", "#{pane_id}", "-t", w[0], sleep())
  tmux("set", "-p", "-t", sb, "@agents_sidebar", "1")
  tmux("set", "-w", "-t", w[0], "@agents_border_hidden", "1")
})
afterAll(() => {
  tmux("kill-server")
  rmSync(TMPDIR, { recursive: true, force: true })
})

test("select-window: the sidebar is already in the new window, full-height left, same width", () => {
  tmux("select-window", "-t", w[2])
  expect(where()).toBe(w[2])
  expect(tmux("display", "-p", "-t", sb, "#{pane_at_left}#{pane_at_top}#{pane_at_bottom}:#{pane_width}")).toBe("111:22")
  expect(tmux("list-panes", "-t", w[2], "-F", "x").split("\n")).toHaveLength(3)
  // Borders: hidden in the window with the sidebar, back in the one it left.
  expect(tmux("show", "-wqv", "-t", w[2], "@agents_border_hidden")).toBe(tmux("show", "-gwv", "pane-border-style"))
  expect(tmux("show", "-wqv", "-t", w[0], "@agents_border_hidden")).toBe("")
  expect(tmux("show", "-wqv", "-t", w[0], "pane-active-border-style")).toBe("")
  expect(tmux("show", "-wqv", "-t", w[2], "pane-active-border-style")).toBe(tmux("show", "-gwv", "pane-border-style"))
  // No style of yours anywhere: nothing saved, and none left behind.
  expect(tmux("show", "-wqv", "-t", w[2], "@agents_border_saved")).toBe("")
  tmux("select-window", "-t", w[0])
  expect(tmux("show", "-wqv", "-t", w[2], "pane-active-border-style")).toBe("")
})

const border = (win: string) => tmux("show", "-wqv", "-t", win, "pane-active-border-style")

test("a border style you set on a window comes back when the sidebar leaves it", () => {
  tmux("set", "-w", "-t", w[1], "pane-active-border-style", "fg=#ff0000,bg=default")
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[1])
  expect(border(w[1])).toBe(tmux("show", "-gwv", "pane-border-style"))
  tmux("select-window", "-t", w[2])
  expect(border(w[1])).toBe("fg=#ff0000,bg=default")
  expect(tmux("show", "-wqv", "-t", w[1], "@agents_border_saved")).toBe("")
  expect(tmux("show", "-wqv", "-t", w[1], "@agents_border_hidden")).toBe("")
})

test("a border style you set while the sidebar was there stays", () => {
  tmux("select-window", "-t", w[1])
  tmux("set", "-w", "-t", w[1], "pane-active-border-style", "fg=blue")
  tmux("select-window", "-t", w[2])
  expect(border(w[1])).toBe("fg=blue")
})

test("background follow (the in-hook move skipped) saves and restores your style too", () => {
  tmux("set", "-w", "-t", w[1], "pane-active-border-style", "fg=green")
  tmux("resize-window", "-t", w[1], "-x", "30") // too narrow for the in-hook move
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
  bin("sidebar", "follow", tmux("display", "-p", "-t", "=s:", "#{session_id}"), w[1])
  expect(where()).toBe(w[1])
  expect(border(w[1])).toBe(tmux("show", "-gwv", "pane-border-style"))
  expect(tmux("show", "-wqv", "-t", w[1], "@agents_border_saved")).toBe("fg=green")
  // The legacy marker "1" in w[0] is gone and so is its border.
  expect(border(w[0])).toBe("")
  tmux("select-window", "-t", w[2])
  bin("sidebar", "follow", tmux("display", "-p", "-t", "=s:", "#{session_id}"), w[2])
  expect(where()).toBe(w[2])
  expect(border(w[1])).toBe("fg=green")
})

// The terminal resized: tmux scales the sidebar along, the hook sets it back.
const width = () => Number(tmux("display", "-p", "-t", sb, "#{pane_width}"))
const settle = () => Bun.sleepSync(300) // run-shell -C runs on a timer

test("terminal resize: the sidebar gets its width back, the saved width stays", () => {
  tmux("set", "-g", "@agents_sidebar_width_saved", "25")
  tmux("resize-pane", "-t", sb, "-x", "25")
  tmux("set", "-g", "@agents_sidebar_width_saved", "25")
  for (const x of ["80", "160", "100"]) {
    tmux("resize-window", "-t", w[0], "-x", x)
    settle()
    expect(width()).toBe(25)
  }
  expect(tmux("show", "-gv", "@agents_sidebar_width_saved")).toBe("25")
})

test("terminal resize: left alone when too narrow, zoomed or off", () => {
  tmux("resize-window", "-t", w[0], "-x", "30")
  settle()
  expect(width()).toBeLessThan(22)
  tmux("resize-window", "-t", w[0], "-x", "120")
  settle()
  expect(width()).toBe(22)
  tmux("set", "-gu", "@agents_sidebar_on")
  tmux("resize-window", "-t", w[0], "-x", "60")
  settle()
  expect(width()).not.toBe(22)
  tmux("set", "-g", "@agents_sidebar_on", "1")
  const mine = tmux("list-panes", "-t", w[0], "-F", "#{pane_id}").split("\n").find((p) => p !== sb)!
  tmux("resize-pane", "-Z", "-t", mine)
  tmux("resize-window", "-t", w[0], "-x", "140")
  settle()
  expect(tmux("display", "-p", "-t", w[0], "#{window_zoomed_flag}:#{pane_id}")).toBe(`1:${mine}`)
})

test("next-window, previous-window, last-window and new-window move it too", () => {
  tmux("next-window", "-t", "=s:")
  expect(where()).toBe(w[1])
  tmux("previous-window", "-t", "=s:")
  expect(where()).toBe(w[0])
  tmux("last-window", "-t", "=s:")
  expect(where()).toBe(w[1])
  tmux("new-window", "-t", "=s:", sleep())
  expect(where()).toBe(tmux("display", "-p", "-t", "=s:", "#{window_id}"))
  expect(sidebars()).toEqual([sb])
})

test("uses the width you saved", () => {
  tmux("set", "-g", "@agents_sidebar_width_saved", "30")
  tmux("select-window", "-t", w[1])
  expect(tmux("display", "-p", "-t", sb, "#{pane_width}")).toBe("30")
})

test("sidebar off: nothing moves", () => {
  tmux("set", "-gu", "@agents_sidebar_on")
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
})

test("zoomed window: nothing moves", () => {
  tmux("resize-pane", "-Z", "-t", `${w[2]}.0`)
  tmux("select-window", "-t", w[2])
  expect(where()).toBe(w[0])
  expect(tmux("display", "-p", "-t", w[2], "#{window_zoomed_flag}")).toBe("1")
})

test("left pane of the window you came from is not the sidebar: nothing moves", () => {
  // The sidebar dragged to the right side: the left pane is a normal one.
  tmux("swap-pane", "-d", "-s", sb, "-t", tmux("list-panes", "-t", w[0], "-F", "#{pane_id}").split("\n").find((p) => p !== sb)!)
  const leftPane = tmux("list-panes", "-t", w[0], "-f", "#{pane_at_left}", "-F", "#{pane_id}")
  expect(leftPane).not.toBe(sb)
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
  expect(tmux("display", "-p", "-t", leftPane, "#{window_id}")).toBe(w[0])
})

test("window that already has a sidebar: nothing moves, nothing doubles", () => {
  const other = tmux("split-window", "-hbf", "-d", "-l", "22", "-P", "-F", "#{pane_id}", "-t", w[1], sleep())
  tmux("set", "-p", "-t", other, "@agents_sidebar", "1")
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
  expect(where(other)).toBe(w[1])
})

test("the zoom's hidden session: nothing moves into it", () => {
  tmux("new-session", "-d", "-s", "_agents_zoom", sleep())
  const hsb = tmux("split-window", "-hbf", "-d", "-l", "22", "-P", "-F", "#{pane_id}", "-t", "=_agents_zoom:", sleep())
  tmux("set", "-p", "-t", hsb, "@agents_sidebar", "1")
  tmux("new-window", "-t", "=_agents_zoom:", sleep())
  expect(where(hsb)).toBe(tmux("list-windows", "-t", "=_agents_zoom", "-F", "#{window_id}").split("\n")[0])
  tmux("kill-session", "-t", "=_agents_zoom")
})

// A floating pane like a toast or a user's own (tmux 3.8 new-pane).
const float = (w: string, x: number, y: number) =>
  tmux("new-pane", "-d", "-P", "-F", "#{pane_id}", "-t", w, "-x", "20", "-y", "4", "-X", String(x), "-Y", String(y), sleep())

test("window you came from is zoomed (tmux zoom): your zoomed pane stays, nothing moves", () => {
  const mine = tmux("list-panes", "-t", w[0], "-F", "#{pane_id}").split("\n").find((p) => p !== sb)!
  tmux("resize-pane", "-Z", "-t", mine)
  tmux("select-window", "-t", w[1])
  expect(tmux("display", "-p", "-t", mine, "#{window_id}")).toBe(w[0])
  expect(where()).toBe(w[0])
  expect(tmux("list-panes", "-t", w[1], "-F", "x").split("\n")).toHaveLength(1)
})

test("floating pane over the top-left corner of the window you came from: it stays, nothing moves", () => {
  const f = float(w[0], 0, 0)
  tmux("select-window", "-t", w[1])
  expect(tmux("display", "-p", "-t", f, "#{window_id}:#{pane_floating_flag}")).toBe(`${w[0]}:1`)
  expect(where()).toBe(w[0])
})

test("floating pane in the top-left corner of the new window: nothing moves, no error", () => {
  float(w[1], 0, 0)
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
})

test("floating panes elsewhere (a toast at the top right) do not stop the move", () => {
  float(w[0], 90, 0)
  float(w[1], 90, 0)
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[1])
})

test("window you came from holds only the sidebar: nothing moves (it would close)", () => {
  for (const p of tmux("list-panes", "-t", w[0], "-F", "#{pane_id}").split("\n")) if (p !== sb) tmux("kill-pane", "-t", p)
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
})

test("new window too narrow for the sidebar: nothing moves", () => {
  tmux("resize-window", "-t", w[1], "-x", "30")
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0])
})

test("background follow out of a tmux-zoomed window: it stays zoomed on your pane", () => {
  const mine = tmux("list-panes", "-t", w[0], "-F", "#{pane_id}").split("\n").find((p) => p !== sb)!
  tmux("split-window", "-d", "-v", "-t", mine, sleep())
  tmux("resize-pane", "-Z", "-t", mine)
  tmux("select-window", "-t", w[1])
  expect(where()).toBe(w[0]) // the in-hook move skips a zoomed window
  bin("sidebar", "follow", tmux("display", "-p", "-t", "=s:", "#{session_id}"), w[1])
  expect(where()).toBe(w[1])
  expect(tmux("display", "-p", "-t", w[0], "#{window_zoomed_flag}:#{pane_id}")).toBe(`1:${mine}`)
})
