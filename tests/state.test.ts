// Reports, tab state, hooks and toasts against a private tmux server in a
// private TMUX_TMPDIR with a dummy HOME. Toasts need a client: a control
// mode client (`tmux -C attach`, no terminal needed) stands in for one.
// Run from the repo root: bun test

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"

const ROOT = `${import.meta.dir}/..`
const BIN = `${ROOT}/bin/tmux-agents`
const SOCK = "tmux-agents-state-test"
const TMPDIR = mkdtempSync("/tmp/tmux-agents-state.")
const env = { ...process.env, TMUX_TMPDIR: TMPDIR, TMUX: "", HOME: TMPDIR }

const tmux = (...args: string[]) =>
  Bun.spawnSync(["tmux", "-L", SOCK, ...args], { env, stderr: "ignore" }).stdout.toString().trim()
const sockEnv = () => ({ ...env, TMUX: `${tmux("display", "-p", "#{socket_path}")},1,0` })
// bin/tmux-agents as a hook runs it: inside pane $pane.
const bin = (pane: string, args: string[], stdin?: string) =>
  Bun.spawnSync([BIN, ...args], { env: { ...sockEnv(), TMUX_PANE: pane }, stdin: stdin ? Buffer.from(stdin) : "ignore" })
const opt = (p: string, o: string) => tmux("show", "-pqv", "-t", p, o)
const wopt = (w: string, o: string) => tmux("show", "-wqv", "-t", w, o)
const toasts = (w: string) =>
  tmux("list-panes", "-t", w, "-f", "#{@agents_toast}", "-F", "#{pane_id} #{pane_top}").split("\n").filter(Boolean)
const until = (f: () => boolean, ms = 3000) => {
  const end = Date.now() + ms
  while (!f() && Date.now() < end) Bun.sleepSync(50)
  return f()
}

let win = ""
let pane = ""

beforeAll(() => {
  tmux("-f", "/dev/null", "new-session", "-d", "-s", "keep", "-x", "120", "-y", "30", "exec sleep 600")
  tmux("set", "-g", "status", "off")
  tmux("set", "-g", "@agents-setup-prompt", "off")
  tmux("run-shell", `${ROOT}/tmux-agents.tmux`)
})
beforeEach(() => {
  tmux("kill-session", "-t", "=s")
  tmux("set", "-gu", "@agents-notify")
  tmux("set", "-gu", "@agents-notify-on")
  tmux("set", "-gu", "@agents_flash_id")
  tmux("new-session", "-d", "-s", "s", "-x", "120", "-y", "30", "exec sleep 600")
  win = tmux("display", "-p", "-t", "=s:", "#{window_id}")
  pane = tmux("display", "-p", "-t", "=s:", "#{pane_id}")
})
afterAll(() => {
  tmux("kill-server")
  rmSync(TMPDIR, { recursive: true, force: true })
})

test("a hook for a pane that is gone does nothing (no toast, no banner)", () => {
  tmux("set", "-g", "@agents-notify", "both")
  const gone = tmux("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", pane, "exec sleep 600")
  tmux("kill-pane", "-t", gone)
  for (const p of ["%999", gone]) {
    const r = bin(p, ["claude-hook"], JSON.stringify({ hook_event_name: "Notification", notification_type: "permission_prompt" }))
    expect(r.exitCode).toBe(0)
    expect(r.stderr.toString()).toBe("")
  }
  Bun.sleepSync(400) // the toast runs in the background
  expect(tmux("show", "-gqv", "@agents_flash_id")).toBe("")
})

test("an agent name with quotes and semicolons is not run as tmux commands", () => {
  const evil = 'x";kill-server;"kill-server'
  bin(pane, ["report", "working", evil])
  expect(opt(pane, "@agent")).toBe(evil)
  tmux("set", "-w", "-t", win, "@agent_win_state", "idle") // a stale tab
  bin(pane, ["sweep"])
  expect(tmux("list-sessions", "-F", "#{session_name}")).toContain("keep")
  expect(wopt(win, "@agent_win_state")).toBe("working")
  expect(wopt(win, "@agent_win_agent")).toBe(evil)
})

