import { WEBRTC_MAX_ICE_CREDENTIAL_BYTES, WEBRTC_MAX_ICE_SERVERS, WEBRTC_MAX_ICE_URL_BYTES } from "@pancake/abi";
import { decodeIceServers, iceServersFrom } from "../lib/ice.ts";
import { icePolicy } from "../web/ice_policy.ts";
import { iceServerSource } from "../web/ui/net/ice.ts";
import { assertEquals } from "./assert.ts";

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	throw new Error("expected promise to reject");
}

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

Deno.test("TURN policy keeps its bearer secret server-side and publishes only issued TURN rows", async () => {
	let requestUrl = "";
	let requestInit: RequestInit | undefined;
	const policy = icePolicy({
		stunServers: "stun:deployment.example:3478",
		turnCredentialsUrl: "https://issuer.example/credentials/generate-ice-servers",
		turnBearerToken: "issuer-secret",
		turnTtlSeconds: "3600",
	}, (input, init) => {
		requestUrl = String(input);
		requestInit = init;
		return Promise.resolve(Response.json({
			iceServers: [
				{ urls: ["stun:issuer.example:3478"] },
				{
					urls: [
						"stun:issuer.example:3478",
						"turn:relay.example:3478?transport=udp",
						"turns:relay.example:5349?transport=tcp",
					],
					username: "temporary-user",
					credential: "temporary-password",
				},
			],
		}));
	});

	assertEquals(await policy.servers(), [
		{ urls: "stun:deployment.example:3478" },
		{
			urls: ["turn:relay.example:3478?transport=udp", "turns:relay.example:5349?transport=tcp"],
			username: "temporary-user",
			credential: "temporary-password",
		},
	], "deployment STUN plus issued TURN only");
	assertEquals(requestUrl, "https://issuer.example/credentials/generate-ice-servers");
	assertEquals(requestInit?.method, "POST");
	assertEquals(new Headers(requestInit?.headers).get("authorization"), "Bearer issuer-secret");
	assertEquals(JSON.parse(String(requestInit?.body)), { ttl: 3600 });
});

Deno.test("TURN policy refuses incomplete, unsafe, or unusable issuer configuration", async () => {
	throwsContaining(
		() => icePolicy({ turnCredentialsUrl: "https://issuer.example/credentials" }),
		"must be set together",
	);
	throwsContaining(
		() => icePolicy({ turnCredentialsUrl: "http://issuer.example/credentials", turnBearerToken: "secret" }),
		"must use https:",
	);
	throwsContaining(
		() =>
			icePolicy({
				turnCredentialsUrl: "https://issuer.example/credentials",
				turnBearerToken: "secret",
				turnTtlSeconds: "49",
			}),
		"must be 300-172800",
	);

	const refused = icePolicy({
		turnCredentialsUrl: "https://issuer.example/credentials",
		turnBearerToken: "must-not-leak",
	}, () => Promise.resolve(new Response(null, { status: 503 })));
	const refusedError = String(await rejectionOf(refused.servers()));
	if (!refusedError.includes("issuer refused (503)")) throw new Error(refusedError);
	if (refusedError.includes("must-not-leak")) throw new Error("issuer bearer token leaked in error");

	const stunOnly = icePolicy({
		turnCredentialsUrl: "https://issuer.example/credentials",
		turnBearerToken: "secret",
	}, () => Promise.resolve(Response.json({ iceServers: [{ urls: "stun:issuer.example:3478" }] })));
	const noTurn = String(await rejectionOf(stunOnly.servers()));
	if (!noTurn.includes("returned no TURN server")) throw new Error(noTurn);

	const oversized = icePolicy({
		turnCredentialsUrl: "https://issuer.example/credentials",
		turnBearerToken: "secret",
	}, () =>
		Promise.resolve(
			new Response("x".repeat(64 * 1024 + 1), {
				headers: { "content-type": "application/json" },
			}),
		));
	const tooLarge = String(await rejectionOf(oversized.servers()));
	if (!tooLarge.includes("response is too large")) throw new Error(tooLarge);
});

Deno.test("a failed ICE request retries instead of substituting a third party", async () => {
	let calls = 0;
	const source = iceServerSource(() => {
		calls++;
		if (calls === 1) return Promise.reject(new Error("offline"));
		return Promise.resolve(new Response(JSON.stringify([])));
	});
	const first = await rejectionOf(source());
	if (!String(first).includes("offline")) throw first;
	assertEquals(await source(), [], "deployment's explicit empty answer");
	assertEquals(calls, 2, "request retried");
});

Deno.test("a successful ICE request is refreshed for the next connection", async () => {
	let calls = 0;
	const source = iceServerSource(() => {
		calls++;
		return Promise.resolve(Response.json([{ urls: `stun:s${calls}.example:3478` }]));
	});
	const [sharedA, sharedB] = await Promise.all([source(), source()]);
	assertEquals(sharedA, [{ urls: "stun:s1.example:3478" }]);
	assertEquals(sharedB, sharedA, "concurrent connection setup shares one request");
	assertEquals(await source(), [{ urls: "stun:s2.example:3478" }], "next connection refreshes credentials");
	assertEquals(calls, 2);
});

Deno.test("a malformed ICE response is refused rather than handed to WebRTC", async () => {
	const source = iceServerSource(() => Promise.resolve(new Response('{"not":"a list"}')));
	const error = await rejectionOf(source());
	if (!String(error).includes("must contain")) throw error;
});
