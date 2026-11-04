// Runs tests/install.sh (installer tests on a private tmux server, throwaway
// HOMEs) under sh, and under dash when available (Debian/Kali's /bin/sh).
// Run from the repo root: bun test

import { expect, test } from "bun:test"

const shells = ["sh", "dash"].filter((s) => Bun.spawnSync(["sh", "-c", `command -v ${s}`]).exitCode === 0)

for (const shell of shells) {
  test(`install.sh under ${shell}`, () => {
    const r = Bun.spawnSync(["sh", `${import.meta.dir}/install.sh`, shell], { stderr: "pipe" })
    const out = r.stdout.toString() + r.stderr.toString()
    if (r.exitCode !== 0) console.log(out)
    expect(out).toContain(`[${shell}] passed`)
    expect(r.exitCode).toBe(0)
  }, 120_000)
}
