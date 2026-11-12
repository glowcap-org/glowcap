// A page whose server has moved to a new build reloads into it, asking only
// when it loses every connection it had or one comes back, and on the beat
// while it has none. The beat and the server's answers are the test's to
// drive, so nothing here waits on a clock.
/// <reference lib="dom" />
import "./support/match_media.ts";
import { assertEquals } from "./assert.ts";
const { PageProjection } = await import("../web/ui/store/projection.ts");
const { openDir, setDirSession } = await import("../web/ui/store/dirs.ts");
const { bindReloadToBuild, firstReloadFor, servedBuild } = await import("../web/ui/build_link.ts");

/** What the page reads from a `ui-version` answer labeled `type`. */
function buildNamed(type: string | null, body: string, status = 200): Promise<string | null> {
	const response = new Response(body, { status });
	// A string body is labeled text by default, so an unlabeled answer drops it.
	if (type == null) response.headers.delete("content-type");
	else response.headers.set("content-type", type);
	return servedBuild(response);
}
const { dirId } = await import("../web/ui/directory.ts");
const { pageStorage } = await import("../web/ui/page_storage.ts");
const a = dirId("ocapn://a");
const b = dirId("ocapn://b");

/** One macrotask turn, after which every settled answer has been read. */
const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

/** A page served as build `current`. Each question its server is asked waits
 * in `asked` until the test answers it, and the beat ticks only on `tick()`. */
function watched(current = "one") {
	const projection = new PageProjection();
	const asked: Array<(build: string | null) => void> = [];
	const reloads: string[] = [];
	let beating: (() => void) | null = null;
	const stop = bindReloadToBuild(projection, {
		current,
		served: () => new Promise((resolve) => asked.push(resolve)),
		reload: (build) => {
			reloads.push(build);
			return true;
		},
	}, (tick) => {
		beating = tick;
		return () => void (beating = null);
	});
	/** Answer the oldest open question, then let the page read it. */
	const answer = async (build: string | null) => {
		const question = asked.shift();
		if (question === undefined) throw new Error("No question is open to answer");
		question(build);
		await settled();
	};
	return {
		projection,
		asked,
		reloads,
		answer,
		beating: () => beating != null,
		tick: () => beating?.(),
		/** Open directory `a` and connect it. */
		connect() {
			openDir(projection, a, "ocapn://a");
			setDirSession(projection, a, "connected");
		},
		done() {
			stop();
			projection.dispose();
		},
	};
}

Deno.test("a page without directories never asks", () => {
	const page = watched();
	assertEquals(page.asked.length, 0);
	assertEquals(page.beating(), false);
	page.done();
});

Deno.test("a first connection that opens before the beat never asks", () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	assertEquals(page.asked.length, 0);
	assertEquals(page.beating(), true);
	setDirSession(page.projection, a, "connected");
	assertEquals(page.asked.length, 0);
	assertEquals(page.beating(), false);
	page.done();
});

Deno.test("a first connection that cannot open asks on the beat", async () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	page.tick();
	await page.answer(null);
	setDirSession(page.projection, a, "disconnected");
	assertEquals(page.asked.length, 0);
	page.tick();
	await page.answer("two");
	assertEquals(page.reloads, ["two"]);
	page.done();
});

Deno.test("a directory that never connects beside a live one neither asks nor beats", () => {
	const page = watched();
	page.connect();
	openDir(page.projection, b, "ocapn://b");
	setDirSession(page.projection, b, "disconnected");
	assertEquals(page.asked.length, 0);
	assertEquals(page.beating(), false);
	page.done();
});

Deno.test("the page asks only once every connection it had is lost", () => {
	const page = watched();
	page.connect();
	openDir(page.projection, b, "ocapn://b");
	setDirSession(page.projection, b, "connected");
	setDirSession(page.projection, a, "reconnecting");
	assertEquals(page.asked.length, 0);
	assertEquals(page.beating(), false);
	setDirSession(page.projection, b, "reconnecting");
	assertEquals(page.asked.length, 1);
	assertEquals(page.beating(), true);
	page.done();
});

Deno.test("a refused reload keeps watching for a later build", async () => {
	const projection = new PageProjection();
	const asked: Array<(build: string | null) => void> = [];
	const attempts: string[] = [];
	const stop = bindReloadToBuild(projection, {
		current: "one",
		served: () => new Promise((resolve) => asked.push(resolve)),
		reload(build) {
			attempts.push(build);
			return build !== "two";
		},
	}, () => () => {});
	try {
		openDir(projection, a, "ocapn://a");
		setDirSession(projection, a, "connected");
		setDirSession(projection, a, "reconnecting");
		for (const answer of asked.splice(0)) answer("two");
		await settled();
		assertEquals(attempts, ["two"]);
		setDirSession(projection, a, "connected");
		assertEquals(asked.length, 1);
		asked.shift()!("three");
		await settled();
		assertEquals(attempts.at(-1), "three");
	} finally {
		stop();
		projection.dispose();
	}
});

