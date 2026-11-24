// A new link's handles go in place in one turn, and the link is live from that
// turn: a call over them charges its loss to the new link, and an answer the
// page cannot accept leaves every old handle in place.
import { assertEquals } from "../assert.ts";
import { settle } from "../support/wait.ts";
import { snapshot } from "../support/managed_viewer.ts";
import { attached, backedOff, linkedWorkspace } from "../support/managed_link.ts";

Deno.test("a call the new link's install starts charges its loss to the new link", async () => {
	const second = linkedWorkspace("second", []);
	const third = linkedWorkspace("third", []);
	// The new link breaks before its first read, which the install itself starts.
	second.lose();
	const { session, first, clock, dials } = await attached([second, third]);
	first.lose();
	await settle();
	await backedOff(session, clock);
	await settle();
	assertEquals(
		[dials.length, session.link?.live, third.state.observations],
		[2, true, 1],
		"the new link's loss dials again",
	);
	await session.close();
});

Deno.test("a new link whose snapshot the page cannot accept leaves the old handles in place", async () => {
	const second = linkedWorkspace("second", [], {
		snapshot: () => Promise.resolve({ ...snapshot(), revision: "not a revision" }),
	});
	const { session, first } = await attached([second]);
	const shown = session.current;
	first.lose();
	await settle();
	assertEquals(session.link?.state.kind, "refused", "a failure inside the page waits for a person");
	assertEquals([first.state.freed, session.current === shown], [0, true], "the old link's handles stay");
	assertEquals(
		[second.state.retired, second.state.freed, second.state.observationFreed],
		[1, 1, 1],
		"what the dial opened is closed",
	);
	await session.close();
});
