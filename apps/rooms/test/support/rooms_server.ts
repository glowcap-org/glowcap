// The harness every rooms server test runs on.
//
// Each test gets a server of its own on a free port and a runtime scope that
// closes what it opened, because these tests bind real loopback sockets and a
// leaked one fails whichever test runs next rather than the one that leaked it.
// All scenarios start the installed Rust server. The build owns that prerequisite.

import type { Host, Runtime, Session } from "@glowcap/runtime";
import { Reachability } from "@glowcap/iroh";

import { dial as dialWithRuntime, isUriLocator, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { assert } from "../assert.ts";
import { readAnnounced, readAnnouncedPort } from "./announce.ts";
import { spawnOwned, stopOwned } from "./children.ts";
import { ROOT, SERVER } from "./paths.ts";
import { delay } from "./wait.ts";

export class TestRuntimeScope {
	readonly #byHost = new Map<Host, Promise<Runtime>>();
	readonly #runtimes = new Set<Runtime>();
	readonly #served: Promise<void>[] = [];
	readonly #faults: unknown[] = [];

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

	/** Run a session's inbound loop and make its outcome this test's.
	 *
	 * `serve()` resolves when the connection closes cleanly and rejects on a
	 * transport or protocol fault, so a loop nobody awaits is a wire fault
	 * nobody sees. The scope keeps every loop it started, latches a rejection
	 * the moment it happens, and raises it when the scope closes: the test
	 * that opened the session fails, named, rather than a later wait naming an
	 * unrelated selector. */
	serve(session: Session): Promise<void> {
		const served = session.serve().then(() => undefined, (error: unknown) => {
			this.#faults.push(error);
		});
		this.#served.push(served);
		return served;
	}

	async close(): Promise<void> {
		for (const runtime of [...this.#runtimes].reverse()) await runtime.close();
		this.#runtimes.clear();
		this.#byHost.clear();
		// Every loop ends with its runtime, so this waits on nothing that is
		// still running; what it collects is the faults latched along the way.
		await Promise.all(this.#served.splice(0));
		const faults = this.#faults.splice(0);
		if (faults.length > 0) throw faults[0];
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

/** Run `session`'s inbound loop under the active test scope, which raises any
 * wire fault the loop ends with when the test's scope closes. */
export function serving(session: Session): Promise<void> {
	if (activeRuntimeScope === null) throw new Error("rooms test serve used outside a test scope");
	return activeRuntimeScope.serve(session);
}

export function readPort(proc: Deno.ChildProcess): Promise<number> {
	return readAnnouncedPort(proc, { token: "ROOMS-SERVER-LISTENING", who: "rooms server" });
}

/** A server that means no durable state. `spawnOwned` keeps the pane's live
 * `GLOWCAP_ROOMS_STATE` away from it. */
export async function withServer(fn: (port: number) => Promise<void>): Promise<void> {
	const proc = spawnOwned(SERVER, {
		args: ["--transport=tcp", "--port=0"],
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

/** Wait until the Rooms front on `port` answers `/locator` with a locator, and
 * return it trimmed. The front answers only once the room it supervises has
 * announced, so this is the one probe that means "serving and useful". `who`
 * names the front in the sentence a timeout reports. */
export async function roomLocator(port: number, who = "rooms-web"): Promise<string> {
	for (let i = 0; i < 400; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/locator`);
			const said = (await res.text()).trim();
			if (res.status === 200 && said.length > 0) return said;
		} catch {
			// not up / room not ready yet status-allow: pending state or quoted runtime label
		}
		await delay(50);
	}
	throw new Error(`${who} did not answer with a room locator`);
}

/** Wait until `rooms-web` answers `/locator` on `port`, or throw. */
export async function waitForHttp(port: number): Promise<void> {
	await roomLocator(port);
}

/** Restart a stateful server on the port it held before. The number comes from
 * the caller's explicit allocation. The one collision seen in practice is our
 * own predecessor's teardown finishing. Exactly the
 * "already in use" refusal retries on a short clock. Any other failure, and
 * exhaustion, stay loud. */
export async function restartStatefulServer(
	port: number,
	stateDirectory: string,
	serverArgs: readonly string[] = [],
): Promise<Deno.ChildProcess> {
	let last = "";
	for (let attempt = 0; attempt < 6; attempt++) {
		if (attempt > 0) await delay(150);
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

/** Read the server's announce token: a TCP port or a dialable transport URI. */
export function readAnnounce(proc: Deno.ChildProcess, withinMs = 10_000): Promise<string> {
	return readAnnounced(proc, { token: "ROOMS-SERVER-LISTENING", who: "rooms server", withinMs });
}