test("an agent name with spaces is kept whole on the tab", () => {
  bin(pane, ["report", "blocked", "my agent", "needs approval"])
  expect(wopt(win, "@agent_win_state")).toBe("blocked")
  expect(wopt(win, "@agent_win_agent")).toBe("my agent")
  tmux("set", "-w", "-t", win, "@agent_win_state", "idle")
  bin(pane, ["sweep"])
  expect(wopt(win, "@agent_win_state")).toBe("blocked")
  expect(wopt(win, "@agent_win_agent")).toBe("my agent")
})

test("newlines, tabs and other control characters in a note or name become spaces", () => {
  bin(pane, ["report", "blocked", "my\tagent", "line one\nline\ttwo\x1b[31m"])
  expect(opt(pane, "@agent_note")).toBe("line one line two [31m")
  expect(opt(pane, "@agent")).toBe("my agent")
})

test('@agents-notify-on "off": no notification', () => {
  tmux("set", "-g", "@agents-notify", "sidebar")
  tmux("set", "-g", "@agents-notify-on", "off")
  bin(pane, ["report", "blocked", "claude", "needs approval"])
  Bun.sleepSync(400)
  expect(tmux("show", "-gqv", "@agents_flash_id")).toBe("")
  // The default ("blocked") does notify.
  tmux("set", "-gu", "@agents-notify-on")
  bin(pane, ["report", "working", "claude"])
  bin(pane, ["report", "blocked", "claude", "needs approval"])
  expect(until(() => tmux("show", "-gqv", "@agents_flash_id") !== "")).toBe(true)
})

test("a long window name does not push the toast's first line out", () => {
  tmux("set", "-g", "@agents-toast-seconds", "5")
  const where = "a-very-long-window-name-that-is-much-wider-than-the-toast-itself"
  tmux("new-session", "-d", "-s", "t", "-x", "30", "-y", "2",
    `exec '${BIN}' toast-body blocked claude 'my project' 'needs approval' '${where}'`)
  expect(until(() => tmux("capture-pane", "-p", "-t", "=t:").includes("needs"))).toBe(true)
  const rows = tmux("capture-pane", "-p", "-t", "=t:").split("\n")
  tmux("kill-session", "-t", "=t")
  tmux("set", "-gu", "@agents-toast-seconds")
  expect(rows[0]).toContain("my project")
  expect(rows[1]).toContain("needs approval")
})

test("moving an agent pane to another window moves its tab icon at once (pane-moved hook)", () => {
  const other = tmux("split-window", "-d", "-h", "-P", "-F", "#{pane_id}", "-t", pane, "exec sleep 600")
  bin(other, ["report", "blocked", "claude", "needs approval"])
  expect(wopt(win, "@agent_win_state")).toBe("blocked")
  const nw = tmux("break-pane", "-d", "-P", "-F", "#{window_id}", "-s", other)
  expect(until(() => wopt(nw, "@agent_win_state") === "blocked" && wopt(win, "@agent_win_state") === "")).toBe(true)
  tmux("join-pane", "-d", "-h", "-s", other, "-t", pane)
  expect(until(() => wopt(win, "@agent_win_state") === "blocked")).toBe(true)
})

test("toasts fired at the same moment get their own slots", async () => {
  tmux("new-session", "-d", "-s", "c", "-x", "120", "-y", "30", "exec sleep 600")
  const client = Bun.spawn(["tmux", "-L", SOCK, "-C", "attach", "-t", "=c"], { env, stdin: "pipe", stdout: "ignore", stderr: "ignore" })
  expect(until(() => tmux("list-clients", "-F", "#{session_name}") === "c")).toBe(true)
  const cw = tmux("display", "-p", "-t", "=c:", "#{window_id}")
  tmux("set", "-g", "@agents-toast-seconds", "8")
  const runs = [1, 2, 3, 4].map((i) =>
    Bun.spawn([BIN, "toast", "blocked", "claude", `agent ${i}`, "needs approval", "1"], { env: sockEnv() }).exited)
  await Promise.all(runs)
  const tops = toasts(cw).map((l) => l.split(" ")[1])
  tmux("set", "-gu", "@agents-toast-seconds")
  for (const t of toasts(cw)) tmux("kill-pane", "-t", t.split(" ")[0])
  client.kill()
  tmux("kill-session", "-t", "=c")
  expect(tops).toHaveLength(4)
  expect(new Set(tops).size).toBe(4)
})
