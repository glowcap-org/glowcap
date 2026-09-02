// Attach dials the locator a tab-hosted session sturdyref names: WebRTC by
// default, noise-relay when DMs use the sealed relay.

import type { Locator, Session } from "@glowcap/runtime";
import { formatLocatorUri, TRANSPORT_NOISE_RELAY, TRANSPORT_WEBRTC } from "@glowcap/runtime";
import {
	dial,
	formatRoomsSturdyref,
	roomsAddress,
	roomsLocator,
	type RoomsRuntime,
	roomsSturdyrefLocator,
	WEBRTC_SIGNALING_DIRECTORY_HINT,
	webrtcSignalingDirectoryHint,
} from "../lib/locator.ts";
import { assertEquals } from "./assert.ts";

const DESIGNATOR = "aa".repeat(32);
const RELAY = "wss://relay.example/relay";

function runtime(onConnect: (locator: Locator) => void): RoomsRuntime {
	return {
		host: {} as RoomsRuntime["host"],
		connect: (locator) => {
			onConnect(locator);
			return Promise.resolve({} as Session);
		},
	};
}

Deno.test("Attach dials the WebRTC locator a tab-hosted session sturdyref names", async () => {
	const advertised = formatLocatorUri({
		transport: TRANSPORT_WEBRTC,
		designator: DESIGNATOR,
		hints: new Map(),
		hintWireForm: "map",
	});
	const sturdyref = formatRoomsSturdyref(roomsLocator(advertised), "session-grant");
	const dialed: Locator[] = [];
	await dial(roomsAddress(roomsSturdyrefLocator(sturdyref)), runtime((locator) => dialed.push(locator)));
	assertEquals(dialed[0]?.transport, TRANSPORT_WEBRTC);
	assertEquals(dialed[0]?.designator, DESIGNATOR);
});

Deno.test("Attach preserves the signaling-directory hint a tab-hosted sturdyref carries", () => {
	const directory = "ocapn://abcdefabcdef.iroh";
	const advertised = formatLocatorUri({
		transport: TRANSPORT_WEBRTC,
		designator: DESIGNATOR,
		hints: new Map([[WEBRTC_SIGNALING_DIRECTORY_HINT, directory]]),
		hintWireForm: "map",
	});
	const sturdyref = formatRoomsSturdyref(roomsLocator(advertised), "session-grant");
	assertEquals(webrtcSignalingDirectoryHint(roomsSturdyrefLocator(sturdyref)), directory);
});

Deno.test("Attach dials the noise-relay locator when that is the session door", async () => {
	const advertised = formatLocatorUri({
		transport: TRANSPORT_NOISE_RELAY,
		designator: DESIGNATOR,
		hints: new Map([["rendezvous-relay", RELAY]]),
		hintWireForm: "map",
	});
	const sturdyref = formatRoomsSturdyref(roomsLocator(advertised), "session-grant");
	const dialed: Locator[] = [];
	await dial(roomsAddress(roomsSturdyrefLocator(sturdyref)), runtime((locator) => dialed.push(locator)));
	assertEquals(dialed[0]?.transport, TRANSPORT_NOISE_RELAY);
	assertEquals(dialed[0]?.designator, DESIGNATOR);
	assertEquals(dialed[0]?.hints.get("rendezvous-relay"), RELAY);
});
