// The page's foreground and network facts reach its link to the session: a
// return or a regained network wakes it once, and a hidden or offline page
// waits.
import "../support/match_media.ts";
import { assertEquals } from "../assert.ts";
import { closed, FakeClock, settle } from "../support/managed_link.ts";
import { ManagedLink } from "../../web/ui/session/managed/link.ts";

const { RoomsPage } = await import("../../web/ui/page.ts");
const { bindLinkToPage } = await import("../../web/ui/link_binding.ts");

function bound() {
	const page = new RoomsPage();
	const clock = new FakeClock();
	let dials = 0;
	let probes = 0;
	let outcome: () => Promise<void> = () => Promise.reject(closed());
	const link = new ManagedLink({
		dial: () => {
			dials++;
			return outcome();
		},
		probe: () => {
			probes++;
			return Promise.resolve();
		},
		changed: () => {},
		report: () => {},
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
	link.lost(closed());
	await settle();
	assertEquals([link.state.kind, counts()], ["waiting", [1, 2]]);
	page.projection.noteVisibility(false);
	page.projection.noteVisibility(true);
	assertEquals(counts()[0], 2, "one return is one dial");
	stop();
});

Deno.test("a device that loses its network waits for it, and dials as soon as it is back", async () => {
	const { page, link, clock, counts, reachable, stop } = bound();
	link.lost(closed());
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
