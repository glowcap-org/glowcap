// Route selection keeps authenticated identity evidence distinct from baseline reachability hints.
import {
	DURABLE_SWISS_ENTROPY_BYTES,
	formatLocatorUri,
	HINT_ALT_LOCATORS,
	HINT_VIA,
	parseLocator,
	stringHint,
	TRANSPORT_ID,
} from "@glowcap/runtime";
import { roomsIdentityDoors, roomsIdentityRoute } from "../lib/routes.ts";
import { BROWSER_OWN_DOORS, HINT_RENDEZVOUS_RELAY } from "../lib/doors.ts";
import { browserDoors } from "../web/ui/application.ts";
import { formatRoomsSturdyref, parseRoomsSturdyref } from "../lib/locator.ts";
import { assert } from "./assert.ts";

Deno.test("an identity route separates proving routes from baseline fallbacks", () => {
	const route = roomsIdentityRoute("node", [
		"ocapn://other.iroh",
		"ocapn://node.noise-tcp?direct-addresses=127.0.0.1:9000",
		"ocapn://node.iroh",
		"ocapn://node.tcp",
		"ocapn://node.noise-relay",
	]);
	assert(route !== null, "two matching keyed routes did not produce an identity route");
	assert(route.transport === TRANSPORT_ID, "the helper did not select the identity transport");
	assert(route.designator === "node", "the helper changed the identity designator");
	assert(
		stringHint(route, HINT_VIA) ===
			"ocapn://node.iroh|ocapn://node.noise-relay|ocapn://node.noise-tcp?direct-addresses=127.0.0.1%3A9000",
		"the helper did not filter or order the route list correctly",
	);
	assert(
		stringHint(route, HINT_ALT_LOCATORS) === "ocapn://node.tcp",
		"the baseline route was not kept as weak handoff advice",
	);
	assert(route.hintWireForm === "map", "the identity route did not use map hints");

	const reparsed = parseLocator(formatLocatorUri(route));
	assert(reparsed.transport === TRANSPORT_ID, "the identity route did not survive URI formatting");
	assert(stringHint(reparsed, HINT_VIA) === stringHint(route, HINT_VIA), "the via route list changed on round-trip");
	assert(
		stringHint(reparsed, HINT_ALT_LOCATORS) === stringHint(route, HINT_ALT_LOCATORS),
		"the weak fallback list changed on round-trip",
	);
});

Deno.test("an identity route opens back into its doors", () => {
	const route = roomsIdentityRoute("node", [
		"ocapn://node.noise-relay?rendezvous-relay=ws://relay/",
		"ocapn://127.0.0.1%3A9301.tcp",
	]);
	assert(route !== null, "two doors did not make a route");
	const doors = roomsIdentityDoors(route).map((door) => `${door.transport}:${door.designator}`);
	assert(doors.join(" ") === "noise-relay:node tcp:127.0.0.1:9301", `the doors were ${doors.join(" ")}`);
	const concrete = parseLocator("ocapn://127.0.0.1%3A9301.tcp");
	assert(roomsIdentityDoors(concrete)[0] === concrete, "a concrete locator is its own one door");
});

Deno.test("a browser with no Rooms server knows which doors it opens itself", () => {
	// A relay door is one the browser's dial admits: a 64-hex key and a relay URL.
	const key = "ab".repeat(32);
	const relayDoor = `ocapn://${key}.noise-relay?${HINT_RENDEZVOUS_RELAY}=ws://relay.example/relay`;
	const mixed = formatLocatorUri(roomsIdentityRoute(key, [relayDoor, "ocapn://127.0.0.1%3A9301.tcp"])!);
	const seen = browserDoors(mixed);
	assert(seen?.relay?.host === "relay.example", `the relay door was read as ${seen?.relay}`);
	assert(seen.throughServer, "the TCP door needs a Rooms server");
	// The page's words name the doors the browser opens itself from
	// `BROWSER_OWN_DOORS`, and the dial decides from the Rust application, so
	// every member of the set is one the dial opens with no server.
	for (const transport of BROWSER_OWN_DOORS) {
		const own = browserDoors(`ocapn://${key}.${transport}?${HINT_RENDEZVOUS_RELAY}=ws://relay.example/relay`);
		assert(own?.relay?.host === "relay.example" && !own.throughServer, `a ${transport} door alone needs no server`);
	}
	// The shorthand is one TCP door, a relay door the dial would refuse is no
	// door this browser opens, and text that is no address has no doors.
	const shorthand = browserDoors("127.0.0.1:9301");
	assert(shorthand?.relay === null && shorthand.throughServer, "the shorthand is one TCP door");
	assert(browserDoors(`ocapn://${key}.noise-relay`)?.relay === null, "a relay door with no relay cannot be opened");
	assert(
		browserDoors("ocapn://node.noise-relay?rendezvous-relay=ws://relay.example/")?.relay === null,
		"nor one with a bad key",
	);
	assert(browserDoors("") === null, "empty text is no address");
});

Deno.test("one proving route plus onion gives new peers identity and old peers reachability", () => {
	const route = roomsIdentityRoute("node", ["ocapn://node.iroh", "ocapn://room-service.onion"]);
	assert(route !== null, "the baseline fallback did not form an identity route");
	assert(stringHint(route, HINT_VIA) === "ocapn://node.iroh", "the proving route was not kept under via");
	assert(
		stringHint(route, HINT_ALT_LOCATORS) === "ocapn://room-service.onion",
		"the Goblins-compatible route was not kept as a weak fallback",
	);
});

Deno.test("an identity route is absent without both proof and added reachability", () => {
	assert(
		roomsIdentityRoute("node", ["ocapn://node.iroh"]) === null,
		"one matching route should remain a concrete locator",
	);
	assert(
		roomsIdentityRoute("node", ["ocapn://node.iroh", "ocapn://other.noise-relay"]) === null,
		"a route for another identity should not form a bundle",
	);
	assert(
		roomsIdentityRoute("node", ["ocapn://room-service.onion", "ocapn://node.tcp"]) === null,
		"weak routes without identity proof formed an id locator",
	);
});

Deno.test("a Rooms sturdyref is parsed from its canonical Swiss encoding", () => {
	const locator = parseLocator("ocapn://127.0.0.1%3A9000.tcp");
	const swiss = new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES).fill(0x5a);
	const sturdyref = formatRoomsSturdyref(locator, swiss);
	assert(
		parseRoomsSturdyref(sturdyref).swissnum.every((byte, index) => byte === swiss[index]),
		"the Rooms sturdyref did not preserve its canonical Swiss bytes",
	);
});
