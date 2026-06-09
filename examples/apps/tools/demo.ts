// Cross-language tools showcase orchestrator.
//
// Starts the Deno tools coordinator, then runs one agent per available language
// — Deno always, plus Python when python3 is on PATH — against it. Each agent
// proves the capability trio (delegation, attenuation, revocation) over OCapN/TCP.
// The coordinator and the agent are different languages on the wire, so the
// capability passing, attenuation, and revocation are real, not in-process.
//
// Run by `zig build tools`, which passes the built Zig agent's path as argv[0].

const ZIG_AGENT = Deno.args[0];
if (!ZIG_AGENT) {
  console.error("demo.ts: missing the Zig agent path (run via `zig build tools`)");
  Deno.exit(2);
}

const ROOT = Deno.cwd();
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

interface Agent {
  name: string;
  cmd: string;
  argv: (port: number) => string[];
}

async function onPath(cmd: string): Promise<boolean> {
  try {
    await new Deno.Command(cmd, { args: ["--version"], stdout: "null", stderr: "null" }).output();
    return true;
  } catch {
    return false;
  }
}

async function buildRust(): Promise<boolean> {
  console.log("tools demo: building the Rust agent (cargo build)…");
  const built = await new Deno.Command("cargo", {
    args: ["build", "--manifest-path", `${ROOT}/examples/apps/tools/rust/Cargo.toml`],
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
  }).output();
  if (!built.success) console.log("tools demo: skipping Rust — cargo build failed");
  return built.success;
}

async function roster(): Promise<{ agents: Agent[]; skipped: string[] }> {
  const agents: Agent[] = [
    {
      name: "deno",
      cmd: "deno",
      argv: (p) => [...DENO_FLAGS, `${ROOT}/examples/apps/tools/deno/agent.ts`, "127.0.0.1", String(p), "deno-agent"],
    },
    {
      name: "zig",
      cmd: ZIG_AGENT,
      argv: (p) => [String(p), "zig-agent"],
    },
  ];
  const skipped: string[] = [];

  if (await onPath("python3")) {
    agents.push({
      name: "python",
      cmd: "python3",
      argv: (p) => [`${ROOT}/examples/apps/tools/python/agent.py`, "127.0.0.1", String(p), "py-agent"],
    });
  } else skipped.push("python (no python3 on PATH)");

  if (await onPath("racket")) {
    agents.push({
      name: "racket",
      cmd: "racket",
      argv: (p) => [`${ROOT}/examples/apps/tools/racket/agent.rkt`, "127.0.0.1", String(p), "rkt-agent"],
    });
  } else skipped.push("racket (no racket on PATH)");

  if (await onPath("cargo") && await buildRust()) {
    agents.push({
      name: "rust",
      cmd: `${ROOT}/examples/apps/tools/rust/target/debug/tools-agent`,
      argv: (p) => ["127.0.0.1", String(p), "rs-agent"],
    });
  } else if (!(await onPath("cargo"))) skipped.push("rust (no cargo on PATH)");

  return { agents, skipped };
}

async function readPort(server: Deno.ChildProcess): Promise<number> {
  const reader = server.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value);
    const m = buf.match(/TOOLS-SERVER-LISTENING (\d+)/);
    if (m) {
      reader.releaseLock();
      return Number(m[1]);
    }
  }
  reader.releaseLock();
  throw new Error("coordinator never announced its port");
}

async function runAgent(a: Agent, port: number) {
  const out = await new Deno.Command(a.cmd, {
    args: a.argv(port),
    stdout: "piped",
    stderr: "piped",
    cwd: ROOT,
  }).output();
  const text = new TextDecoder().decode(out.stdout) + new TextDecoder().decode(out.stderr);
  return { name: a.name, code: out.code, out: text };
}

const { agents, skipped } = await roster();
for (const s of skipped) console.log(`tools demo: skipping ${s}`);

const server = new Deno.Command("deno", {
  args: [...DENO_FLAGS, `${ROOT}/examples/apps/tools/deno/server.ts`, "0"],
  stdout: "piped",
  stderr: "inherit",
  cwd: ROOT,
}).spawn();

let failed = false;
try {
  const port = await readPort(server);
  console.log(`tools demo: coordinator on 127.0.0.1:${port}; running ${agents.length} agent(s) (${agents.map((a) => a.name).join(", ")})\n`);

  for (const a of agents) {
    const r = await runAgent(a, port);
    console.log(`──────── ${r.name} (exit ${r.code}) ────────`);
    console.log(r.out.trimEnd());
    console.log("");
    if (r.code !== 0) failed = true;
  }

  if (failed) {
    console.error("tools demo FAILED: an agent did not prove the capability properties");
  } else {
    const langs = agents.length === 1 ? "1 language" : `${agents.length} languages`;
    console.log(`tools demo OK: ${langs} proved delegation, attenuation, and revocation over OCapN`);
    if (skipped.length > 0) console.log(`(skipped: ${skipped.join("; ")})`);
  }
} finally {
  try {
    server.kill("SIGTERM");
  } catch { /* already gone */ }
  await server.status;
}

Deno.exit(failed ? 1 : 0);
