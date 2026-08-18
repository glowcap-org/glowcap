// The viz capability: reaching the live timeline endpoint is not the
// authority to use it.
//
// The endpoint used to admit any socket that could reach its port, which made
// reachability both the authority to read the timeline and — the wider hole —
// the authority to write traces into it. Now the endpoint is minted with one
// swiss, presented by every socket as the `cap` query parameter, and a socket
// without it is closed with a typed refusal before it is anything: never a
// producer, never a viewer, nothing it sends parsed or forwarded.
//
// The server half is the mint: enabling the endpoint (`--viz`, or its env
// twin `PANCAKE_ROOMS_VIZ=1`) is what mints and persists the swiss, a server
// without it mints nothing, and a stale swiss left in state answers nothing
// anywhere.

import { constantTimeEquals, startViz, VIZ_REFUSED_REASON } from "../server/viz.ts";
import { VIZ_REFUSED_CLOSE_CODE, vizCapUrl } from "../lib/viz_publish.ts";
import { connectVizViewer, vizCapOf, vizPortOf } from "./viz_viewer.ts";
import {
	assert,
	DENO_FLAGS,
	dial,
	readPort,
	roomsTest,
	ROOT,
	SERVER,
	stopServer,
	within,
} from "./support/rooms_server.ts";

const CAP = "ab".repeat(32);

const openRecord = (session: string): string =>
	JSON.stringify({ v: 1, sim_t_ns: 1, kind: "ocapn.session-opened", session, a: "mallory", b: "room" });

function opened(socket: WebSocket): Promise<void> {
	return new Promise((resolve, reject) => {
		socket.onopen = () => resolve();
		socket.onerror = () => reject(new Error("socket would not open"));
	});
}

function closed(socket: WebSocket): Promise<{ code: number; reason: string }> {
	return new Promise((resolve) => {
		socket.onclose = (event) => resolve({ code: event.code, reason: event.reason });
	});
}

const settle = () => new Promise((r) => setTimeout(r, 60));

Deno.test("two secrets compare without an early exit", () => {
	assert(constantTimeEquals(CAP, CAP), "the same swiss did not compare equal");
	assert(!constantTimeEquals("", CAP), "an absent swiss compared equal");
	assert(!constantTimeEquals(CAP.slice(0, 63), CAP), "a truncated swiss compared equal");
	assert(!constantTimeEquals(CAP.slice(0, 63) + "c", CAP), "a one-character miss compared equal");
	assert(!constantTimeEquals(CAP + "ab", CAP), "an overlong swiss compared equal");
});

Deno.test("a write without the capability is refused before a single record lands", async () => {
	// The headline. Writing into the timeline used to need only reachability;
	// now a producer socket without the swiss is closed with the typed reason,
	// and the record it managed to send never reaches a viewer.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const seen: Record<string, unknown>[] = [];
		const viewer = await connectVizViewer(port, await viz.sturdyref, (record) => seen.push(record));
		const intruder = new WebSocket(`ws://127.0.0.1:${port}/publish`);
		const refusal = closed(intruder);
		await opened(intruder);
		intruder.send(openRecord("live-h1-s1"));
		const { code, reason } = await within(refusal, "the write refusal", 5_000);
		assert(code === VIZ_REFUSED_CLOSE_CODE, `the refusal closed with ${code}`);
		assert(reason === VIZ_REFUSED_REASON, `the refusal read "${reason}"`);
		await settle();
		assert(
			!seen.some((record) => record.kind === "ocapn.session-opened"),
			`an unadmitted write reached a viewer: ${JSON.stringify(seen)}`,
		);
		// With the swiss, the same write lands: the capability is the whole
		// difference.
		const producer = new WebSocket(vizCapUrl(`ws://127.0.0.1:${port}/publish`, CAP));
		await opened(producer);
		producer.send(openRecord("live-h1-s1"));
		await within(
			(async () => {
				while (!seen.some((record) => record.kind === "ocapn.session-opened")) await settle();
			})(),
			"the admitted write to reach the viewer",
			5_000,
		);
		producer.close();
		await viewer.close();
	} finally {
		viz.close();
	}
});

Deno.test("a viewer socket without the capability is refused the same way", async () => {
	// Reading is the same door: the socket is closed before any CapTP
	// establish, and a wrong swiss is exactly a missing one.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		for (const url of [`ws://127.0.0.1:${port}/`, vizCapUrl(`ws://127.0.0.1:${port}/`, "cd".repeat(32))]) {
			const socket = new WebSocket(url);
			const refusal = closed(socket);
			await opened(socket);
			const { code, reason } = await within(refusal, "the viewer refusal", 5_000);
			assert(code === VIZ_REFUSED_CLOSE_CODE, `the refusal closed with ${code}`);
			assert(reason === VIZ_REFUSED_REASON, `the refusal read "${reason}"`);
		}
	} finally {
		viz.close();
	}
});

