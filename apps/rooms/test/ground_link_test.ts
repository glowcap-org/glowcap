// The threads under the page dim when every connection is lost for a while,
// and regrow when one comes back.
/// <reference lib="dom" />
import { assertEquals } from "./assert.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { PageProjection } = await import("../web/ui/store/core.ts");
const { forgetDir, openDir, setDirSession } = await import("../web/ui/store/dirs.ts");
const { bindGroundToConnections } = await import("../web/ui/ground_link.ts");
const { dirId } = await import("../web/ui/types.ts");
const a = dirId("ocapn://a");
const b = dirId("ocapn://b");
const GRACE_MS = 20;

const settle = () => new Promise((resolve) => setTimeout(resolve, GRACE_MS * 3));

function watched() {
	const projection = new PageProjection();
	// Records what reaches the mycelium, which ignores a repeated dim() and
	// a regrow() that follows no dim(), as the real one does.
	const calls: string[] = [];
	let dimmed = false;
	const stop = bindGroundToConnections(projection, {
		dim() {
			if (dimmed) return;
			dimmed = true;
			calls.push("dim");
		},
		regrow() {
			if (!dimmed) return;
			dimmed = false;
			calls.push("regrow");
		},
	}, GRACE_MS);
	return {
		projection,
		calls,
		done() {
			stop();
			projection.dispose();
		},
	};
}

Deno.test("a first dial that fails and then connects neither dims nor regrows", async () => {
	const { projection, calls, done } = watched();
	openDir(projection, a, "ocapn://a");
	setDirSession(projection, a, "disconnected");
	await settle();
	setDirSession(projection, a, "connected");
	await settle();
	assertEquals(calls, []);
	done();
});

Deno.test("a blip shorter than the grace shows nothing", async () => {
	const { projection, calls, done } = watched();
	openDir(projection, a, "ocapn://a");
	setDirSession(projection, a, "connected");
	setDirSession(projection, a, "reconnecting");
	setDirSession(projection, a, "connected");
	await settle();
	assertEquals(calls, []);
	done();
});

Deno.test("a lost connection dims, and its return regrows", async () => {
	const { projection, calls, done } = watched();
	openDir(projection, a, "ocapn://a");
	setDirSession(projection, a, "connected");
	setDirSession(projection, a, "reconnecting");
	setDirSession(projection, a, "disconnected");
	await settle();
	assertEquals(calls, ["dim"]);
	setDirSession(projection, a, "connected");
	assertEquals(calls, ["dim", "regrow"]);
	done();
});

Deno.test("the threads dim only once every connection is lost", async () => {
	const { projection, calls, done } = watched();
	openDir(projection, a, "ocapn://a");
	openDir(projection, b, "ocapn://b");
	setDirSession(projection, a, "connected");
	setDirSession(projection, b, "connected");
	setDirSession(projection, a, "reconnecting");
	await settle();
	assertEquals(calls, []);
	setDirSession(projection, b, "reconnecting");
	await settle();
	assertEquals(calls, ["dim"]);
	setDirSession(projection, b, "connected");
	setDirSession(projection, a, "connected");
	assertEquals(calls, ["dim", "regrow"]);
	done();
});

Deno.test("forgetting the only lost directory is not a loss", async () => {
	const { projection, calls, done } = watched();
	openDir(projection, a, "ocapn://a");
	setDirSession(projection, a, "connected");
	setDirSession(projection, a, "reconnecting");
	forgetDir(projection, a);
	await settle();
	assertEquals(calls, []);
	done();
});
