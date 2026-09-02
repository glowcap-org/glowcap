import { TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "@glowcap/abi";
import type { Host, Locator } from "@glowcap/runtime";
import routeCorpusJson from "../../../../test/net/fixtures/relay_routes.json" with { type: "json" };
import { connector } from "../transport.ts";
import { dialUrl, keyed, noise, routeFromLocator } from "../route.ts";
import { assert, rejects } from "../../dogfood/assert.ts";

const DESIGNATOR = "ab".repeat(32);

interface RouteCorpus {
	readonly designator: string;
	readonly accepted: readonly { readonly route: string; readonly request_target: string }[];
	readonly rejected: readonly string[];
}

const routeCorpus = routeCorpusJson as RouteCorpus;

Deno.test("managed relay connector advertises clear and Noise profiles", () => {
	const managed = connector();
	assert(managed.supports(TRANSPORT_KEYED_RELAY), "clear relay profile disappeared");
	assert(managed.supports(TRANSPORT_NOISE_RELAY), "Noise relay profile was not composed");
});

Deno.test("relay locators admit bounded WSS routes before any I/O", async () => {
	const route = "wss://relay.example.test/bridge?deployment=one";
	const clear = keyed.locator(DESIGNATOR, route);
	const sealed = noise.locator(DESIGNATOR, route);
	assert(clear.transport === TRANSPORT_KEYED_RELAY, "keyed locator changed profiles");
	assert(sealed.transport === TRANSPORT_NOISE_RELAY, "Noise locator changed profiles");
	assert(routeFromLocator(sealed) === route, "locator route changed during validation");
	assert(
		dialUrl(route, DESIGNATOR) ===
			`wss://relay.example.test/bridge?deployment=one&rendezvous=${DESIGNATOR}`,
		"dial route did not retain deployment query",
	);
	const byteSignificant = "wss://Relay.Example.test/bridge?second=%2f&first=one";
	assert(
		dialUrl(byteSignificant, DESIGNATOR) === `${byteSignificant}&rendezvous=${DESIGNATOR}`,
		"managed route reordered, normalized, or re-encoded admitted bytes",
	);

	let sockets = 0;
	const realWebSocket = globalThis.WebSocket;
	class CountingWebSocket {
		constructor(_url: string) {
			sockets++;
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = CountingWebSocket as unknown as typeof WebSocket;
		const invalid: Locator = {
			transport: TRANSPORT_NOISE_RELAY,
			designator: "not-a-key",
			hints: new Map([["rendezvous-relay", route]]),
			hintWireForm: "map",
		};
		await connector().connect({} as Host, invalid, { redeem: false, handshakeTimeoutMs: null })
			.then(() => {
				throw new Error("invalid designator opened a session");
			}, (error) => {
				assert(String(error).includes("64 lowercase hexadecimal"), "wrong designator refusal");
			});
		assert(sockets === 0, "invalid relay input opened a WebSocket");
	} finally {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("relay routing refuses ambiguous and unbounded inputs", () => {
	rejects(() => keyed.locator("AB".repeat(32), "wss://relay.example.test/"), "64 lowercase hexadecimal");
	rejects(() => noise.locator(DESIGNATOR, "https://relay.example.test/"), "must use ws or wss");
	rejects(
		() => noise.locator(DESIGNATOR, `wss://relay.example.test/${"x".repeat(4096)}`),
		"exceeds 4096 UTF-8 bytes",
	);
	rejects(
		() => dialUrl("wss://relay.example.test/?%69%64=somebody-else", DESIGNATOR),
		"reserves the id query parameter",
	);
	rejects(() => dialUrl("wss://relay.example.test/%", DESIGNATOR), "malformed percent encoding");
	rejects(
		() => dialUrl("wss://relay.example.test/?rendezvous=somebody-else", DESIGNATOR),
		"reserves the rendezvous query parameter",
	);
	rejects(() => dialUrl("wss://user:secret@relay.example.test/", DESIGNATOR), "credentials or a fragment");
});

Deno.test("managed relay routing matches the binding-neutral native corpus", () => {
	assert(routeCorpus.designator === DESIGNATOR, "route corpus designator drifted");
	for (const testCase of routeCorpus.accepted) {
		const expected = `${testCase.route}${testCase.route.includes("?") ? "&" : "?"}rendezvous=${DESIGNATOR}`;
		assert(dialUrl(testCase.route, DESIGNATOR) === expected, `route bytes changed: ${testCase.route}`);
	}
	for (const route of routeCorpus.rejected) {
		rejects(() => dialUrl(route, DESIGNATOR), "rendezvous-relay");
	}
});
