// Cross-language accountability demo: Zig host + Deno caller + Python caller.
//
// Starts the Zig host binary (accountability-host), reads the port it prints,
// then runs each available caller against a fresh host. Both exit 0 exactly when:
//   - The legitimate invocation resolved with an ack, and
//   - The tampered invocation was refused as a broken promise.
//
// Run it with `zig build demo-accountability`, which passes the built host
// binary's path as argv[0]. Run by hand, it falls back to the installed host
// under zig-out/bin. `--port=N` (from `-Dport`) pins the hosts' port instead of
// an ephemeral one; each caller still gets a fresh host, rebound on the same
// port. `--attach` is rejected: a host serves exactly one caller and exits, so
// there is no long-lived server to join.

const positional: string[] = [];
let pinPort = 0;
for (const a of Deno.args) {
  if (a === "--attach") {
    console.error("demo.ts: --attach is not supported here — each caller needs a fresh host (drop -Dattach)");
    Deno.exit(2);
  } else if (a.startsWith("--port=")) pinPort = Number(a.slice("--port=".length));
  else positional.push(a);
}
if (!Number.isInteger(pinPort) || pinPort < 0 || pinPort > 65535) {
  console.error("demo.ts: --port must be an integer in 1..65535");
  Deno.exit(2);
}

const ROOT = new URL("../../..", import.meta.url).pathname;
const HOST_BIN = positional[0] ?? `${ROOT}/zig-out/bin/accountability-host`;
const DENO_CALLER = new URL("./caller.ts", import.meta.url).pathname;
const PYTHON_CALLER = `${ROOT}/conformance/accountability-on-pancake/python/caller.py`;

async function readPort(proc: Deno.ChildProcess): Promise<number> {
  const reader = proc.stderr.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    const m = buf.match(/ACCOUNTABILITY-HOST-LISTENING (\d+)/);
    if (m) {
      reader.releaseLock();
      return Number(m[1]);
    }
  }
  reader.releaseLock();
  throw new Error("host never announced its port");
}

async function onPath(cmd: string): Promise<boolean> {
  try {
    await new Deno.Command(cmd, { args: ["--version"], stdout: "null", stderr: "null" }).output();
    return true;
  } catch {
    return false;
  }
}

interface CallerSpec {
  name: string;
  cmd: string;
  args: (port: number) => string[];
}

const callers: CallerSpec[] = [
  {
    name: "deno",
    cmd: "deno",
    args: (p) => ["run", "--allow-ffi", "--allow-read", "--allow-net", DENO_CALLER, String(p)],
  },
];

// Python is optional — skip with a note if not on PATH or pynacl missing.
if (await onPath("python3")) {
  const check = await new Deno.Command("python3", {
    args: ["-c", "import nacl.signing"],
    stdout: "null",
    stderr: "null",
  }).output();
  if (check.code === 0) {
    callers.push({
      name: "python",
      cmd: "python3",
      args: (p) => [PYTHON_CALLER, String(p)],
    });
  } else {
    console.log("  skipping python (pynacl not installed)");
  }
} else {
  console.log("  skipping python (python3 not on PATH)");
}

console.log(`accountability-on-pancake cross-seam demo: Zig host + ${callers.map((c) => c.name).join(" + ")} callers\n`);

let failed = false;
for (const caller of callers) {
  // Each caller gets its own fresh host so the session is clean.
  const host = new Deno.Command(HOST_BIN, {
    args: pinPort > 0 ? [`--port=${pinPort}`] : [],
    cwd: ROOT,
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  try {
    const port = await readPort(host);
    console.log(`──── ${caller.name} (host on 127.0.0.1:${port}) ────`);

    const result = await new Deno.Command(caller.cmd, {
      args: caller.args(port),
      cwd: ROOT,
      stdout: "inherit",
      stderr: "inherit",
    }).output();

    if (result.code !== 0) {
      console.error(`  ${caller.name} caller FAILED (exit ${result.code})`);
      failed = true;
    }
    console.log("");
  } finally {
    try { host.kill("SIGTERM"); } catch { /* already gone */ }
    await host.status;
  }
}

if (failed) {
  console.error("cross-seam demo FAILED");
  Deno.exit(1);
} else {
  const langs = callers.length + 1; // +1 for Zig host
  console.log(`cross-seam demo OK: ${langs} languages held one OCapN accountability conversation`);
}
