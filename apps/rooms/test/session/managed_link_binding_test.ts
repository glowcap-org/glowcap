// The page's foreground and network facts reach its link to the session: the
// browser's events reach the page, a return or a regained network wakes the
// link once, and a hidden or offline page waits.
import "../support/match_media.ts";
import { assertEquals } from "../assert.ts";
import { closed, FakeClock } from "../support/managed_link.ts";
import { settle } from "../support/wait.ts";
import { ManagedLink } from "../../web/ui/session/managed/link.ts";

const { RoomsPage } = await import("../../web/ui/page.ts");
const { bindLinkToPage } = await import("../../web/ui/session/managed/link_binding.ts");
const { bindNetwork, bindTabVisibility } = await import("../../web/ui/hooks.ts");

function bound() {
	const page = new RoomsPage();
	const clock = new FakeClock();
	let dials = 0;
	let probes = 0;
	let outcome: () => Promise<void> = () => Promise.reject(closed());
	const link = new ManagedLink({
		dial: (live) => {
			dials++;
			return outcome().then(live);
		},
		probe: () => {
			probes++;
			return Promise.resolve();
		},
		changed: () => {},
	}, clock);
	const stop = bindLinkToPage(page.projection, link);
	return {
		page,
		link,
		clock,
		stop,
		counts: () => [dials, probes],
		reachable: () => outcome = () => Promise.resolve(),
	};
}

Deno.test("a return to a live link probes it once, and a return to a lost one dials now", async () => {
	const { page, link, counts, stop } = bound();
	page.projection.noteVisibility(false);
	page.projection.noteVisibility(true);
	await settle();
	assertEquals(counts(), [0, 1]);
	page.projection.noteReturn();
	await settle();
	assertEquals(counts(), [0, 2], "a page restored from the back-forward cache is a return");
	link.lost(closed(), link);
	await settle();
	assertEquals([link.state.kind, counts()], ["waiting", [1, 2]]);
	page.projection.noteVisibility(false);
	page.projection.noteVisibility(true);
	assertEquals(counts()[0], 2, "one return is one dial");
	stop();
});

Deno.test("a device that loses its network waits for it, and dials as soon as it is back", async () => {
	const { page, link, clock, counts, reachable, stop } = bound();
	link.lost(closed(), link);
	await settle();
	page.projection.noteOnline(false);
	clock.advance(60_000);
	assertEquals([link.state.kind, counts()[0]], ["waiting", 1], "no dial while the device has no network");
	reachable();
	page.projection.noteOnline(true);
	await settle();
	assertEquals([link.live, counts()[0]], [true, 2]);
	stop();
});

/** Run `body` with a document whose hidden flag the test sets, and with the
 * device reporting `online`. Deno has neither, so both are put in place and
 * taken away again. */
function inBrowser(online: boolean, body: (document: EventTarget & { hidden: boolean }) => void) {
	const document = Object.assign(new EventTarget(), { hidden: false });
	Object.defineProperty(globalThis, "document", { value: document, configurable: true });
	Object.defineProperty(navigator, "onLine", { value: online, configurable: true });
	try {
		body(document);
	} finally {
		Reflect.deleteProperty(globalThis, "document");
		Reflect.deleteProperty(navigator, "onLine");
	}
}

Deno.test("a page shown from the back-forward cache counts as a return, and a first show does not", () => {
	inBrowser(true, (document) => {
		const page = new RoomsPage();
		const stop = bindTabVisibility(page.projection);
		const returns = () => page.projection.get().returns;
		const before = returns();
		dispatchEvent(Object.assign(new Event("pageshow"), { persisted: false }));
		assertEquals(returns(), before, "a first show is no return");
		dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }));
		assertEquals(returns(), before + 1, "a page restored from the cache returns");
		document.hidden = true;
		document.dispatchEvent(new Event("visibilitychange"));
		assertEquals(page.projection.get().visible, false);
		stop();
		dispatchEvent(Object.assign(new Event("pageshow"), { persisted: true }));
		assertEquals(returns(), before + 1, "a stopped binding hears nothing");
		page.projection.dispose();
	});
});

Deno.test("the device's network reports reach the page, starting from what it says now", () => {
	inBrowser(false, () => {
		const page = new RoomsPage();
		const stop = bindNetwork(page.projection);
		assertEquals(page.projection.get().online, false, "the first report is the device's own");
		dispatchEvent(new Event("online"));
		assertEquals(page.projection.get().online, true);
		dispatchEvent(new Event("offline"));
		assertEquals(page.projection.get().online, false);
		stop();
		dispatchEvent(new Event("online"));
		assertEquals(page.projection.get().online, false, "a stopped binding hears nothing");
		page.projection.dispose();
	});
});
