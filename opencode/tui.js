// tmux-agents reporter for the OpenCode V2 TUI.
//
// Runs inside each `opencode` TUI process, which knows its own tmux pane
// ($TMUX_PANE). It follows the session shown in this TUI (plus its subagent
// sessions) and reports the state to tmux through bin/tmux-agents:
//   working  the session is executing
//   blocked  a permission request or question (form) waits for you,
//            or the run failed
//   done     the run finished (the tmux side turns it into idle once seen)
//   idle     interrupted, or no session open
//
// Plain JS, no dependencies: the V2 loader resolves this directory's tui.js.

import { spawn, spawnSync } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const BIN = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "tmux-agents")
const ROUTE_POLL_MS = 250
const REPORT_TIMEOUT_MS = 3000

// Reports go out one at a time and only the newest pending one is kept, so
// a fast started -> succeeded can never land in tmux in the wrong order.
let pending
let busy = false
let running // the report child in flight, killed on exit

function report(args) {
  pending = args
  if (!busy) pump()
}

function pump() {
  const args = pending
  pending = undefined
  if (!args) {
    busy = false
    return
  }
  busy = true
  let done = false
  const next = () => {
    if (done) return
    done = true
    clearTimeout(timer)
    pump()
  }
  const timer = setTimeout(next, REPORT_TIMEOUT_MS)
  try {
    // Own process group, so exit can kill the script and its tmux calls.
    const child = spawn(BIN, args, { stdio: "ignore", detached: true })
    running = child
    child.on("error", next)
    child.on("exit", () => {
      if (running === child) running = undefined
      next()
    })
  } catch {
    next()
  }
}

function setup(api) {
  if (!process.env.TMUX_PANE) return

  let selected // root session shown in this TUI
  let state = "idle"
  let note = ""
  const blockers = new Map() // "permission:<id>" | "form:<id>" -> note
  let last = ""

  function root(id) {
    const seen = new Set()
    while (typeof id === "string" && !seen.has(id)) {
      seen.add(id)
      const session = api.data.session.get(id)
      if (!session) return id // not hydrated yet: treat as its own root
      if (!session.parentID) return id
      id = session.parentID
    }
  }

  function current() {
    try {
      const route = api.ui.router.current()
      return route?.type === "session" ? root(route.sessionID) : undefined
    } catch {
      return undefined
    }
  }

  function publish() {
    const [s, n] = blockers.size ? ["blocked", [...blockers.values()].at(-1)] : [state, note]
    const key = `${s}\t${n}`
    if (key === last) return
    last = key
    report(["report", s, "opencode", n])
  }

  // Pending permissions/questions of the session and its subagents, read
  // from the host cache, so returning to a session that still waits for you
  // shows blocked again. A kind whose cache is not loaded yet is skipped.
  function hydrate(id) {
    blockers.clear()
    if (!id) return
    let members = [id]
    try {
      members = [id, ...(api.data.session.family?.(id) ?? [])]
    } catch {}
    for (const member of members) {
      for (const [kind, label] of [
        ["permission", "needs approval"],
        ["form", "asking a question"],
      ]) {
        try {
          for (const item of api.data.session[kind]?.list?.(member) ?? []) {
            if (item?.id) blockers.set(`${kind}:${item.id}`, label)
          }
        } catch {}
      }
    }
  }

  function select() {
    const id = current()
    if (id === selected) return
    selected = id
    hydrate(id)
    note = ""
    let running = false
    try {
      running = !!id && api.data.session.status(id) === "running"
    } catch {}
    state = running ? "working" : "idle"
    publish()
  }

  function receive({ details: event }) {
    const data = event?.data
    if (!data) return
    select()
    const id = event.type === "form.created" ? data.form?.sessionID : data.sessionID
    if (!selected || root(id) !== selected) return
    switch (event.type) {
      case "permission.asked":
        blockers.set(`permission:${data.id}`, "needs approval")
        break
      case "permission.replied":
        blockers.delete(`permission:${data.requestID}`)
        break
      case "form.created":
        blockers.set(`form:${data.form?.id}`, "asking a question")
        break
      case "form.replied":
      case "form.cancelled":
        blockers.delete(`form:${data.id}`)
        break
      case "session.execution.started":
        if (id !== selected) return
        state = "working"
        note = ""
        break
      case "session.execution.succeeded":
        if (id !== selected) return
        state = "done"
        note = ""
        break
      case "session.execution.interrupted":
        if (id !== selected) return
        state = "idle"
        note = ""
        break
      case "session.execution.failed":
        if (id !== selected) return
        state = "blocked"
        note = "run failed"
        break
      default:
        return
    }
    publish()
  }

  const unsubscribe = api.data.listen(receive)
  select()
  publish() // register the pane even before a session is opened
  const poll = setInterval(() => {
    select()
    publish() // no-op unless state or note changed
  }, ROUTE_POLL_MS)
  // On exit there is no event loop left: clear synchronously (bounded).
  const bye = () => {
    pending = undefined
    // A report still in flight could land after the clear and bring the
    // card back: kill it (whole group) first.
    try {
      if (running?.pid) process.kill(-running.pid, "SIGKILL")
    } catch {}
    running = undefined
    try {
      spawnSync(BIN, ["clear", process.env.TMUX_PANE], { stdio: "ignore", timeout: 1000 })
    } catch {}
  }
  process.once("exit", bye)

  return () => {
    clearInterval(poll)
    unsubscribe?.()
    process.off("exit", bye)
    bye()
  }
}

export default { id: "tmux-agents.opencode", setup }
