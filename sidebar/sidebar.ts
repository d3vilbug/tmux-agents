#!/usr/bin/env bun
// Agents sidebar: a live list of every tmux pane that runs a coding agent.
// Runs inside a narrow tmux pane created by `tmux-agents sidebar`. State is
// read from pane user options written by the agent hooks (see bin/tmux-agents).
//
// Keys: j/k or arrows move, Enter jumps, x forgets the selected entry,
// q closes the sidebar. Mouse: click an entry to jump, wheel moves.
// Card title: the window name you gave the tab, else the directory.
// Icons need a Nerd Font. Colors/icons come from defaults.conf, overridden by
// tmux options of the same name. Agents that exit without a hook are cleaned
// up by `tmux-agents sweep`, which the 1 s tick runs.

const STATES = ["blocked", "done", "working", "idle"] as const
type State = (typeof STATES)[number]
const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

type Agent = {
  pane: string
  session: string
  window: string
  slot: number // 0-based position among the window's real panes
  windowPanes: number // real panes in the window (no sidebar, no floating)
  agent: string
  state: State
  since: number
  note: string
  name: string // window name you gave the tab, else the directory
  path: string
  viewing: boolean
}

const self = process.env.TMUX_PANE ?? ""
const bin = `${import.meta.dir}/../bin/tmux-agents`

function tmux(...args: string[]): string {
  const r = Bun.spawnSync(["tmux", ...args], { stderr: "ignore" })
  return r.success ? r.stdout.toString() : ""
}

// defaults.conf, then tmux overrides (one round trip).
const opts = new Map<string, string>()
for (const l of (await Bun.file(`${import.meta.dir}/../defaults.conf`).text()).split("\n")) {
  const m = l.match(/^(@agents-[\w-]+) ?(.*)$/)
  if (m) opts.set(m[1], m[2])
}
// `show -g` quotes values: '' for empty, "..." with \-escapes when needed.
const unquote = (v: string) =>
  /^'.*'$/.test(v) ? v.slice(1, -1) : /^".*"$/.test(v) ? v.slice(1, -1).replace(/\\(.)/g, "$1") : v
for (const l of tmux("show", "-g").split("\n")) {
  const m = l.match(/^(@agents-[\w-]+) (.*)$/)
  if (m) opts.set(m[1], unquote(m[2]))
}
const option = (name: string) => opts.get(name) ?? ""

const C = {
  blocked: option("@agents-color-blocked"),
  done: option("@agents-color-done"),
  working: option("@agents-color-working"),
  idle: option("@agents-color-idle"),
  title: option("@agents-color-title"),
  text: option("@agents-color-text"),
  muted: option("@agents-color-muted"),
  faint: option("@agents-color-faint"),
  select: option("@agents-color-select"),
  viewing: option("@agents-color-viewing"),
  header: option("@agents-color-header"),
  border: option("@agents-color-border"),
  dark: option("@agents-color-bg"),
  claude: option("@agents-color-claude"),
  opencode: option("@agents-color-opencode"),
  codex: option("@agents-color-codex"),
  agent: option("@agents-color-agent"),
}
const ICON = {
  blocked: option("@agents-icon-blocked"),
  done: option("@agents-icon-done"),
  working: option("@agents-icon-working"),
  idle: option("@agents-icon-idle"),
  claude: option("@agents-icon-claude"),
  opencode: option("@agents-icon-opencode"),
  codex: option("@agents-icon-codex"),
  agent: option("@agents-icon-agent"),
  window: option("@agents-icon-window"),
  viewing: option("@agents-icon-viewing"),
  header: option("@agents-icon-header"),
}
// Full-height line in the sidebar's last column ("" = none), so its edge
// shows even when pane borders match the background.
const BORDER = option("@agents-sidebar-border")

// How the card of the pane you are looking at is marked (@agents-show-viewing):
// "tint" = background like the status bar's current tab, "eye" = eye icon,
// "off" = not marked.
const VIEWING = option("@agents-show-viewing")

