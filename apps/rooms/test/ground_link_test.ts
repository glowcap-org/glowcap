// The threads under the page dim when every connection is lost for a while,
// and regrow when one comes back. The delay is the test's to run out, so
// nothing here waits on a clock.
/// <reference lib="dom" />
import { assertEquals } from "./assert.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { PageProjection } = await import("../web/ui/store/core.ts");
const { forgetDir, openDir, setDirSession } = await import("../web/ui/store/dirs.ts");
const { bindGroundToConnections } = await import("../web/ui/mycelium/link.ts");
const { dirId } = await import("../web/ui/types.ts");
const a = dirId("ocapn://a");
const b = dirId("ocapn://b");

/** A page whose dim delay elapses only on `elapse()`. */
function watched() {
	const projection = new PageProjection();
	// Records what reaches the mycelium, which ignores a repeated dim() and
	// a regrow() that follows no dim(), as the real one does.
	const calls: string[] = [];
	let dimmed = false;
	let pending: (() => void) | null = null;
	const stop = bindGroundToConnections(projection, {
		ground: {
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
		},
		delay: (fire) => {
			pending = fire;
			return () => void (pending = null);
		},
	});
	return {
		projection,
		calls,
		/** Whether a dim is waiting on the delay. */
		waiting: () => pending != null,
		/** Let the delay run out, firing whatever waits on it. */
		elapse() {
			const fire = pending;
			pending = null;
			fire?.();
		},
		done() {
			stop();
			projection.dispose();
		},
	};
}

Deno.test("a first dial that fails and then connects neither dims nor regrows", () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	setDirSession(page.projection, a, "disconnected");
	assertEquals(page.waiting(), false);
	setDirSession(page.projection, a, "connected");
	assertEquals(page.calls, []);
	page.done();
});

Deno.test("a blip that returns before the delay shows nothing", () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	setDirSession(page.projection, a, "connected");
	setDirSession(page.projection, a, "reconnecting");
	assertEquals(page.waiting(), true);
	setDirSession(page.projection, a, "connected");
	assertEquals(page.waiting(), false);
	page.elapse();
	assertEquals(page.calls, []);
	page.done();
});

Deno.test("a lost connection dims once the delay runs out, and its return regrows", () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	setDirSession(page.projection, a, "connected");
	setDirSession(page.projection, a, "reconnecting");
	setDirSession(page.projection, a, "disconnected");
	assertEquals(page.calls, []);
	page.elapse();
	assertEquals(page.calls, ["dim"]);
	setDirSession(page.projection, a, "connected");
	assertEquals(page.calls, ["dim", "regrow"]);
	page.done();
});

Deno.test("the threads dim only once every connection is lost", () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	openDir(page.projection, b, "ocapn://b");
	setDirSession(page.projection, a, "connected");
	setDirSession(page.projection, b, "connected");
	setDirSession(page.projection, a, "reconnecting");
	assertEquals(page.waiting(), false);
	setDirSession(page.projection, b, "reconnecting");
	page.elapse();
	assertEquals(page.calls, ["dim"]);
	setDirSession(page.projection, b, "connected");
	setDirSession(page.projection, a, "connected");
	assertEquals(page.calls, ["dim", "regrow"]);
	page.done();
});

Deno.test("forgetting the only lost directory is not a loss", () => {
	const page = watched();
	openDir(page.projection, a, "ocapn://a");
	setDirSession(page.projection, a, "connected");
	setDirSession(page.projection, a, "reconnecting");
	forgetDir(page.projection, a);
	assertEquals(page.waiting(), false);
	assertEquals(page.calls, []);
	page.done();
});
