import {
	formatLocatorUri,
	HINT_ALT_LOCATORS,
	HINT_VIA,
	parseLocator,
	stringHint,
	TRANSPORT_ID,
} from "@pancake/runtime";
import { roomsIdentityRoute } from "../lib/routes.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

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
