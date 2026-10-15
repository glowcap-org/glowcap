/// <reference lib="dom" />

// The browser listener's admission rules over a fake peer connection whose
// remote description never finishes, so every accept stays in flight until
// the test ends it. The live answer and session belong to
// `zig build webrtc-browser-to-browser`.

import {
	CLOSED,
	INVALID_ARGUMENT,
	TRANSPORT_WEBRTC,
	WEBRTC_MAX_ACCEPTS_IN_FLIGHT,
	WEBRTC_MAX_SIGNAL_BYTES,
	WOULD_BLOCK,
} from "@glowcap/abi";
import { GlowcapError, type Host, type Locator } from "@glowcap/runtime";
import { bringUp, mintExchange, type SignalingAuthority, type SignalingTarget } from "../exchange.ts";
import { listener } from "../listener.ts";
import { assertDeepEquals, assertEquals } from "../../dogfood/assert.ts";
import { installFakePeerConnection } from "./fake_peer_connection.ts";

const SELF = "a".repeat(64);
const PEER = "b".repeat(64);

function key(n: number): string {
	return n.toString(16).padStart(64, "0");
}

function fakeHost() {
	const advertised: Locator[] = [];
	const failures: Array<{ operation: string; error: unknown }> = [];
	const host = {
		designator: () => SELF,
		setAdvertisedLocator: (locator: Locator) => advertised.push(locator),
		recordCallerlessBindingFailure: (operation: string, error: unknown) => failures.push({ operation, error }),
	};
	return { host: host as unknown as Host, advertised, failures };
}

function answering(answer: SignalingAuthority["answer"] = () => {}) {
	const disposed: string[] = [];
	const signaling: Omit<SignalingAuthority, "offer"> = {
		answer,
		candidate() {},
		onCandidate(_exchange, target) {
			return () => disposed.push(target.designator);
		},
	};
	return { signaling, disposed };
}

function refusalCode(run: () => unknown): number {
	try {
		run();
	} catch (error) {
		if (error instanceof GlowcapError) return error.code;
		throw error;
	}
	throw new Error("expected a GlowcapError");
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

Deno.test("a listener advertises the Host's key as its webrtc locator", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host, advertised } = fakeHost();
		await using listening = listener(host, answering().signaling);
		assertEquals(listening.designator, SELF);
		assertEquals(advertised.length, 1);
		assertEquals(advertised[0].transport, TRANSPORT_WEBRTC);
		assertEquals(advertised[0].designator, SELF);
	} finally {
		fake.restore();
	}
});

Deno.test("an offer that names no key or is too large starts nothing", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host, failures } = fakeHost();
		const { signaling, disposed } = answering();
		await using listening = listener(host, signaling);
		assertEquals(refusalCode(() => listening.provideOffer("not a key", "offer")), INVALID_ARGUMENT);
		assertEquals(refusalCode(() => listening.provideOffer("B".repeat(64), "offer")), INVALID_ARGUMENT);
		const large = "x".repeat(WEBRTC_MAX_SIGNAL_BYTES + 1);
		assertEquals(refusalCode(() => listening.provideOffer(PEER, large)), INVALID_ARGUMENT);
		// The refusals reserved nothing, so the same peer may offer now.
		listening.provideOffer(PEER, "offer");
		await settle();
		assertEquals(disposed.length, 0);
		assertEquals(failures.length, 0);
	} finally {
		fake.restore();
	}
});

