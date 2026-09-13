// ICE deployment parsing preserves defaults and validates bounded STUN and credentialed TURN entries.
import { WEBRTC_MAX_ICE_CREDENTIAL_BYTES, WEBRTC_MAX_ICE_SERVERS, WEBRTC_MAX_ICE_URL_BYTES } from "@glowcap/abi";
import { decodeIceServers, iceServersFrom } from "./support/ice.ts";
import { assertEquals } from "./assert.ts";

function throwsContaining(run: () => unknown, text: string): void {
	try {
		run();
	} catch (error) {
		if (String(error).includes(text)) return;
		throw error;
	}
	throw new Error(`expected refusal containing ${JSON.stringify(text)}`);
}

Deno.test("ICE deployment defaults, explicit none, and shorthand stay distinct", () => {
	assertEquals(
		iceServersFrom(undefined),
		[{ urls: "stun:stun.cloudflare.com:3478" }],
		"default STUN",
	);
	assertEquals(iceServersFrom(""), [], "explicitly no infrastructure");
	assertEquals(
		iceServersFrom(" stun:one.example:3478, stuns:two.example:5349 "),
		[{ urls: "stun:one.example:3478" }, { urls: "stuns:two.example:5349" }],
		"STUN shorthand",
	);
});

Deno.test("ICE deployment validates bounded STUN and credentialed TURN records", () => {
	throwsContaining(() => iceServersFrom("https://not-ice.example"), "must use stun:");
	throwsContaining(
		() => iceServersFrom("turn:turn.example:3478"),
		"needs both username and credential",
	);
	assertEquals(
		decodeIceServers([{
			urls: ["turn:turn.example:3478?transport=udp", "turns:turn.example:5349?transport=tcp"],
			username: "short-lived-user",
			credential: "short-lived-secret",
		}]),
		[{
			urls: ["turn:turn.example:3478?transport=udp", "turns:turn.example:5349?transport=tcp"],
			username: "short-lived-user",
			credential: "short-lived-secret",
		}],
		"credentialed TURN",
	);
	throwsContaining(
		() => decodeIceServers([{ urls: "stun:stun.example:3478", credential: "not-for-stun" }]),
		"do not take TURN credentials",
	);
	throwsContaining(
		() => decodeIceServers([{ urls: "turn:turn.example:3478", username: "missing-secret" }]),
		"credential is missing",
	);
	throwsContaining(
		() => decodeIceServers([{ urls: "turn:turn.example:3478", credential: "missing-user" }]),
		"username is missing",
	);
	throwsContaining(
		() => decodeIceServers([{ urls: "turn:turn.example:3478", username: "u", credential: "p", extra: true }]),
		"unknown ICE server field extra",
	);
	assertEquals(
		decodeIceServers(
			Array.from({ length: WEBRTC_MAX_ICE_SERVERS }, (_, index) => ({ urls: `stun:s${index}.example` })),
		)
			.length,
		WEBRTC_MAX_ICE_SERVERS,
		"maximum bounded server list",
	);
	throwsContaining(
		() =>
			decodeIceServers(
				Array.from({ length: WEBRTC_MAX_ICE_SERVERS + 1 }, (_, index) => ({ urls: `stun:s${index}.example` })),
			),
		`at most ${WEBRTC_MAX_ICE_SERVERS}`,
	);
	throwsContaining(() => decodeIceServers([{ urls: `stun:${"a".repeat(WEBRTC_MAX_ICE_URL_BYTES)}` }]), "too long");
	throwsContaining(
		() => decodeIceServers([{ urls: `stun:${"\u{00e9}".repeat(Math.floor(WEBRTC_MAX_ICE_URL_BYTES / 2) + 1)}` }]),
		"too long",
	);
	throwsContaining(
		() =>
			decodeIceServers([{
				urls: "turn:turn.example:3478",
				username: "u",
				credential: "\u{00e9}".repeat(Math.floor(WEBRTC_MAX_ICE_CREDENTIAL_BYTES / 2) + 1),
			}]),
		"credential is missing or too long",
	);
});

// Fetch retry, coalescing, credential refresh, invalid responses, and cancellation
// execute against Rust Source in proofs/src/browser_ice.rs and its real-browser
// HTTP fixtures (zig build rooms-rust-browser-host-test).
