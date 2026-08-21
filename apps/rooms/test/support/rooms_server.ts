// The harness every rooms server test runs on.
//
// Each test gets a server of its own on a free port and a runtime scope that
// closes what it opened, because these tests bind real loopback sockets and a
// leaked one fails whichever test runs next rather than the one that leaked it.
// The iroh arm probes whether this tree can actually run iroh before using it,
// and skips only for the loader's own refusal.

import type { Host, Runtime, Session } from "@pancake/runtime";
import { Reachability } from "@pancake/iroh";

import { dial as dialWithRuntime, isUriLocator, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { spawnOwned, stopOwned } from "./children.ts";
export const ROOT = new URL("../../../../", import.meta.url).pathname;
export const SERVER = new URL("../../server/main.ts", import.meta.url).pathname;
export const RACKET_CLIENT = new URL("../../clients/racket/client.rkt", import.meta.url).pathname;
export const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];
// iroh dials through the sidecar over nonblocking FFI, which needs broader
// permissions and --unstable-ffi; the server reads its own lib path.
export const IROH_FLAGS = ["run", "-A", "--unstable-ffi"];

export class TestRuntimeScope {
	readonly #byHost = new Map<Host, Promise<Runtime>>();
	readonly #runtimes = new Set<Runtime>();

	async dial(locator: string, host = roomsHost()): Promise<Session> {
		let pending = this.#byHost.get(host);
		if (pending === undefined) {
			pending = openRoomsRuntime({
				host,
				iroh: isUriLocator(locator) ? { reachability: Reachability.Direct } : undefined,
			});
			this.#byHost.set(host, pending);
		}
		const runtime = await pending;
		this.#runtimes.add(runtime);
		return await dialWithRuntime(locator, runtime);
	}