// Two-row block-art icons for cards ("top|bottom"); an agent without art
// (or with the option set to "") falls back to its one-cell glyph.
const ART: Record<string, [string, string]> = {}
for (const agent of ["claude", "opencode", "codex", "agent"]) {
  const v = option(`@agents-art-${agent}`)
  if (v.includes("|")) ART[agent] = v.split("|", 2) as [string, string]
}
const artOf = (agent: string): [string, string] | undefined => ART[agent] ?? ART.agent
const SECTION: Record<State, string> = {
  blocked: "NEEDS YOU",
  done: "DONE",
  working: "WORKING",
  idle: "IDLE",
}
const LABEL: Record<State, string> = {
  blocked: "needs input",
  done: "finished",
  working: "working",
  idle: "idle",
}

const rgb = (hex: string) => {
  const n = Number.parseInt(hex.replace("#", ""), 16)
  return `${(n >> 16) & 255};${(n >> 8) & 255};${n & 255}`
}
const fg = (hex: string) => `\x1b[38;2;${rgb(hex)}m`
const bg = (hex: string) => `\x1b[48;2;${rgb(hex)}m`
const BOLD = "\x1b[1m"
const RESET = "\x1b[0m"

// --- data --------------------------------------------------------------------

const FIELDS = [
  "#{pane_id}",
  "#{session_name}",
  "#{window_id}",
  "#{window_index}",
  "#{?#{||:#{@agents_sidebar},#{||:#{pane_floating_flag},#{@agents_toast}}},1,0}",
  "#{@agent}",
  "#{@agent_state}",
  "#{@agent_since}",
  "#{@agent_note}",
  "#{?#{automatic-rename},,#{window_name}}",
  "#{pane_current_path}",
  "#{&&:#{window_active},#{session_attached}}",
  "#{pane_active}",
  "#{pane_last}",
  "#{@agents_sidebar}",
].join("\t")

function basename(p: string): string {
  return p.split("/").filter(Boolean).at(-1) ?? "/"
}

function load(): Agent[] {
  const rows = tmux("list-panes", "-a", "-F", FIELDS)
    .split("\n")
    .filter(Boolean)
    .map((l) => l.split("\t"))
  // Real panes per window, in index order, so "2.1" ignores the sidebar.
  const real = new Map<string, string[]>()
  // Windows whose active pane is the sidebar: you look at their last pane.
  const sidebarActive = new Set<string>()
  for (const f of rows) {
    if (f[14] === "1" && f[12] === "1") sidebarActive.add(f[2])
    if (f[4] === "1") continue
    const list = real.get(f[2]) ?? []
    list.push(f[0])
    real.set(f[2], list)
  }
  const list: Agent[] = []
  for (const f of rows) {
    if (!f[5]) continue
    const panes = real.get(f[2]) ?? []
    const shown = f[11] === "1"
    list.push({
      pane: f[0],
      session: f[1],
      window: f[3],
      slot: Math.max(0, panes.indexOf(f[0])),
      windowPanes: Math.max(1, panes.length),
      agent: f[5],
      state: (STATES as readonly string[]).includes(f[6]) ? (f[6] as State) : "idle",
      since: Number(f[7]) || 0,
      note: f[8],
      name: f[9] || basename(f[10]),
      path: f[10],
      viewing: shown && (sidebarActive.has(f[2]) ? f[13] === "1" : f[12] === "1"),
    })
  }
  // Sections in urgency order; blocked: longest waiting first, others: newest.
  const order = (s: State) => STATES.indexOf(s)
  list.sort(
    (x, y) => order(x.state) - order(y.state) || (x.state === "blocked" ? x.since - y.since : y.since - x.since),
  )
  return list
}

// --- rendering ---------------------------------------------------------------

let agents: Agent[] = []
let selected = 0
let focused = false
let frame = 0
let scroll = 0
let rowsOf: { start: number; end: number }[] = [] // screen rows per entry
let bodyRows = 0 // screen rows of the card list (below: banner, footer)
let sessions = 1

