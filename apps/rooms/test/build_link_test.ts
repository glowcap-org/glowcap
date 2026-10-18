// A page whose server has moved to a new build reloads into it, asking only
// when it loses every connection it had or one comes back, and on the beat
// while it has none. The beat and the server's answers are the test's to
// drive, so nothing here waits on a clock.
/// <reference lib="dom" />
import { assertEquals } from "./assert.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { PageProjection } = await import("../web/ui/store/core.ts");
const { openDir, setDirSession } = await import("../web/ui/store/dirs.ts");
const { bindReloadToBuild, firstReloadFor } = await import("../web/ui/build_link.ts");
const { dirId } = await import("../web/ui/types.ts");
const a = dirId("ocapn://a");
const b = dirId("ocapn://b");

/** One macrotask turn, after which every settled answer has been read. */
const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

/** A page served as build `one`. Each question its server is asked waits in
 * `asked` until the test answers it, and the beat ticks only on `tick()`. */
function watched() {
	const projection = new PageProjection();
	const asked: Array<(build: string | null) => void> = [];
	const reloads: string[] = [];
	let beating: (() => void) | null = null;
	const stop = bindReloadToBuild(projection, {
		current: "one",
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
	assertEquals(firstReloadFor("two", () => storage), true);
	assertEquals(firstReloadFor("two", () => storage), false);
	assertEquals(firstReloadFor("three", () => storage), true);
	const refusing = {
		getItem: (): string | null => {
			throw new Error("denied");
		},
		setItem: () => {
			throw new Error("denied");
		},
	};
	assertEquals(firstReloadFor("two", () => refusing), true);
	assertEquals(
		firstReloadFor("two", () => {
			throw new Error("denied");
		}),
		true,
	);
});
