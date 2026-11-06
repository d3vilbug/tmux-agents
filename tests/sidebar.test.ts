// The real sidebar (bun sidebar/sidebar.ts) on a private tmux server in a
// private TMUX_TMPDIR with a dummy HOME. A `tmux` wrapper first on PATH pins
// every call, the sidebar's and bin/tmux-agents', to the private socket.
// Agents are panes running sleep with the @agent* options set, so any value
// (newlines, tabs, wide text) can be fed to the renderer.
// Run from the repo root: bun test tests/sidebar.test.ts
// SIDEBAR_TS=<file> runs another copy of the renderer (to check a test fails
// without its fix); it must sit in a sidebar/ dir next to bin/ and defaults.conf.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"

const ROOT = `${import.meta.dir}/..`
const SIDEBAR = process.env.SIDEBAR_TS || `${ROOT}/sidebar/sidebar.ts`
const BIN = `${ROOT}/bin/tmux-agents`
const SOCK = "tmux-agents-sidebar-test"
const TMPDIR = mkdtempSync("/tmp/tmux-agents-sidebar.")
const REAL_TMUX = Bun.which("tmux") ?? "tmux"
mkdirSync(`${TMPDIR}/bin`)
mkdirSync(`${TMPDIR}/home`)
writeFileSync(`${TMPDIR}/bin/tmux`, `#!/bin/sh\nTMUX_TMPDIR='${TMPDIR}' exec '${REAL_TMUX}' -L ${SOCK} "$@"\n`)
chmodSync(`${TMPDIR}/bin/tmux`, 0o755)
const env = {
  ...process.env,
  TMUX: "",
  TMUX_TMPDIR: TMPDIR,
  HOME: `${TMPDIR}/home`,
  PATH: `${TMPDIR}/bin:${process.env.PATH}`,
}

const tmux = (...args: string[]) =>
  Bun.spawnSync([`${TMPDIR}/bin/tmux`, ...args], { env, stderr: "ignore" }).stdout.toString().replace(/\n$/, "")
const H = 30
const SB_W = 22

let sb = ""
let main = ""

// A fresh window "w:" with one agent pane and the sidebar (active, so focused).
function fresh(opts: { baseIndex?: number } = {}) {
  for (const s of tmux("list-sessions", "-F", "#{session_name}").split("\n"))
    if (s && s !== "keep") tmux("kill-session", "-t", `=${s}`)
  tmux("set", "-g", "pane-base-index", String(opts.baseIndex ?? 0))
  tmux("new-session", "-d", "-s", "w", "-x", "120", "-y", String(H), "exec sleep 600")
  main = tmux("display", "-p", "-t", "=w:", "#{pane_id}")
}
function openSidebar() {
  sb = tmux("split-window", "-hbf", "-l", String(SB_W), "-P", "-F", "#{pane_id}", "-t", main, `exec bun '${SIDEBAR}'`)
  waitFor(() => screen()[0]?.includes("AGENTS"))
}
function agent(pane: string, state: string, note = "", agentName = "claude") {
  tmux("set", "-p", "-t", pane, "@agent", agentName, ";", "set", "-p", "-t", pane, "@agent_state", state, ";",
    "set", "-p", "-t", pane, "@agent_note", note)
}
function waitFor(ok: () => boolean | undefined, ms = 4000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (ok()) return true
    Bun.sleepSync(100)
  }
  return false
}
// Repaint now (the sidebar refreshes on SIGUSR1), then let it draw.
function poke() {
  const pid = tmux("display", "-p", "-t", sb, "#{@agents_sidebar_pid}")
  if (pid) Bun.spawnSync(["kill", "-USR1", pid])
  Bun.sleepSync(400)
}
const screen = (join = false) => tmux("capture-pane", "-p", ...(join ? ["-J"] : []), "-t", sb).split("\n")
const alive = () => tmux("list-panes", "-a", "-F", "#{pane_id} #{pane_dead}").split("\n").includes(`${sb} 0`)

// Every row fits: the header is on top, nothing wrapped (a wrapped row would
// scroll it away and -J would join it), one row per pane line.
function expectFits() {
  const rows = screen()
  expect(alive()).toBe(true)
  expect(rows).toHaveLength(Number(tmux("display", "-p", "-t", sb, "#{pane_height}")))
  expect(screen(true)).toHaveLength(rows.length)
  return rows
}