Deno.test("an admitted producer hears the admission mark first", async () => {
	// The mark is what makes taking the capability a deterministic round trip
	// in a client instead of a grace timer: refusal closes, admission answers.
	const viz = startViz(0, CAP);
	const port = await viz.ready;
	try {
		const socket = new WebSocket(vizCapUrl(`ws://127.0.0.1:${port}/publish`, CAP));
		const mark = new Promise<Record<string, unknown>>((resolve) => {
			socket.onmessage = (msg) => resolve(JSON.parse(String(msg.data)));
		});
		await opened(socket);
		const heard = await within(mark, "the admission mark", 5_000);
		assert(heard.kind === "trace.publish-ready", `the first thing heard was ${JSON.stringify(heard)}`);
		socket.close();
	} finally {
		viz.close();
	}
});

// ── The mint, at the server ──────────────────────────────────────────────────

function spawnServer(stateDir: string, env: Record<string, string> = {}): Deno.ChildProcess {
	return new Deno.Command("deno", {
		args: [...DENO_FLAGS, `--allow-write=${stateDir}`, SERVER, "0"],
		cwd: ROOT,
		env: { ...Deno.env.toObject(), PANCAKE_ROOMS_STATE: stateDir, ...env },
		stdout: "piped",
		stderr: "piped",
	}).spawn();
}

/** Read stderr until `patterns` have each matched, teeing nothing. */
function scrapeStderr(stderr: ReadableStream<Uint8Array>, patterns: RegExp[]): Promise<string[]> {
	return (async () => {
		const decoder = new TextDecoder();
		let buffer = "";
		const found = new Array<string | null>(patterns.length).fill(null);
		for await (const chunk of stderr) {
			buffer += decoder.decode(chunk, { stream: true });
			patterns.forEach((pattern, i) => {
				if (found[i] === null) found[i] = buffer.match(pattern)?.[1] ?? null;
			});
			if (found.every((hit) => hit !== null)) return found as string[];
		}
		throw new Error(`the server ended before announcing; stderr was:\n${buffer}`);
	})();
}

roomsTest("viz off mints nothing, and a stale persisted swiss answers nothing", async () => {
	const stateDir = await Deno.makeTempDir();
	const stale = "ef".repeat(32);
	await Deno.writeTextFile(`${stateDir}/viz`, `${stale}\n`);
	const proc = spawnServer(stateDir);
	const stderr = new Response(proc.stderr).text();
	try {
		const port = await readPort(proc);
		// No flag, no endpoint, no publication: the stale swiss is debris, and
		// fetching it on the directory session answers a refusal, not an object.
		const session = await dial(`127.0.0.1:${port}`);
		let refused = false;
		try {
			await within(session.fetch(stale), "the stale fetch to settle", 10_000);
		} catch {
			refused = true;
		}
		assert(refused, "a stale viz swiss still answered on the directory session");
	} finally {
		await stopServer(proc);
	}
	assert(!(await stderr).includes("ROOMS-VIZ"), "a server without the flag still announced viz");
	// And a run that never held a viz file mints none: the file is written only
	// on the enabled path.
	const bare = await Deno.makeTempDir();
	const second = spawnServer(bare);
	try {
		await readPort(second);
		let minted = true;
		try {
			await Deno.stat(`${bare}/viz`);
		} catch {
			minted = false;
		}
		assert(!minted, "a server without the flag persisted a viz swiss");
	} finally {
		await stopServer(second);
	}
});

roomsTest("enabling the endpoint mints one persistent swiss the announcement carries", async () => {
	const stateDir = await Deno.makeTempDir();
	const proc = spawnServer(stateDir, { PANCAKE_ROOMS_VIZ: "1", PANCAKE_ROOMS_VIZ_PORT: "0" });
	const announced = scrapeStderr(proc.stderr, [
		/^ROOMS-VIZ ([0-9a-f]{64})$/m,
		/ROOMS-VIZ-LISTENING (\S+)/,
	]);
	try {
		await readPort(proc);
		const [token, sturdyref] = await within(announced, "the viz announcements", 15_000);
		const persisted = (await Deno.readTextFile(`${stateDir}/viz`)).trim();
		assert(persisted === token, "the ROOMS-VIZ token is not the persisted swiss");
		assert(vizCapOf(sturdyref) === token, "the sturdyref's swissnum is not the viz swiss");
		// The one swiss is the whole admission: a socket presenting it hears
		// the admission mark back.
		const socket = new WebSocket(vizCapUrl(`ws://127.0.0.1:${vizPortOf(sturdyref)}/publish`, token));
		const mark = new Promise<Record<string, unknown>>((resolve) => {
			socket.onmessage = (msg) => resolve(JSON.parse(String(msg.data)));
		});
		await opened(socket);
		const heard = await within(mark, "the admission mark", 5_000);
		assert(heard.kind === "trace.publish-ready", `the endpoint answered ${JSON.stringify(heard)}`);
		socket.close();
	} finally {
		await stopServer(proc);
	}
});
