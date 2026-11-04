// Drives opencode/tui.js with a fake OpenCode V2 TUI API against a private
// tmux server (`tmux -L tmux-agents-test`), and checks what lands in tmux.
// Run from tmux-agents/: bun test

import { afterAll, beforeAll, expect, test } from "bun:test"

const SOCKET = "tmux-agents-test"
const tmux = (...args: string[]) =>
  Bun.spawnSync(["tmux", "-L", SOCKET, ...args], { stderr: "ignore" }).stdout.toString().trim()

let pane = ""

beforeAll(() => {
  tmux("kill-server")
  Bun.spawnSync(["tmux", "-L", SOCKET, "-f", "/dev/null", "new-session", "-d", "-s", "t", "exec sleep 600"])
  tmux("set", "-g", "@agents-notify", "off")
  pane = tmux("list-panes", "-t", "t", "-F", "#{pane_id}")
  // tui.js and bin/tmux-agents talk to tmux through these, like inside a pane.
  process.env.TMUX = `${tmux("display", "-p", "#{socket_path}")},1,0`
  process.env.TMUX_PANE = pane
})

afterAll(() => {
  tmux("kill-server")
})

const state = () => tmux("display", "-p", "-t", pane, "#{@agent_state}|#{@agent_note}")

async function until(expected: string, ms = 3000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (state() === expected) return
    await Bun.sleep(25)
  }
  expect(state()).toBe(expected)
}

// Minimal fake of the host API surface tui.js uses.
function fakeApi() {
  let route: any = { type: "home" }
  const sessions = new Map<string, any>([["ses_a", { id: "ses_a" }], ["ses_child", { id: "ses_child", parentID: "ses_a" }]])
  const forms = new Map<string, any[]>()
  const status = new Map<string, string>()
  let listener: ((e: any) => void) | undefined
  const api = {
    ui: { router: { current: () => route } },
    data: {
      listen: (fn: (e: any) => void) => {
        listener = fn
        return () => {
          listener = undefined
        }
      },
      session: {
        get: (id: string) => sessions.get(id),
        status: (id: string) => status.get(id) ?? "idle",
        family: (id: string) => [...sessions.values()].filter((s) => s.parentID === id).map((s) => s.id),
        permission: { list: () => [] },
        form: { list: (id: string) => forms.get(id) ?? [] },
      },
    },
  }
  return {
    api,
    go: (r: any) => {
      route = r
    },
    emit: (type: string, data: any) => listener?.({ details: { type, data } }),
    forms,
    status,
  }
}

const plugin = (await import("../opencode/tui.js")).default

test("fast started -> succeeded burst ends as done, never stuck working", async () => {
  const f = fakeApi()
  const dispose = plugin.setup(f.api)
  f.go({ type: "session", sessionID: "ses_a" })
  await Bun.sleep(300) // route poll picks the session
  for (let i = 0; i < 5; i++) {
    f.emit("session.execution.started", { sessionID: "ses_a" })
    f.emit("session.execution.succeeded", { sessionID: "ses_a" })
  }
  await until("done|")
  await Bun.sleep(400) // nothing late may overwrite it
  expect(state()).toBe("done|")
  dispose()
})

test("a pending question survives navigating away and back", async () => {
  const f = fakeApi()
  const dispose = plugin.setup(f.api)
  f.status.set("ses_a", "running")
  f.go({ type: "session", sessionID: "ses_a" })
  await until("working|")

  // Question asked by a subagent, also present in the host cache.
  f.forms.set("ses_child", [{ id: "frm_1", sessionID: "ses_child" }])
  f.emit("form.created", { form: { id: "frm_1", sessionID: "ses_child" } })
  await until("blocked|asking a question")

  f.go({ type: "home" })
  await until("idle|")
  f.go({ type: "session", sessionID: "ses_a" })
  await until("blocked|asking a question")

  f.forms.delete("ses_child")
  f.emit("form.replied", { id: "frm_1", sessionID: "ses_child" })
  await until("working|")
  dispose()
})

test("dispose clears the pane", async () => {
  const f = fakeApi()
  const dispose = plugin.setup(f.api)
  await until("idle|")
  dispose()
  expect(tmux("display", "-p", "-t", pane, "#{@agent}")).toBe("")
})