beforeAll(() => {
  tmux("-f", "/dev/null", "new-session", "-d", "-s", "keep", "exec sleep 600")
  tmux("set", "-g", "destroy-unattached", "off")
})
beforeEach(() => fresh())
afterAll(() => {
  tmux("kill-server")
  rmSync(TMPDIR, { recursive: true, force: true })
})

test("notes with newlines, tabs or escapes do not crash the sidebar", () => {
  openSidebar()
  agent(main, "blocked", "build failed\nsee log")
  const other = tmux("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", main, "exec sleep 600")
  agent(other, "working", "a\tb\x1b[31mred")
  poke()
  Bun.sleepSync(800)
  const rows = expectFits()
  expect(rows[0]).toContain("AGENTS")
  expect(rows.join("\n")).toContain("build fail")
  expect(rows.join("\n")).toContain("a b")
  expect(rows.some((r) => r.startsWith("see log"))).toBe(false)
})

test("wide, combining and ZWJ text and long session names never wrap a row", () => {
  tmux("rename-session", "-t", "=w", "my-long-project-session-name")
  openSidebar()
  agent(main, "blocked", "日本語のメモ 👨‍👩‍👧 é̂ ✔️ done")
  tmux("rename-window", "-t", main, "ウィンドウ名前テスト")
  const other = tmux("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", main, "exec sleep 600")
  agent(other, "working", "👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽👍🏽")
  poke()
  const rows = expectFits()
  expect(rows[0]).toContain("AGENTS")
  // Two sessions: the location is cut, not wrapped.
  expect(rows.join("\n")).toContain("my-")
  expect(rows.join("\n")).toContain("…")
  // The right border stays in the last column of every row.
  for (const r of rows) expect(Bun.stringWidth(r)).toBe(SB_W)
})

test("focused at the default width: the footer shows every key", () => {
  openSidebar()
  agent(main, "idle")
  poke()
  const rows = expectFits()
  const footer = rows.at(-2) ?? ""
  for (const k of ["jump", "drop", "hide"]) expect(footer).toContain(k)
})

test("pane-base-index 1: locations count panes from 1", () => {
  fresh({ baseIndex: 1 })
  const other = tmux("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", main, "exec sleep 600")
  openSidebar()
  agent(main, "idle")
  agent(other, "working")
  poke()
  const text = expectFits().join("\n")
  expect(text).toContain("0.1")
  expect(text).toContain("0.2")
  expect(text).not.toContain("0.0")
})

test("widths of 4 and less never wrap", () => {
  openSidebar()
  agent(main, "blocked", "something long enough to be cut")
  for (const w of [4, 3, 2, 1]) {
    tmux("resize-pane", "-t", sb, "-x", String(w))
    poke()
    const rows = expectFits()
    expect(rows[0].length).toBeGreaterThan(0)
  }
})

// A click on a card first focuses the sidebar: the cursor must already be on
// the card you are looking at (it used to flash on the one left from before).
test("coming into the sidebar puts the cursor on the card you are looking at", () => {
  const other = tmux("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=w:", "exec sleep 600")
  agent(main, "idle")
  agent(other, "blocked") // blocked sorts first, so the cursor starts on it
  openSidebar()
  // A client, so "the pane you look at" exists (control mode, kept open).
  const client = Bun.spawn([`${TMPDIR}/bin/tmux`, "-C", "attach", "-t", "=w"], { env, stdin: "pipe", stdout: "ignore", stderr: "ignore" })
  try {
    waitFor(() => tmux("list-clients", "-F", "x") !== "")
    tmux("select-pane", "-t", main)
    tmux("send-keys", "-t", sb, "-H", "1b", "5b", "4f") // focus out
    poke()
    tmux("send-keys", "-t", sb, "-H", "1b", "5b", "49", "0d") // focus in, Enter
    Bun.sleepSync(500)
    // Enter jumped to the cursor's card: still this window and pane.
    expect(tmux("display", "-p", "-t", "=w:", "#{window_id}")).toBe(tmux("display", "-p", "-t", main, "#{window_id}"))
    expect(alive()).toBe(true)
  } finally {
    client.kill()
  }
})
