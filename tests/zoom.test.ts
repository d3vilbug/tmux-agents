// Sidebar-aware zoom (@agents-zoom-keeps-sidebar on) against a private tmux
// server in a private TMUX_TMPDIR, with a fake sidebar pane (a sleep marked
// @agents_sidebar), so the real sidebar (bun) is not needed.
// Run from the repo root: bun test

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"

const ROOT = `${import.meta.dir}/..`
const BIN = `${ROOT}/bin/tmux-agents`
const SOCK = "tmux-agents-zoom-test"
const TMPDIR = mkdtempSync("/tmp/tmux-agents-zoom.")
const env = { ...process.env, TMUX_TMPDIR: TMPDIR, TMUX: "", TMUX_PANE: "" }

const tmux = (...args: string[]) =>
  Bun.spawnSync(["tmux", "-L", SOCK, ...args], { env, stderr: "ignore" }).stdout.toString().trim()
// bin/tmux-agents talks to tmux through $TMUX, like inside a pane.
const bin = (...args: string[]) => binIn("", ...args)
// Run from inside pane $pane (TMUX_PANE), e.g. the sidebar.
const binIn = (pane: string, ...args: string[]) => {
  const r = Bun.spawnSync([BIN, ...args], { env: { ...env, TMUX: `${tmux("display", "-p", "#{socket_path}")},1,0`, TMUX_PANE: pane } })
  return r.exitCode
}
const W = 120

let win = ""
let sb = ""
let left = ""
let right = ""

function freshWindow() {
  tmux("kill-session", "-t", "=w")
  tmux("kill-session", "-t", "=_agents_zoom")
  tmux("new-session", "-d", "-s", "w", "-x", String(W), "-y", "30", "exec sleep 600")
  win = tmux("display", "-p", "-t", "=w:", "#{window_id}")
  left = tmux("display", "-p", "-t", "=w:", "#{pane_id}")
  right = tmux("split-window", "-d", "-h", "-P", "-F", "#{pane_id}", "-t", left, "exec sleep 600")
  sb = tmux("split-window", "-hbf", "-d", "-l", "22", "-P", "-F", "#{pane_id}", "-t", left, "exec sleep 600")
  tmux("set", "-p", "-t", sb, "@agents_sidebar", "1")
}
// A toast: a floating pane marked @agents_toast, like bin/tmux-agents makes.
const toast = (w = win) => {
  const t = tmux("new-pane", "-d", "-A", "-P", "-F", "#{pane_id}", "-t", w, "-x", "20", "-y", "4", "-X", "90", "-Y", "0", "exec sleep 600")
  tmux("set", "-p", "-t", t, "@agents_toast", "1")
  return t
}
const tiled = (w = win) => tmux("list-panes", "-t", w, "-f", "#{!=:#{pane_floating_flag},1}", "-F", "#{pane_id}").split("\n").filter(Boolean)
const stashed = () => tmux("list-panes", "-s", "-t", "=_agents_zoom", "-F", "#{pane_id}").split("\n").filter(Boolean)
const panes = (w = win) => tmux("list-panes", "-t", w, "-F", "#{pane_id}").split("\n").filter(Boolean)
const width = (p: string) => Number(tmux("display", "-p", "-t", p, "#{pane_width}"))

beforeAll(() => {
  tmux("-f", "/dev/null", "new-session", "-d", "-s", "keep", "exec sleep 600")
  tmux("set", "-g", "@agents-zoom-keeps-sidebar", "on")
  tmux("run-shell", `${ROOT}/tmux-agents.tmux`)
})
beforeEach(freshWindow)
afterAll(() => {
  tmux("kill-server")
  rmSync(TMPDIR, { recursive: true, force: true })
})

test("option on: prefix + z runs the sidebar-aware zoom", () => {
  expect(tmux("list-keys", "-T", "prefix", "z")).toContain("zoom toggle")
})

