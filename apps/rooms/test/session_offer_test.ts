// Shared-session offers consume only their capability fragment and preserve the route.
import { assertEquals } from "./assert.ts";
import printedLinks from "./web/page_links.json" with { type: "json" };
import { sessionOffer, withSessionOffer } from "../web/ui/session_offer.ts";

Deno.test("a link's session offer leaves the address and never takes a room route", () => {
	// The link the Rooms server prints for a listed page with a shared session,
	// from the fixture its web.rs test prints from.
	const offer = sessionOffer(new URL(printedLinks.sessionLink));
	assertEquals(offer?.capability, printedLinks.session);
	assertEquals(offer?.rest.href, printedLinks.pageLink);
	assertEquals(sessionOffer(new URL("https://glowcap.org/rooms/app/#garden")), null);
	assertEquals(sessionOffer(new URL("https://glowcap.org/rooms/app/#room/attach=x")), null);
	// A link carried across a reload reads back whole.
	const carried = withSessionOffer(new URL("https://glowcap.org/rooms/app/#garden"), "ocapn://abc.iroh/s/x?y=1&z");
	assertEquals(sessionOffer(carried)?.capability, "ocapn://abc.iroh/s/x?y=1&z");
	assertEquals(sessionOffer(carried)?.rest.href, "https://glowcap.org/rooms/app/#garden");
});

Deno.test("a session offer preserves a join destination in either fragment order", () => {
	const join = new URL(
		"https://glowcap.org/rooms/app/join#room=workshop&address=ocapn%3A%2F%2Froom.iroh%2Fs%2Fsecret",
	);
	const offered = withSessionOffer(join, "ocapn://session.iroh/s/attach?x=1&y=2");
	assertEquals(offered.pathname + offered.search, "/rooms/app/join");
	assertEquals(sessionOffer(offered)?.rest.href, join.href);
	assertEquals(sessionOffer(offered)?.capability, "ocapn://session.iroh/s/attach?x=1&y=2");
	const reordered = new URL(join);
	reordered.hash = `attach=other&${join.hash.slice(1)}`;
	assertEquals(sessionOffer(reordered)?.rest.href, join.href);
	assertEquals(sessionOffer(join), null);
});