	async close(): Promise<void> {
		for (const runtime of [...this.#runtimes].reverse()) await runtime.close();
		this.#runtimes.clear();
		this.#byHost.clear();
	}
}

let activeRuntimeScope: TestRuntimeScope | null = null;

export function roomsTest(
	name: string,
	run: (context: Deno.TestContext) => void | Promise<void>,
): void {
	Deno.test(name, async (context) => {
		const scope = new TestRuntimeScope();
		activeRuntimeScope = scope;
		try {
			await run(context);
		} finally {
			activeRuntimeScope = null;
			await scope.close();
		}
	});
}

export function dial(locator: string, host?: Host): Promise<Session> {
	if (activeRuntimeScope === null) throw new Error("rooms test dial used outside a test scope");
	return activeRuntimeScope.dial(locator, host);
}

// The optional iroh ABI companion library (`zig build iroh-abi`, needs cargo).
// The iroh tests below skip when this tree cannot run it, matching the demo's
// join-when-available posture, so this suite stays green without cargo.
//
// The question is whether the library *loads*, not whether the file is there.
// Asking `statSync` answered the easier one and got it wrong in the ordinary
// case: `check` deliberately never rebuilds the cargo sidecar, so after any ABI
// change the file is present and stale, the probe said yes, and four tests then
// failed on a server that had already refused to start — the gate red for a
// reason it believed it tolerated.
//
// So the probe starts the thing the tests need and reads the answer, once for
// the suite. Only the loader's own "not built here" refusal counts as absent;
// a server that fails any other way is still a failure, because a skip that
// swallows a real iroh regression would be worse than the wrong question.
export const IROH_UNAVAILABLE = "iroh transport unavailable";

let irohProbe: Promise<boolean> | null = null;

export function irohUsable(): Promise<boolean> {
	irohProbe ??= probeIroh();
	return irohProbe;
}

export async function probeIroh(): Promise<boolean> {
	const proc = spawnOwned("deno", {
		args: [...IROH_FLAGS, SERVER, "0", "--transport=iroh"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	try {
		const announced = await readAnnounce(proc, 20_000).then(() => true).catch(() => false);
		if (announced) return true;
		// Not announced: read what it said. The loader's refusal names itself,
		// and that is the only sentence that means "this tree has no iroh".
		// A refusing server has already exited by now — that is how it refuses —
		// so ending it is only for the case where it hung instead, and asking a
		// process that is already gone to stop is not an error worth raising.
		try {
			proc.kill("SIGTERM");
		} catch {
			// already exited, which is the ordinary way this path is reached
		}
		const said = await new Response(proc.stderr).text().catch(() => "");
		if (said.includes(IROH_UNAVAILABLE)) return false;
		throw new Error(`the iroh room server would not start, and not for want of the library: ${said.trim()}`);
	} finally {
		await stopOwned(proc);
	}
}

export function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

export function assertMatch(value: string, pattern: RegExp): void {
	if (!pattern.test(value)) {
		throw new Error(`expected ${JSON.stringify(value)} to match ${pattern}`);
	}
}

export const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Wait for one thing with a deadline on it.
 *
 * A stream that never delivers what a test is waiting for is the ordinary shape
 * of a broken feature, and awaiting it plainly turns that into a hang: the run
 * sits there until something outside kills it, and reports nothing about what
 * was missing. This turns the same failure into a sentence. */
export async function within<T>(work: Promise<T>, what: string, ms = 10_000): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const expiry = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
	});
	try {
		return await Promise.race([work, expiry]);
	} finally {
		clearTimeout(timer);
	}
}

export async function onPath(cmd: string): Promise<boolean> {
	try {
		const out = await new Deno.Command(cmd, {
			args: ["--version"],
			stdout: "null",
			stderr: "null",
		}).output();
		return out.success;
	} catch {
		return false;
	}
}

export async function readPort(proc: Deno.ChildProcess): Promise<number> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	let exited = false;
	const deadline = Date.now() + 10_000;
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			const chunk = await Promise.race([
				reader.read(),
				delay(remaining).then(() => undefined),
			]);
			if (chunk === undefined) break;
			const { value, done } = chunk;
			if (done) {
				exited = true;
				break;
			}
			buf += decoder.decode(value, { stream: true });
			const match = buf.match(/ROOMS-SERVER-LISTENING (\d+)/);
			if (match) return Number(match[1]);
		}
	} finally {
		reader.releaseLock();
	}
	if (exited) {
		const status = await proc.status;
		const stderr = await new Response(proc.stderr).text();
		throw new Error(
			`rooms server exited ${status.code} before announcing its port${stderr === "" ? "" : `: ${stderr.trim()}`}`,
		);
	}
	throw new Error("rooms server never announced its port");
}

/** A port nothing holds right now. Asked with a socket that does not share an
 * address, which is the same question the server itself asks before binding. */
export function freeServerPort(): number {
	const probe = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const { port } = probe.addr as Deno.NetAddr;
	probe.close();
	return port;
}

export async function withServer(fn: (port: number) => Promise<void>): Promise<void> {
	const proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, SERVER, "0"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await fn(await readPort(proc));
	} finally {
		await stopOwned(proc);
	}
}

export async function withCapturedServer(fn: (port: number) => Promise<void>): Promise<string> {
	const proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, SERVER, "0"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	const stderr = new Response(proc.stderr).text();
	try {
		await fn(await readPort(proc));
	} finally {
		await stopOwned(proc);
	}
	return await stderr;
}

export function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}

/** Wait until serve.ts answers `/locator` on `port`, or throw. The web
 * server answers only once the room it supervises has announced, so this is
 * the one probe that means "serving and useful". */
export async function waitForHttp(port: number): Promise<void> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			await res.body?.cancel();
			if (res.status === 200) return;
		} catch {
			// not up / room not ready yet
		}
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	throw new Error("serve.ts did not answer with a room locator");
}

