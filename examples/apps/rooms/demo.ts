// Cross-language rooms demo orchestrator.
//
// Starts the Deno rooms server, then joins one client per available language —
// Deno and the native Zig client always, plus Python, Racket, and Rust when their
// runtimes are on PATH — into one capability-secure chat room over TCP. Each
// client subscribes, waits for the room to fill, posts one line, and must receive
// every member's line back through the capability callback. The orchestrator
// asserts every participating client exits 0, so `zig build rooms` is an honest
// proof that one OCapN room holds members written in several languages at once.
//
// It does not require every runtime: a language whose runtime is missing is
// skipped with a note, not treated as a failure, so the demo runs on whatever
// machine you have. Deno is the floor — it hosts the room and runs this script.
//
// Run by `zig build rooms`, which passes the built Zig client's path as argv[0].

const ZIG_CLIENT = Deno.args[0];
if (!ZIG_CLIENT) {
  console.error("demo.ts: missing the Zig client path (run via `zig build rooms`)");
  Deno.exit(2);
}

const ROOT = Deno.cwd();
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

interface Member {
  name: string;
  cmd: string;
  /** The client's args, once we know the port and how many members to expect. */
  argv: (port: number, expect: number) => string[];
}

/** True if `cmd` can be spawned at all — the cross-platform way to ask "is this
 * runtime on PATH?" without a shell. */
async function onPath(cmd: string): Promise<boolean> {
  try {
    await new Deno.Command(cmd, { args: ["--version"], stdout: "null", stderr: "null" }).output();
    return true;
  } catch {
    return false; // spawn failed: not installed / not on PATH
  }
}

/** Build the Rust client crate. Returns false (with a note) if the build fails so
 * the demo can carry on without it. */
async function buildRust(): Promise<boolean> {
  console.log("rooms demo: building the Rust client (cargo build)…");
  const built = await new Deno.Command("cargo", {
    args: ["build", "--manifest-path", `${ROOT}/examples/apps/rooms/rust/Cargo.toml`],
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
  }).output();
  if (!built.success) console.log("rooms demo: skipping Rust — cargo build failed");
  return built.success;
}

/** Decide who plays. Deno and Zig always; the others only when present. */
async function roster(): Promise<{ members: Member[]; skipped: string[] }> {
  const members: Member[] = [
    { name: "deno", cmd: "deno", argv: (p, e) => [...DENO_FLAGS, `${ROOT}/examples/apps/rooms/deno/client.ts`, "127.0.0.1", String(p), "deno-ada", "hello from deno", String(e)] },
    { name: "zig", cmd: ZIG_CLIENT, argv: (p, e) => [String(p), "zig-andrew", "hello from zig", String(e)] },
  ];
  const skipped: string[] = [];

  if (await onPath("python3")) {
    members.push({ name: "python", cmd: "python3", argv: (p, e) => [`${ROOT}/examples/apps/rooms/python/client.py`, "127.0.0.1", String(p), "py-grace", "hello from python", String(e)] });
  } else skipped.push("python (no python3 on PATH)");

  if (await onPath("racket")) {
    members.push({ name: "racket", cmd: "racket", argv: (p, e) => [`${ROOT}/examples/apps/rooms/racket/client.rkt`, "127.0.0.1", String(p), "rkt-alan", "hello from racket", String(e)] });
  } else skipped.push("racket (no racket on PATH)");

  if (await onPath("cargo") && await buildRust()) {
    members.push({ name: "rust", cmd: `${ROOT}/examples/apps/rooms/rust/target/debug/rooms-client`, argv: (p, e) => ["127.0.0.1", String(p), "rs-linus", "hello from rust", String(e)] });
  } else if (!(await onPath("cargo"))) skipped.push("rust (no cargo on PATH)");

  return { members, skipped };
}

/** Wait for the server's first line: "ROOMS-SERVER-LISTENING <port>". */
async function readPort(server: Deno.ChildProcess): Promise<number> {
  const reader = server.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value);
    const m = buf.match(/ROOMS-SERVER-LISTENING (\d+)/);
    if (m) {
      reader.releaseLock();
      return Number(m[1]);
    }
  }
  reader.releaseLock();
  throw new Error("server never announced its port");
}

async function runMember(m: Member, port: number, expect: number) {
  const out = await new Deno.Command(m.cmd, {
    args: m.argv(port, expect),
    stdout: "piped",
    stderr: "piped",
    cwd: ROOT,
  }).output();
  const text = new TextDecoder().decode(out.stdout) + new TextDecoder().decode(out.stderr);
  return { name: m.name, code: out.code, out: text };
}

const { members, skipped } = await roster();
for (const s of skipped) console.log(`rooms demo: skipping ${s}`);

const server = new Deno.Command("deno", {
  args: [...DENO_FLAGS, `${ROOT}/examples/apps/rooms/deno/server.ts`, "0"],
  stdout: "piped",
  stderr: "inherit",
  cwd: ROOT,
}).spawn();

let failed = false;
try {
  const port = await readPort(server);
  const expect = members.length;
  console.log(`rooms demo: server on 127.0.0.1:${port}; joining ${expect} members (${members.map((m) => m.name).join(", ")})\n`);

  const results = await Promise.all(members.map((m) => runMember(m, port, expect)));
  for (const r of results) {
    console.log(`──────── ${r.name} (exit ${r.code}) ────────`);
    console.log(r.out.trimEnd());
    console.log("");
    if (r.code !== 0) failed = true;
  }

  if (failed) {
    console.error("rooms demo FAILED: at least one client did not complete the all-to-all broadcast");
  } else {
    const langs = members.length === 1 ? "1 language" : `${members.length} languages`;
    console.log(`rooms demo OK: ${langs} held one capability-secure room and every member saw every message`);
    if (skipped.length > 0) console.log(`(skipped: ${skipped.join("; ")})`);
  }
} finally {
  try {
    server.kill("SIGTERM");
  } catch { /* already gone */ }
  await server.status;
}

Deno.exit(failed ? 1 : 0);