test("zoom keeps the sidebar and hides the other pane; unzoom restores the exact layout", () => {
  const layout = tmux("display", "-p", "-t", win, "#{window_layout}")
  bin("zoom", "toggle", win, left)
  expect(panes()).toEqual([sb, left].sort((a, b) => panes().indexOf(a) - panes().indexOf(b)))
  expect(panes()).toHaveLength(2)
  expect(width(sb)).toBe(22)
  expect(width(left)).toBe(W - 22 - 1)
  expect(tmux("display", "-p", "-t", win, "#{window_zoomed_flag}")).toBe("0")
  // The moved pane keeps running, in the hidden session.
  expect(tmux("display", "-p", "-t", right, "#{session_name}:#{pane_dead}")).toBe("_agents_zoom:0")
  // Tab marker while zoomed.
  expect(tmux("display", "-p", "-t", win, "#{E:@agents-tab-icon}")).toContain("Z")

  bin("zoom", "toggle", win, left)
  expect(panes()).toHaveLength(3)
  expect(tmux("display", "-p", "-t", win, "#{window_layout}")).toBe(layout)
  expect(tmux("has-session", "-t", "=_agents_zoom") + tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
  expect(tmux("display", "-p", "-t", win, "#{@agents_zoom}#{@agents_zoom_layout}")).toBe("")
  expect(tmux("display", "-p", "-t", win, "#{E:@agents-tab-icon}")).not.toContain("Z")
})

test("a mixed layout (side by side and stacked) comes back exactly", () => {
  const below = tmux("split-window", "-d", "-v", "-P", "-F", "#{pane_id}", "-t", right, "exec sleep 600")
  tmux("select-pane", "-t", right)
  const layout = tmux("display", "-p", "-t", win, "#{window_layout}")
  const order = panes()
  bin("zoom", "toggle", win, right)
  expect(panes()).toHaveLength(2)
  expect(tmux("display", "-p", "-t", below, "#{session_name}")).toBe("_agents_zoom")
  bin("zoom", "toggle", win, right)
  expect(panes()).toEqual(order)
  expect(tmux("display", "-p", "-t", win, "#{window_layout}")).toBe(layout)
})

test("a window without a sidebar gets the plain tmux zoom", () => {
  tmux("kill-pane", "-t", sb)
  bin("zoom", "toggle", win, left)
  expect(tmux("display", "-p", "-t", win, "#{window_zoomed_flag}")).toBe("1")
  expect(panes()).toHaveLength(2)
})

test("closing the zoomed pane brings the others back (sweep)", () => {
  bin("zoom", "toggle", win, left)
  tmux("kill-pane", "-t", left)
  bin("sweep")
  expect(panes()).toContain(right)
  expect(tmux("display", "-p", "-t", right, "#{window_id}")).toBe(win)
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
  expect(width(sb)).toBe(22)
})

test("killing the zoomed window gives the moved panes their own window (sweep)", () => {
  bin("zoom", "toggle", win, left)
  tmux("kill-window", "-t", win)
  bin("sweep")
  const s = tmux("display", "-p", "-t", right, "#{session_name}")
  expect(s === "keep" || s === "w").toBe(true)
  expect(tmux("display", "-p", "-t", right, "#{@agents_zoom_from}")).toBe("")
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
})

test("only the sidebar next to the pane: nothing to zoom, nothing moved", () => {
  tmux("kill-pane", "-t", right)
  const layout = tmux("display", "-p", "-t", win, "#{window_layout}")
  bin("zoom", "toggle", win, left)
  expect(tmux("display", "-p", "-t", win, "#{window_layout}")).toBe(layout)
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
})

test("option off again: prefix + z is tmux zoom, an active zoom is undone", () => {
  bin("zoom", "toggle", win, left)
  tmux("set", "-g", "@agents-zoom-keeps-sidebar", "off")
  tmux("run-shell", `${ROOT}/tmux-agents.tmux`)
  expect(tmux("list-keys", "-T", "prefix", "z")).toContain("resize-pane -Z")
  expect(panes()).toHaveLength(3)
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
  tmux("set", "-g", "@agents-zoom-keeps-sidebar", "on")
  tmux("run-shell", `${ROOT}/tmux-agents.tmux`)
})

test("a toast open while zooming does not end up in the restored layout", () => {
  tmux("select-pane", "-t", left)
  const layout = tmux("display", "-p", "-t", win, "#{window_layout}")
  const t = toast()
  bin("zoom", "toggle", win, left)
  expect(panes()).not.toContain(t) // closed, not saved in the layout
  bin("zoom", "toggle", win, left)
  expect(tiled()).toHaveLength(3)
  expect(tmux("display", "-p", "-t", win, "#{window_layout}")).toBe(layout)
  expect(tmux("display", "-p", "-t", right, "#{pane_floating_flag}")).toBe("0")
})

test("a toast that appears while zoomed does not break the unzoom", () => {
  tmux("select-pane", "-t", left)
  const layout = tmux("display", "-p", "-t", win, "#{window_layout}")
  bin("zoom", "toggle", win, left)
  toast()
  bin("zoom", "toggle", win, left)
  expect(tmux("display", "-p", "-t", win, "#{window_layout}")).toBe(layout)
})

test("prefix + z pressed twice at once leaves no pane stuck in the hidden session", async () => {
  tmux("select-pane", "-t", left)
  const sockEnv = { ...env, TMUX: `${tmux("display", "-p", "#{socket_path}")},1,0` }
  const runs = [0, 1].map(() => Bun.spawn([BIN, "zoom", "toggle", win, left], { env: sockEnv }).exited)
  await Promise.all(runs)
  const zoomed = tmux("display", "-p", "-t", win, "#{@agents_zoom}") !== ""
  // Either zoomed with the pane out, or not zoomed with every pane home.
  if (zoomed) expect(tmux("display", "-p", "-t", right, "#{session_name}")).toBe("_agents_zoom")
  else expect(panes()).toContain(right)
  if (zoomed) bin("zoom", "toggle", win, left)
  expect(panes()).toContain(right)
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
})

test("an interrupted zoom (pane out, no zoom state) is brought back by sweep", () => {
  bin("zoom", "toggle", win, left)
  tmux("set", "-wu", "-t", win, "@agents_zoom") // as if a second toggle had raced it
  bin("sweep")
  expect(panes()).toContain(right)
  expect(tmux("display", "-p", "-t", right, "#{@agents_zoom_from}")).toBe("")
})

test("no sidebar is started inside the hidden session", () => {
  tmux("set", "-g", "@agents_sidebar_on", "1")
  bin("zoom", "toggle", win, left)
  Bun.sleepSync(1500) // the session-window-changed hook runs in the background
  expect(tmux("list-panes", "-s", "-t", "=_agents_zoom", "-f", "#{@agents_sidebar}", "-F", "#{pane_id}")).toBe("")
  bin("zoom", "toggle", win, left)
  tmux("set", "-gu", "@agents_sidebar_on")
})

test("zoom works with destroy-unattached on", () => {
  // destroy-unattached kills every session without a client; the user's own
  // sessions have one, the test's do not: exempt them, so only the hidden
  // session (created unattached) is at risk, as in real use.
  for (const t of ["=w:", "=keep:"]) tmux("set", "-t", t, "destroy-unattached", "off")
  tmux("set", "-g", "destroy-unattached", "on")
  bin("zoom", "toggle", win, left)
  const out = tmux("display", "-p", "-t", right, "#{session_name}")
  tmux("set", "-g", "destroy-unattached", "off")
  expect(out).toBe("_agents_zoom")
  expect(tmux("display", "-p", "-t", win, "#{@agents_zoom}")).not.toBe("")
  bin("zoom", "toggle", win, left)
  expect(panes()).toContain(right)
})

test("a moved pane's agent state shows on its home tab", () => {
  bin("zoom", "toggle", win, left)
  const r = Bun.spawnSync([BIN, "report", "blocked", "claude", "needs approval"], {
    env: { ...env, TMUX: `${tmux("display", "-p", "#{socket_path}")},1,0`, TMUX_PANE: right },
  })
  expect(r.exitCode).toBe(0)
  expect(tmux("display", "-p", "-t", win, "#{@agent_win_state}")).toBe("blocked")
  expect(stashed().length).toBeGreaterThan(0)
  expect(tmux("list-windows", "-t", "=_agents_zoom", "-F", "#{@agent_win_state}")).not.toContain("blocked")
  bin("zoom", "toggle", win, left)
})

test("zoomed window gone: its moved panes go to their own session, as one window", () => {
  const below = tmux("split-window", "-d", "-v", "-P", "-F", "#{pane_id}", "-t", right, "exec sleep 600")
  tmux("new-window", "-d", "-t", "=w:", "exec sleep 600") // the session survives the window
  bin("zoom", "toggle", win, left)
  tmux("kill-window", "-t", win)
  bin("sweep")
  expect(tmux("display", "-p", "-t", right, "#{session_name}")).toBe("w")
  expect(tmux("display", "-p", "-t", below, "#{window_id}")).toBe(tmux("display", "-p", "-t", right, "#{window_id}"))
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
})

// The right side as %2 above %4, so a fallback (all side by side) shows.
function stackRight() {
  const below = tmux("split-window", "-d", "-v", "-P", "-F", "#{pane_id}", "-t", right, "exec sleep 600")
  tmux("select-pane", "-t", left)
  return below
}
const box = (p: string) => tmux("display", "-p", "-t", p, "#{pane_left} #{pane_top} #{pane_width}").split(" ").map(Number)

test("jump from the sidebar in another window to a moved pane: the exact layout comes back", () => {
  stackRight()
  const layout = tmux("display", "-p", "-t", win, "#{window_layout}")
  const other = tmux("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=w:", "exec sleep 600")
  bin("zoom", "toggle", win, left)
  tmux("join-pane", "-hbf", "-d", "-l", "22", "-s", sb, "-t", other) // you went there, the sidebar followed
  binIn(sb, "zoom", "restore", win) // what the sidebar runs before selecting the window
  expect(tmux("display", "-p", "-t", win, "#{window_layout}")).toBe(layout)
  expect(tmux("display", "-p", "-t", sb, "#{window_id}")).toBe(win) // the window it selects next
  expect(tmux("display", "-p", "-t", win, "#{@agents_zoom}")).toBe("")
})

test("unzoom of a window whose sidebar is elsewhere (not the sidebar asking): same structure, the sidebar stays put", () => {
  const below = stackRight()
  const other = tmux("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=w:", "exec sleep 600")
  bin("zoom", "toggle", win, left)
  tmux("join-pane", "-hbf", "-d", "-l", "22", "-s", sb, "-t", other)
  bin("zoom", "restore-all")
  expect(tmux("display", "-p", "-t", sb, "#{window_id}")).toBe(other)
  expect(width(sb)).toBe(22)
  expect(panes()).toHaveLength(3)
  const [rl, rt, rw] = box(right)
  const [bl, bt, bw] = box(below)
  expect([bl, bw]).toEqual([rl, rw]) // stacked, not side by side
  expect(bt).toBeGreaterThan(rt)
  expect(box(left)[0]).toBeLessThan(rl)
})

test("session gone with two zoomed windows: every hidden window is rescued, no zoom state left", () => {
  const w2 = tmux("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=w:", "exec sleep 600")
  const a = tmux("display", "-p", "-t", w2, "#{pane_id}")
  const b = tmux("split-window", "-d", "-h", "-P", "-F", "#{pane_id}", "-t", a, "exec sleep 600")
  bin("zoom", "toggle", win, left)
  tmux("join-pane", "-hbf", "-d", "-l", "22", "-s", sb, "-t", a)
  bin("zoom", "toggle", w2, a)
  expect(stashed().sort()).toEqual([right, b].sort())
  tmux("kill-session", "-t", "=keep")
  tmux("kill-session", "-t", "=w")
  bin("sweep")
  const state = (p: string) => tmux("display", "-p", "-t", p, "#{session_name}|#{@agents_zoom_from}|#{@agents_zoom_session}")
  const out = [state(right), state(b)]
  const r = Bun.spawnSync([BIN, "report", "blocked", "claude", "needs approval"], {
    env: { ...env, TMUX: `${tmux("display", "-p", "#{socket_path}")},1,0`, TMUX_PANE: b },
  })
  const tab = tmux("display", "-p", "-t", b, "#{@agent_win_state}")
  tmux("new-session", "-d", "-s", "keep", "exec sleep 600")
  tmux("kill-session", "-t", "=agents-rescued")
  expect(out).toEqual(["agents-rescued||", "agents-rescued||"])
  expect(r.exitCode).toBe(0)
  expect(tab).toBe("blocked")
})

test("every moved pane gone: sweep ends the zoom and gives the sidebar its width back", () => {
  bin("zoom", "toggle", win, left)
  tmux("kill-pane", "-t", right)
  expect(tmux("list-sessions", "-F", "#{session_name}")).not.toContain("_agents_zoom")
  bin("sweep")
  expect(tmux("display", "-p", "-t", win, "#{@agents_zoom}#{@agents_zoom_layout}")).toBe("")
  expect(tmux("display", "-p", "-t", win, "#{E:@agents-tab-icon}")).not.toContain("Z")
  expect(width(sb)).toBe(22)
})