/** A port for a server that must keep its number across a restart, from below
 * the kernel's ephemeral range (32768 up on Linux). A learned bind-0 port is
 * ephemeral, and the build runs test steps in parallel, so between a stop and
 * a rebind any concurrent step's socket can legitimately land on it. Below the
 * range, only an explicit binder can collide, and nothing in this repository
 * binds these numbers deliberately. The probe-then-bind gap still exists, which
 * is what `restartStatefulServer`'s retry is for. */
export function stablePort(): number {
	for (let attempt = 0; attempt < 32; attempt++) {
		const candidate = 20000 + Math.floor(Math.random() * 10000);
		try {
			const probe = Deno.listen({ hostname: "127.0.0.1", port: candidate });
			probe.close();
			return candidate;
		} catch {
			continue;
		}
	}
	throw new Error("no stable port below the ephemeral range answered in 32 draws");
}

/** Restart a stateful server on the port it held before. The number comes from
 * `stablePort`, so only an explicit binder can be holding it, and the one seen
 * in practice is our own predecessor's teardown finishing; exactly the
 * "already in use" refusal retries on a short clock. Any other failure, and
 * exhaustion, stay loud. */
export async function restartStatefulServer(port: number, stateDirectory: string): Promise<Deno.ChildProcess> {
	let last = "";
	for (let attempt = 0; attempt < 6; attempt++) {
		if (attempt > 0) await new Promise((settle) => setTimeout(settle, 150));
		const proc = startStatefulServer(port, stateDirectory);
		try {
			await readPort(proc);
			return proc;
		} catch (refused) {
			// The attempt that failed still owns whatever it managed to bind, so it
			// goes before the next one rather than waiting for the end of the run.
			await stopOwned(proc);
			last = refused instanceof Error ? refused.message : String(refused);
			if (!last.includes("already in use")) throw refused;
		}
	}
	throw new Error(`rooms server could not rebind ${port} after retries: ${last}`);
}

export function startStatefulServer(port: number, stateDirectory: string): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [...DENO_FLAGS, `--allow-write=${stateDirectory}`, SERVER, String(port)],
		cwd: ROOT,
		env: { PANCAKE_ROOMS_STATE: stateDirectory },
		stdout: "piped",
		stderr: "piped",
	});
}

export function stopServer(proc: Deno.ChildProcess): Promise<void> {
	return stopOwned(proc);
}

/** Read the server's announce token (`ROOMS-SERVER-LISTENING <token>`), the iroh
 * ocapn:// URI a client dials. Like `readPort`, but the token is a URI, not a
 * port. */
export async function readAnnounce(proc: Deno.ChildProcess, withinMs = 10_000): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + withinMs;
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			const chunk = await Promise.race([
				reader.read(),
				delay(remaining).then(() => undefined),
			]);
			if (chunk === undefined) break;
			const { value, done } = chunk;
			if (done) break;
			buf += decoder.decode(value, { stream: true });
			const match = buf.match(/ROOMS-SERVER-LISTENING (\S+)/);
			if (match) return match[1];
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error("rooms server never announced its locator");
}

/** Run the rooms server over iroh and hand its dialable ocapn:// URI to `fn`. */
export async function withIrohServer(
	fn: (uri: string) => Promise<void>,
): Promise<void> {
	const proc = spawnOwned("deno", {
		args: [...IROH_FLAGS, SERVER, "--transport=iroh"],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await fn(await readAnnounce(proc));
	} finally {
		await stopOwned(proc);
	}
}

export {
	enterOrOpen,
	listRooms,
	nextMessage,
	refusalCode,
	registerAndWatch,
	resubscribeAndHold,
	roomLines,
	subscribeOnce,
	subscribeOnceConn,
	subscribeOnceIroh,
	subscribeTwiceAndClose,
	trySubscribe,
	until,
	waitForLine,
	waitForMatch,
	watchDirectory,
	watchRoom,
	watchRoomConn,
	watchRoomIroh,
} from "./subscribe.ts";