Deno.test("a lost connection asks on the drop and on every beat until it returns", async () => {
	const page = watched();
	page.connect();
	setDirSession(page.projection, a, "reconnecting");
	assertEquals(page.asked.length, 1);
	await page.answer(null);
	page.tick();
	await page.answer("one");
	setDirSession(page.projection, a, "connected");
	assertEquals(page.beating(), false);
	await page.answer("one");
	assertEquals(page.reloads, []);
	page.done();
});

Deno.test("a server that comes back on another build reloads the page once and ends the binding", async () => {
	const page = watched();
	page.connect();
	setDirSession(page.projection, a, "reconnecting");
	await page.answer("two");
	assertEquals(page.reloads, ["two"]);
	assertEquals(page.beating(), false);
	setDirSession(page.projection, a, "connected");
	setDirSession(page.projection, a, "reconnecting");
	assertEquals(page.asked.length, 0);
	page.done();
});

Deno.test("overlapping checks that both name another build reload once", async () => {
	const page = watched();
	page.connect();
	setDirSession(page.projection, a, "reconnecting");
	page.tick();
	assertEquals(page.asked.length, 2);
	await page.answer("two");
	await page.answer("two");
	assertEquals(page.reloads, ["two"]);
	page.done();
});

Deno.test("a tab reloads for one build once, so a server that contradicts itself cannot loop it", () => {
	const kept = new Map<string, string>();
	const storage = {
		getItem: (key: string) => kept.get(key) ?? null,
		setItem: (key: string, value: string) => void kept.set(key, value),
	};
	const area = pageStorage(() => ({ ...storage, removeItem: () => {}, key: () => null, length: 0 }));
	assertEquals(firstReloadFor("two", area), true);
	assertEquals(firstReloadFor("two", area), false);
	assertEquals(firstReloadFor("three", area), true);
});

Deno.test("a tab whose browser will not keep the reload target never reloads by itself", () => {
	const refusing = pageStorage(() => {
		throw new DOMException("The operation is insecure.", "SecurityError");
	});
	assertEquals(firstReloadFor("two", refusing), false);
	assertEquals(firstReloadFor("two", refusing), false, "and asking again does not loop it");
});

const BUILT = "source-0123456789ab";
const NEWER = "source-ba9876543210";
const PAGE = "<!doctype html><html><body>Rooms</body></html>";

Deno.test("only a build name under a build name's type names a build", async () => {
	assertEquals(await buildNamed("text/html; charset=utf-8", PAGE), null);
	assertEquals(await buildNamed("text/plain", PAGE), null);
	assertEquals(await buildNamed("text/plain", ""), null);
	assertEquals(await buildNamed("text/plain", "\n"), null);
	assertEquals(await buildNamed("text/html", `${NEWER}\n`), null);
	assertEquals(await buildNamed(null, NEWER), null);
	assertEquals(await buildNamed("text/plain", "source-0123456789AB"), null);
	assertEquals(await buildNamed("text/plain", `${NEWER}-dirty`), null);
	// `rooms-web` answers text, and a static host answers the exported file as bytes.
	assertEquals(await buildNamed("text/plain; charset=utf-8", `${NEWER}\n`), NEWER);
	assertEquals(await buildNamed("application/octet-stream", NEWER), NEWER);
	assertEquals(await buildNamed("text/plain", "0123456789ab-dirty"), "0123456789ab-dirty");
	assertEquals(await buildNamed("text/plain", "0123456789ab"), "0123456789ab");
	assertEquals(await buildNamed("text/plain", "0123456789ab", 404), null, "a refused answer names no build");
});

Deno.test("a host that answers ui-version with the page never reloads it, and another build does", async () => {
	const page = watched(BUILT);
	page.connect();
	setDirSession(page.projection, a, "reconnecting");
	await page.answer(await buildNamed("text/html; charset=utf-8", PAGE));
	page.tick();
	await page.answer(await buildNamed("text/plain", ""));
	page.tick();
	await page.answer(await buildNamed("text/html", NEWER));
	page.tick();
	await page.answer(await buildNamed("text/plain", BUILT));
	assertEquals(page.reloads, []);
	page.tick();
	await page.answer(await buildNamed("application/octet-stream", `${NEWER}\n`));
	assertEquals(page.reloads, [NEWER]);
	page.done();
});
