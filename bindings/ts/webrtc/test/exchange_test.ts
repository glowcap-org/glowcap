/// <reference lib="dom" />

// One bring-up's ownership of the session it opened, over a fake peer
// connection. A bring-up that fails after the handshake closes that session
// instead of handing it out or dropping it.

import { CLOSED } from "@glowcap/abi";
import { GlowcapError, Host, Session } from "@glowcap/runtime";
import { bringUp, mintExchange, type Negotiation, type SignalingTarget } from "../exchange.ts";
import { assert, assertEquals } from "../../test/assert.ts";
import { fakeChannel, installFakePeerConnection } from "./fake_peer_connection.ts";

const TARGET: SignalingTarget = { designator: "b".repeat(64), introducer: null };

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function fakeHost(): Host {
	return Object.create(Host.prototype, { recordCallerlessBindingFailure: { value: () => {} } });
}

function trackedSession(): { session: Session; closes: () => number } {
	let closes = 0;
	const session: Session = Object.create(Session.prototype, {
		closeTransport: {
			value: () => {
				closes += 1;
			},
		},
	});
	return { session, closes: () => closes };
}

function answering(establish: Negotiation["establish"]): Negotiation {
	return { offerer: false, negotiate: () => Promise.resolve(), establish };
}

async function failureOf(pending: Promise<unknown>): Promise<unknown> {
	try {
		await pending;
	} catch (error) {
		return error;
	}
	throw new Error("the bring-up handed out its session");
}

Deno.test("an abort after the handshake closes the opened session", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { session, closes } = trackedSession();
		const stop = new AbortController();
		let finishSend = (): void => {};
		const signaling = {
			candidate: () =>
				new Promise<void>((resolve) => {
					finishSend = resolve;
				}),
			onCandidate: () => () => {},
		};
		// A candidate send still in flight holds the bring-up open past the
		// handshake, and the caller gives up meanwhile.
		const opening = bringUp(
			fakeHost(),
			signaling,
			mintExchange(),
			TARGET,
			{},
			stop.signal,
			"webrtc accept",
			answering(() => {
				setTimeout(() => {
					stop.abort();
					finishSend();
				}, 0);
				return Promise.resolve(session);
			}),
		);
		await settle();
		fake.instance().emitLocalCandidate("in-flight");
		fake.instance().emitDataChannel(fakeChannel({ readyState: "open" }));
		const error = await failureOf(opening);
		assert(error instanceof GlowcapError && error.code === CLOSED, String(error));
		await settle();
		assertEquals(closes(), 1);
	} finally {
		fake.restore();
	}
});

Deno.test("a candidate disposer that throws after the handshake closes the opened session", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { session, closes } = trackedSession();
		const disposerFailure = new Error("disposer failed");
		const signaling = {
			candidate: () => {},
			onCandidate: () => () => {
				throw disposerFailure;
			},
		};
		const opening = bringUp(
			fakeHost(),
			signaling,
			mintExchange(),
			TARGET,
			{},
			undefined,
			"webrtc accept",
			answering(() => Promise.resolve(session)),
		);
		await settle();
		fake.instance().emitDataChannel(fakeChannel({ readyState: "open" }));
		assertEquals(await failureOf(opening), disposerFailure);
		assertEquals(closes(), 1);
	} finally {
		fake.restore();
	}
});