Deno.test("one authority signals a repeat offer and a dialed peer's offer as separate exchanges", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host, failures } = fakeHost();
		const answers: Array<{ exchange: bigint; designator: string }> = [];
		const candidates: Array<{ exchange: bigint; ice: string }> = [];
		const sinks = new Map<bigint, (ice: string) => void>();
		const signaling: SignalingAuthority = {
			offer: () => new Promise(() => {}),
			answer(exchange, target) {
				answers.push({ exchange, designator: target.designator });
			},
			candidate(exchange, ice) {
				candidates.push({ exchange, ice });
			},
			onCandidate(exchange, _target, sink) {
				sinks.set(exchange, sink);
				return () => sinks.delete(exchange);
			},
		};
		await using listening = listener(host, signaling);

		// The authority is dialing PEER when PEER's own offer arrives.
		const dialed = mintExchange();
		const target: SignalingTarget = { designator: PEER, introducer: null };
		const stopDial = new AbortController();
		const dial = bringUp(host, signaling, dialed, target, {}, stopDial.signal, "webrtc dial", {
			offerer: true,
			async negotiate(peer, step) {
				const offer = await step(peer.createOffer(), "offer");
				await step(signaling.offer(dialed, target, offer), "signaling");
			},
			establish: () => new Promise(() => {}),
		}).catch(() => {});
		const first = listening.provideOffer(PEER, "offer");
		const second = listening.provideOffer(PEER, "offer");
		assertEquals(new Set([dialed, first, second]).size, 3);

		const [dialer, firstPeer, secondPeer] = fake.instances();
		firstPeer.finishRemoteDescription();
		secondPeer.finishRemoteDescription();
		await settle();
		assertDeepEquals(answers.map(({ exchange, designator }) => `${exchange}:${designator}`), [
			`${first}:${PEER}`,
			`${second}:${PEER}`,
		]);

		dialer.emitLocalCandidate("dialed");
		firstPeer.emitLocalCandidate("first");
		secondPeer.emitLocalCandidate("second");
		await settle();
		const sent = new Map(candidates.map(({ exchange, ice }) => [exchange, JSON.parse(ice).candidate]));
		assertEquals(sent.get(dialed), "dialed");
		assertEquals(sent.get(first), "first");
		assertEquals(sent.get(second), "second");

		// Each exchange takes the candidates routed to its own id.
		sinks.get(first)!(JSON.stringify({ candidate: "for-first" }));
		await settle();
		assertEquals(firstPeer.calls.includes("candidate for-first"), true);
		assertEquals(secondPeer.calls.includes("candidate for-first"), false);
		assertEquals(dialer.calls.includes("candidate for-first"), false);

		listening.failExchange(first);
		listening.failExchange(second);
		stopDial.abort();
		await dial;
		await settle();
		// Ending an exchange cancels its open step and records only that late
		// settlement, never a signaling failure.
		assertEquals(failures.every((f) => f.operation === "webrtc.open.cancel.late-settlement"), true);
	} finally {
		fake.restore();
	}
});

Deno.test("an offer past the in-flight limit is refused", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host } = fakeHost();
		await using listening = listener(host, answering().signaling);
		const exchanges: bigint[] = [];
		for (let n = 1; n <= WEBRTC_MAX_ACCEPTS_IN_FLIGHT; n++) exchanges.push(listening.provideOffer(key(n), "offer"));
		const next = key(WEBRTC_MAX_ACCEPTS_IN_FLIGHT + 1);
		assertEquals(refusalCode(() => listening.provideOffer(next, "offer")), WOULD_BLOCK);
		await settle();
		listening.failExchange(exchanges[0]);
		await settle();
		listening.provideOffer(next, "offer");
	} finally {
		fake.restore();
	}
});

Deno.test("failExchange refuses an exchange that is not in progress", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host } = fakeHost();
		await using listening = listener(host, answering().signaling);
		assertEquals(refusalCode(() => listening.failExchange(9n)), INVALID_ARGUMENT);
		const exchange = listening.provideOffer(PEER, "offer");
		await settle();
		listening.failExchange(exchange);
		await settle();
		assertEquals(refusalCode(() => listening.failExchange(exchange)), INVALID_ARGUMENT);
	} finally {
		fake.restore();
	}
});

Deno.test("an answer the authority could not send ends the accept and is kept", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host, failures } = fakeHost();
		const refused = new Error("the room is gone");
		const { signaling, disposed } = answering(() => Promise.reject(refused));
		await using listening = listener(host, signaling);
		const exchange = listening.provideOffer(PEER, "offer");
		await settle();
		fake.instance().finishRemoteDescription();
		for (let i = 0; i < 5 && failures.length === 0; i++) await settle();
		assertDeepEquals(failures.map((f) => f.operation), ["webrtc.accept"]);
		assertEquals(failures[0].error, refused);
		assertDeepEquals(disposed, [PEER]);
		assertEquals(refusalCode(() => listening.failExchange(exchange)), INVALID_ARGUMENT);
	} finally {
		fake.restore();
	}
});

Deno.test("closing ends every accept in flight and refuses later offers", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const { host, failures } = fakeHost();
		const { signaling, disposed } = answering();
		const listening = listener(host, signaling);
		listening.provideOffer(PEER, "offer");
		const waiting = listening[Symbol.asyncIterator]().next();
		await settle();
		await listening.close();
		assertEquals((await waiting).done, true);
		assertEquals((await listening[Symbol.asyncIterator]().next()).done, true);
		assertDeepEquals(disposed, [PEER]);
		// An accept the listener closed is not a failure.
		assertEquals(failures.length, 0);
		assertEquals(refusalCode(() => listening.provideOffer(key(2), "offer")), CLOSED);
	} finally {
		fake.restore();
	}
});