// Notification banner: bin/tmux-agents writes @agents_flash_* options; a
// new @agents_flash_id blinks for FLASH_MS. Read in one display call.
const FLASH_MS = 3000
const FLASH_FORMAT = ["id", "state", "agent", "name", "text", "where"].map((k) => `#{@agents_flash_${k}}`).join("\t")
const readFlashRaw = () => tmux("display", "-p", FLASH_FORMAT).replace(/\n$/, "").split("\t")
let flashSeen = readFlashRaw()[0] // ignore notices from before we started
let flash: { state: State; agent: string; name: string; text: string; where: string; until: number } | undefined

function readFlash() {
  const [id, state, agent, name, text, where] = readFlashRaw()
  if (!id || id === flashSeen) return
  flashSeen = id
  flash = {
    state: (STATES as readonly string[]).includes(state) ? (state as State) : "done",
    agent,
    name,
    text,
    where: where ?? "",
    until: Date.now() + FLASH_MS,
  }
}

const len = (s: string) => [...s].length

function age(since: number): string {
  if (!since) return ""
  const s = Math.max(0, Math.floor(Date.now() / 1000) - since)
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

function cut(s: string, n: number): string {
  if (n <= 0) return ""
  const chars = [...s]
  return chars.length <= n ? s : `${chars.slice(0, n - 1).join("")}…`
}

function where(a: Agent): string {
  const base = sessions > 1 ? `${a.session}:${a.window}` : a.window
  return a.windowPanes > 1 ? `${base}.${a.slot}` : base
}

function brand(agent: string): { icon: string; color: string } {
  if (agent === "claude") return { icon: ICON.claude, color: C.claude }
  if (agent === "opencode") return { icon: ICON.opencode, color: C.opencode }
  if (agent === "codex") return { icon: ICON.codex, color: C.codex }
  return { icon: ICON.agent, color: C.agent }
}

function stateIcon(state: State): string {
  if (state === "working" && ICON.working === "spinner") return SPINNER[frame % SPINNER.length]
  return ICON[state]
}

// A styled line made of segments, padded/cut to `width`. `base` is a
// background re-applied after every segment (selection highlight).
type Seg = [text: string, style?: string]
function line(width: number, left: Seg[], right: Seg[] = [], base = ""): string {
  const rightLen = right.reduce((n, [t]) => n + len(t), 0)
  let room = width - rightLen - (rightLen ? 1 : 0)
  let out = base
  for (const [t, style = ""] of left) {
    if (room <= 0) break
    const text = cut(t, room)
    room -= len(text)
    out += `${style}${text}${RESET}${base}`
  }
  out += " ".repeat(Math.max(0, room + (rightLen ? 1 : 0)))
  for (const [t, style = ""] of right) out += `${style}${t}${RESET}${base}`
  return `${out}${RESET}`
}

function render() {
  const COLS = process.stdout.columns || 26
  // Content width: the last column holds the right border line, if any.
  const W = BORDER ? COLS - 1 : COLS
  const H = process.stdout.rows || 24
  const lines: string[] = []
  const entryRows: { start: number; end: number }[] = []

  // Header: title + total, a state meter (full-width bar split by state
  // color, sized by count), then the count per state.
  lines.push(line(W, [[` ${ICON.header} AGENTS`, `${BOLD}${fg(C.header)}`]], [[`${agents.length} `, fg(C.muted)]]))
  const counts = STATES.map((s) => agents.filter((a) => a.state === s).length)
  const span = Math.max(0, W - 2)
  const meter: Seg[] = [[" "]]
  if (agents.length === 0) meter.push(["━".repeat(span), fg(C.faint)])
  else {
    // Every state present gets one cell (while there is room), the rest is
    // split by share with largest-remainder rounding, so cells sum to span.
    const present = counts.flatMap((n, k) => (n > 0 ? [{ n, k }] : []))
    const cells = present.map((_, i) => (i < span ? 1 : 0))
    const extra = span - cells.reduce((a, b) => a + b, 0)
    const exact = present.map(({ n }) => (n / agents.length) * extra)
    exact.forEach((x, i) => (cells[i] += Math.floor(x)))
    let left = span - cells.reduce((a, b) => a + b, 0)
    for (const i of exact.map((_, i) => i).sort((a, b) => (exact[b] % 1) - (exact[a] % 1))) {
      if (left-- <= 0) break
      cells[i]++
    }
    present.forEach(({ k }, i) => {
      if (cells[i] > 0) meter.push(["━".repeat(cells[i]), fg(C[STATES[k]])])
    })
  }
  lines.push(line(W, meter))
  const chips: Seg[] = [[" "]]
  counts.forEach((n, k) => {
    if (n) chips.push([`${stateIcon(STATES[k])} ${n}`, `${BOLD}${fg(C[STATES[k]])}`], ["  "])
  })
  lines.push(agents.length ? line(W, chips) : "")

  if (agents.length === 0) {
    const mid = Math.max(lines.length + 1, Math.floor(H / 2) - 3)
    while (lines.length < mid) lines.push("")
    const center = (t: string, style: string) =>
      `${" ".repeat(Math.max(0, Math.floor((W - len(t)) / 2)))}${style}${cut(t, W)}${RESET}`
    lines.push(center(ICON.header, fg(C.faint)), "")
    lines.push(center("No agents yet", `${BOLD}${fg(C.text)}`))
    lines.push(center("start claude, codex", fg(C.muted)))
    lines.push(center("or opencode in any", fg(C.muted)))
    lines.push(center("pane", fg(C.muted)))
  }

  // Width of the icon column: the widest art in use, else one glyph.
  let artW = 1
  for (const a of agents) {
    const art = artOf(a.agent)
    if (art) artW = Math.max(artW, len(art[0]), len(art[1]))
  }

  let section: State | undefined
  agents.forEach((a, i) => {
    if (a.state !== section) {
      section = a.state
      const n = agents.filter((x) => x.state === a.state).length
      const label = ` ${SECTION[a.state]} `
      const count = `${n} `
      lines.push("")
      lines.push(
        line(W, [
          ["─", fg(C.faint)],
          [label, `${BOLD}${fg(C[a.state])}`],
          [count, fg(C.muted)],
          ["─".repeat(Math.max(0, W - 1 - len(label) - len(count))), fg(C.faint)],
        ]),
      )
    } else {
      lines.push("")
    }
    // Focused: only the keyboard cursor is highlighted (same color as the tint).
    const on = focused
      ? i === selected ? bg(C.select) : ""
      : VIEWING === "tint" && a.viewing ? bg(C.viewing) : ""
    const bar = `${fg(C[a.state])}▎${RESET}`
    const b = brand(a.agent)
    const inner = W - 1
    const start = lines.length

    // Icon column: two-row art (same width on every card so names line up),
    // or the one-cell glyph with the viewing mark under it.
    const art = artOf(a.agent)
    const pad = (t: string) => t + " ".repeat(Math.max(0, artW - len(t)))
    const viewing = VIEWING === "eye" && a.viewing
    const eyeRight = viewing && (art || artW > 1)
    const top = art ? art[0] : b.icon
    const bottom = art ? art[1] : viewing && !eyeRight ? ICON.viewing : ""
    const bottomStyle = art ? fg(b.color) : fg(C.title)
    // 1: agent icon + name ............ window
    const loc: Seg[] = [[`${ICON.window} ${where(a)} `, fg(C.muted)]]
    lines.push(bar + line(inner, [[`${pad(top)} `, fg(b.color)], [a.name, `${BOLD}${fg(C.text)}`]], loc, on))
    // 2: icon bottom (or viewing mark), state / note ...... [viewing] age
    const right: Seg[] = [[`${age(a.since)} `, fg(C.muted)]]
    if (eyeRight) right.unshift([`${ICON.viewing} `, fg(C.title)])
    lines.push(
      bar +
        line(
          inner,
          [[`${pad(bottom)} `, bottomStyle], [`${stateIcon(a.state)} ${a.note || LABEL[a.state]}`, fg(C[a.state])]],
          right,
          on,
        ),
    )
    entryRows.push({ start, end: lines.length - 1 })
  })

  // Footer: key hints while focused, nothing otherwise.
  const key = (k: string): Seg => [` ${k} `, `${bg(C.select)}${fg(C.text)}`]
  const footer = focused
    ? line(W, [[" "], key("⏎"), [" jump ", fg(C.muted)], key("x"), [" drop ", fg(C.muted)], key("q"), [" hide", fg(C.muted)]])
    : ""

  // Credit line on the last row.
  const credit = line(W, [[" by d3vilbug", fg(C.faint)]])

  // Notification banner (2 rows) blinking above the footer.
  const banner: string[] = []
  if (flash && Date.now() < flash.until) {
    const lit = Math.floor((flash.until - Date.now()) / 300) % 2 === 0
    const b = brand(flash.agent)
    const style = lit ? `${BOLD}${bg(C[flash.state])}${fg(C.dark)}` : `${BOLD}${bg(C.select)}${fg(C[flash.state])}`
    const icon = flash.state === "working" ? stateIcon("working") : ICON[flash.state]
    banner.push(line(W, [[` ${b.icon} ${flash.name}`, style]], [], style))
    banner.push(line(W, [[` ${icon} ${flash.text}`, style]], [[`${ICON.window} ${flash.where} `, style]], style))
  } else {
    flash = undefined
  }

  // Keep the selected card on screen.
  const body = H - (footer ? 3 : 2) - banner.length
  const sel = entryRows[selected]
  if (sel) {
    if (sel.end - scroll >= body) scroll = sel.end - body + 1
    if (sel.start - 2 < scroll) scroll = Math.max(0, sel.start - 2)
  }
  if (lines.length <= body) scroll = 0
  const view = lines.slice(scroll, scroll + body)
  while (view.length < body) view.push("")
  rowsOf = entryRows.map((r) => ({ start: r.start - scroll, end: r.end - scroll }))
  bodyRows = body
  view.push(...banner, "")
  if (footer) view.push(footer)
  view.push(credit)

  // Each row: content, clear to the end, then the border in the last column.
  const edge = BORDER ? `\x1b[${COLS}G${fg(C.border)}${BORDER}${RESET}` : ""
  process.stdout.write(`\x1b[H${view.map((l) => `${l}\x1b[K${edge}`).join("\r\n")}`)
}

function refresh() {
  const prev = agents[selected]?.pane
  agents = load()
  readFlash()
  sessions = new Set(tmux("list-sessions", "-F", "#{session_name}").split("\n").filter(Boolean)).size
  const keep = agents.findIndex((a) => a.pane === prev)
  selected = keep >= 0 ? keep : Math.max(0, Math.min(selected, agents.length - 1))
  render()
}

// --- actions -----------------------------------------------------------------

function jump(a: Agent | undefined) {
  if (!a) return
  // Window + pane work without a client; switch-client only matters when the
  // agent lives in another session (and fails harmlessly otherwise).
  tmux("select-window", "-t", a.pane, ";", "select-pane", "-t", a.pane)
  tmux("switch-client", "-t", a.pane)
}

function forget(a: Agent | undefined) {
  if (!a) return
  Bun.spawnSync([bin, "clear", a.pane])
  refresh()
}

function quit() {
  process.stdout.write("\x1b[?1004l\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l")
  process.exit(0)
}

// Input arrives batched ("j\r" in one chunk), so split it into keys first.
const TOKEN = /\x1b\[<(\d+);(\d+);(\d+)([Mm])|\x1b\[[A-DIO]|\x1b|[\s\S]/g

function onKey(k: string, mouse?: RegExpMatchArray) {
  if (mouse) {
    // SGR mouse: ESC [ < button ; x ; y (M press | m release)
    const button = Number(mouse[1])
    const row = Number(mouse[3]) - 1
    if (button === 64) selected = Math.max(0, selected - 1)
    else if (button === 65) selected = Math.max(0, Math.min(agents.length - 1, selected + 1))
    else if (button === 0 && mouse[4] === "M") {
      const hit = row < bodyRows ? rowsOf.findIndex((r) => row >= r.start && row <= r.end) : -1
      if (hit >= 0) {
        selected = hit
        render()
        jump(agents[hit])
      }
    }
    return
  }
  if (k === "\x1b[I") focused = true
  else if (k === "\x1b[O") focused = false
  else if (k === "j" || k === "\x1b[B") selected = Math.max(0, Math.min(agents.length - 1, selected + 1))
  else if (k === "k" || k === "\x1b[A") selected = Math.max(0, selected - 1)
  else if (k === "\r" || k === "\n") jump(agents[selected])
  else if (k === "x") forget(agents[selected])
  else if (k === "r") refresh()
  else if (k === "q" || k === "\x03") {
    Bun.spawnSync([bin, "sidebar", "toggle"])
    quit()
  }
}

function onInput(data: Buffer) {
  for (const m of data.toString().matchAll(TOKEN)) onKey(m[0], m[1] ? m : undefined)
  render()
}

// Tab icon animations for working agents. Tabs cannot animate on their own
// and setting a tmux option repaints the whole screen, so the sidebar puts
// the frames in its pane title (OSC 2: tmux redraws only the status line) and
// the tab format reads them from there:
//   agents=<claude>|<opencode, inactive tab>|<opencode, current tab>
// Frames are picked by elapsed time, so the tick rate only sets smoothness.

// Claude: Claude Code's own spinner, thin to fat and back (each end twice).
const CLAUDE_FRAMES = [...option("@agents-tab-claude-frames")]
CLAUDE_FRAMES.push(...[...CLAUDE_FRAMES].reverse())
const CLAUDE_MS = Number(option("@agents-tab-claude-frame-ms")) || 250

// Codex: its own braille spinner.
const CODEX_FRAMES = [...option("@agents-tab-codex-frames")]
const CODEX_MS = Number(option("@agents-tab-codex-frame-ms")) || 125

// OpenCode: its own "blocks" scanner (opencode TUI, Knight Rider style): a
// lit ■ with a fading 6-step trail sweeping over ⬝ dots, both ways, holding
// 30 frames at the start and 9 at the end while the dots fade; 40 ms frames.
const OC_WIDTH = Number(option("@agents-tab-opencode-width")) || 4
const OC_MS = 40
const OC_HOLD_START = 30
const OC_HOLD_END = 9
const OC_TRAIL = Array.from({ length: 6 }, (_, h) => ({
  alpha: h === 0 ? 1 : h === 1 ? 0.9 : 0.65 ** (h - 1),
  boost: h === 1 ? 1.15 : 1,
}))
const rgbOf = (h: string) => rgb(h).split(";").map(Number)
// Tab backgrounds the scanner is blended over: inactive tabs sit on the
// status bar (@agents-color-bg), the current tab on @agents-color-viewing.
const OC_RGB = rgbOf(C.opencode)
const TAB_BG = rgbOf(C.dark)
const TAB_CURRENT_BG = rgbOf(C.viewing)
// Color `c` at `alpha` over `under`, as a tmux style.
const mixStyle = (c: number[], alpha: number, under: number[], boost = 1) =>
  `#[fg=#${c.map((v, i) => Math.round(Math.min(255, v * boost) * alpha + under[i] * (1 - alpha)).toString(16).padStart(2, "0")).join("")}]`
function scanner(n: number, bgc: number[]): string {
  const w = OC_WIDTH
  const total = w + OC_HOLD_END + (w - 1) + OC_HOLD_START
  const f = n % total
  let at: number, hold: boolean, fwd: boolean, hp = 0, ht = 0, mp = 0, mt = 0
  if (f < w) [at, hold, fwd, mp, mt] = [f, false, true, f, w]
  else if (f < w + OC_HOLD_END) [at, hold, fwd, hp, ht] = [w - 1, true, true, f - w, OC_HOLD_END]
  else if (f < w + OC_HOLD_END + w - 1) {
    mp = f - w - OC_HOLD_END
    ;[at, hold, fwd, mt] = [w - 2 - mp, false, false, w - 1]
  } else [at, hold, fwd, hp, ht] = [0, true, false, f - w - OC_HOLD_END - (w - 1), OC_HOLD_START]
  // Idle dots fade out while holding and back in while moving (min 0.3).
  let fade = 1
  if (hold && ht > 0) fade = Math.max(0.3, 1 - Math.min(hp / ht, 1) * 0.7)
  else if (!hold && mt > 0) fade = 0.3 + Math.min(mp / Math.max(1, mt - 1), 1) * 0.7
  const color = OC_RGB
  let out = ""
  for (let r = 0; r < w; r++) {
    const d = fwd ? at - r : r - at
    const p = hold ? d + hp : d >= 0 && d < OC_TRAIL.length ? d : -1
    if (p >= 0 && p < OC_TRAIL.length) out += `${mixStyle(color, OC_TRAIL[p].alpha, bgc, OC_TRAIL[p].boost)}■`
    else out += `${mixStyle(color, 0.6 * fade, bgc)}⬝`
  }
  return out
}

const animStart = performance.now()
let lastTitle = ""
function tabFrames() {
  const t = performance.now() - animStart
  const working = (agent: string) => agents.some((a) => a.agent === agent && a.state === "working")
  const claude =
    CLAUDE_FRAMES.length > 0 && working("claude") ? CLAUDE_FRAMES[Math.floor(t / CLAUDE_MS) % CLAUDE_FRAMES.length] : ""
  const oc = working("opencode") ? Math.floor(t / OC_MS) : -1
  const codex =
    CODEX_FRAMES.length > 0 && working("codex") ? CODEX_FRAMES[Math.floor(t / CODEX_MS) % CODEX_FRAMES.length] : ""
  const title =
    claude || oc >= 0 || codex
      ? `agents=${claude}|${oc >= 0 ? scanner(oc, TAB_BG) : ""}|${oc >= 0 ? scanner(oc, TAB_CURRENT_BG) : ""}|${codex}`
      : "agents"
  if (title === lastTitle) return
  lastTitle = title
  process.stdout.write(`\x1b]2;${title}\x1b\\`)
}
// The title (and so the status line) only changes when a frame does.
setInterval(tabFrames, Number(option("@agents-tab-frame-ms")) || 40)

// --- main --------------------------------------------------------------------

// Before the pid is published: hooks poke it with SIGUSR1, whose default
// action would kill the process.
process.on("SIGUSR1", () => refresh())

if (self) {
  tmux(
    "set", "-p", "-t", self, "@agents_sidebar", "1", ";",
    "set", "-p", "-t", self, "@agents_sidebar_pid", String(process.pid), ";",
    "select-pane", "-t", self, "-T", "agents",
  )
  focused = tmux("display", "-p", "-t", self, "#{&&:#{pane_active},#{window_active}}").trim() === "1"
}

// Alt screen, hidden cursor, SGR mouse, focus in/out reports.
process.stdout.write("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[2J")
if (process.stdin.isTTY) process.stdin.setRawMode(true)
process.stdin.on("data", onInput)
process.stdout.on("resize", () => render())
process.on("SIGTERM", quit)
process.on("SIGHUP", quit)

refresh()
// 1 s tick: fresh ages; sweep drops agents that exited without a hook.
let sweeping = false
setInterval(() => {
  refresh()
  if (sweeping) return
  sweeping = true
  Bun.spawn([bin, "sweep"], { stdout: "ignore", stderr: "ignore" }).exited.finally(() => {
    sweeping = false
  })
}, 1000)
// Spinner animation: redraw only, no tmux calls.
setInterval(() => {
  if (!flash && !agents.some((a) => a.state === "working")) return
  frame++
  render()
}, 120)
