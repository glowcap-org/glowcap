// The harness every rooms server test runs on.
//
// Each test gets a server of its own on a free port and a runtime scope that
// closes what it opened, because these tests bind real loopback sockets and a
// leaked one fails whichever test runs next rather than the one that leaked it.
// All scenarios start the installed Rust server; the build owns that prerequisite.

import type { Host, Runtime, Session } from "@glowcap/runtime";
import { Reachability } from "@glowcap/iroh";

import { dial as dialWithRuntime, isUriLocator, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { spawnOwned, stopOwned } from "./children.ts";
export const ROOT = new URL("../../../../", import.meta.url).pathname;
import { SERVER } from "./server_binary.ts";
export { SERVER };

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

// The native test server includes iroh. Probe one direct endpoint once per
// suite; failure is a failure, not an implicit skip of supported behavior.
export function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
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

/** Child servers that mean no durable state must not inherit a live
 * `GLOWCAP_ROOMS_STATE` from the pane that launched the suite.
 *
 * `spawnOwned` is the authority that actually hides the pane directory
 * (Deno overlays `env` unless `clearEnv` is set). This helper still names
 * that absence for callers who pass an explicit environment map. */
function ephemeralRoomsEnv(): Record<string, string> {
	const env = { ...Deno.env.toObject() };
	delete env.GLOWCAP_ROOMS_STATE;
	return env;
}

export async function withServer(fn: (port: number) => Promise<void>): Promise<void> {
	const proc = spawnOwned(SERVER, {
		args: ["--transport=tcp", "--port=0"],
		cwd: ROOT,
		env: ephemeralRoomsEnv(),
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await fn(await readPort(proc));
	} finally {
		await stopOwned(proc);
	}
}

export async function withPeeringServer(
	fn: (port: number, swiss: string) => Promise<void>,
): Promise<void> {
	const state = await Deno.makeTempDir();
	const proc = spawnOwned(SERVER, {
		args: ["--transport=tcp", "--port=0", "--peering"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), GLOWCAP_ROOMS_STATE: state },
		stdout: "piped",
		stderr: "piped",
	});
	try {
		const port = await readPort(proc);
		const swiss = (await Deno.readTextFile(`${state}/peering`)).trim();
		assert(swiss.length > 0, "the peering server did not persist its swiss");
		await fn(port, swiss);
	} finally {
		await stopOwned(proc);
		await Deno.remove(state, { recursive: true });
	}
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

/** Restart a stateful server on the port it held before. The number comes from
 * the caller's explicit allocation. The one collision seen in practice is our
 * own predecessor's teardown finishing; exactly the
 * "already in use" refusal retries on a short clock. Any other failure, and
 * exhaustion, stay loud. */
export async function restartStatefulServer(
	port: number,
	stateDirectory: string,
	serverArgs: readonly string[] = [],
): Promise<Deno.ChildProcess> {
	let last = "";
	for (let attempt = 0; attempt < 6; attempt++) {
		if (attempt > 0) await new Promise((settle) => setTimeout(settle, 150));
		const proc = startStatefulServer(port, stateDirectory, serverArgs);
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

export function startStatefulServer(
	port: number,
	stateDirectory: string,
	serverArgs: readonly string[] = [],
): Deno.ChildProcess {
	return spawnOwned(SERVER, {
		args: ["--transport=tcp", `--port=${port}`, ...serverArgs],
		cwd: ROOT,
		env: { GLOWCAP_ROOMS_STATE: stateDirectory },
		stdout: "piped",
		stderr: "piped",
	});
}

export function stopServer(proc: Deno.ChildProcess): Promise<void> {
	return stopOwned(proc);
}

/** Read the server's announce token: a TCP port or a dialable transport URI. */
export async function readAnnounce(proc: Deno.ChildProcess, withinMs = 10_000): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + withinMs;
	try {
		while (Date.now() < deadline) {
			const remaining = deadline - Date.now();
			const chunk = await within(reader.read(), "the room server announcement", remaining);
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

export {
	assertRoster,
	enterOrOpen,
	listRooms,
	nextMessage,
	recordDirectoryEvent,
	refusalCode,
	registerAndWatch,
	resubscribeAndHold,
	roomLines,
	subscribeMembership,
	subscribeOnce,
	subscribeOnceConn,
	subscribeOnceIroh,
	subscribeTwiceAndClose,
	trySubscribe,
	until,
	waitForLine,
	waitForMatch,
	waitForRoster,
	watchDirectory,
	watchRoom,
	watchRoomConn,
	watchRoomIroh,
} from "./subscribe.ts";
