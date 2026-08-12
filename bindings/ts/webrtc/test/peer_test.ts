/// <reference lib="dom" />

import { RtcPeer } from "../peer.ts";

function assertEquals(actual: unknown, expected: unknown): void {
	if (JSON.stringify(actual) !== JSON.stringify(expected)) {
		throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
	}
}

function deferred(): { promise: Promise<void>; resolve: () => void } {
	let resolve!: () => void;
	const promise = new Promise<void>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	throw new Error("expected promise to reject");
}

interface FakePeerConnection {
	readonly calls: string[];
	finishRemoteDescription(): void;
}

function installFakePeerConnection(
	addCandidate: (candidate: RTCIceCandidateInit) => Promise<void>,
): { instance: () => FakePeerConnection; restore: () => void } {
	const original = Object.getOwnPropertyDescriptor(globalThis, "RTCPeerConnection");
	let current: FakePeerConnection | null = null;

	class FakeRTCPeerConnection {
		onicecandidate: ((event: RTCPeerConnectionIceEvent) => void) | null = null;
		ondatachannel: ((event: RTCDataChannelEvent) => void) | null = null;
		readonly calls: string[] = [];
		#resolveRemote!: () => void;
		readonly #remoteInstalled = new Promise<void>((resolve) => {
			this.#resolveRemote = resolve;
		});

		constructor() {
			current = this;
		}

		async setRemoteDescription(): Promise<void> {
			this.calls.push("set remote");
			await this.#remoteInstalled;
		}

		async addIceCandidate(candidate: RTCIceCandidateInit): Promise<void> {
			this.calls.push(`candidate ${candidate.candidate}`);
			await addCandidate(candidate);
		}

		finishRemoteDescription(): void {
			this.#resolveRemote();
		}

		close(): void {}
	}

	Object.defineProperty(globalThis, "RTCPeerConnection", {
		configurable: true,
		writable: true,
		value: FakeRTCPeerConnection as unknown as typeof RTCPeerConnection,
	});
	return {
		instance: () =>
			current ?? (() => {
				throw new Error("fake peer connection was not constructed");
			})(),
		restore: () => {
			if (original) Object.defineProperty(globalThis, "RTCPeerConnection", original);
			else delete (globalThis as { RTCPeerConnection?: unknown }).RTCPeerConnection;
		},
	};
}

Deno.test("RtcPeer applies pre-SDP ICE candidates in arrival order", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const first = peer.addRemoteCandidate({ candidate: "first" });
		const second = peer.addRemoteCandidate({ candidate: "second" });
		const setRemote = peer.setRemoteOffer("offer");
		const pc = fake.instance();
		assertEquals(pc.calls, ["set remote"]);
		pc.finishRemoteDescription();
		await Promise.all([setRemote, first, second]);
		assertEquals(pc.calls, ["set remote", "candidate first", "candidate second"]);
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer snapshots a candidate retained before remote SDP", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const candidate = { candidate: "original", sdpMid: "0" };
		const applied = peer.addRemoteCandidate(candidate);
		candidate.candidate = "mutated";
		const setRemote = peer.setRemoteOffer("offer");
		const pc = fake.instance();
		pc.finishRemoteDescription();
		await Promise.all([setRemote, applied]);
		assertEquals(pc.calls, ["set remote", "candidate original"]);
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer surfaces a queued ICE failure without stranding later candidates", async () => {
	const failure = new Error("candidate refused");
	const fake = installFakePeerConnection((candidate) =>
		candidate.candidate === "bad" ? Promise.reject(failure) : Promise.resolve()
	);
	try {
		const peer = new RtcPeer({ offerer: false });
		const bad = peer.addRemoteCandidate({ candidate: "bad" });
		const good = peer.addRemoteCandidate({ candidate: "good" });
		const setRemote = peer.setRemoteOffer("offer");
		const pc = fake.instance();
		pc.finishRemoteDescription();
		const [setError, badError] = await Promise.all([
			rejectionOf(setRemote),
			rejectionOf(bad),
			good,
		]);
		assertEquals(setError, failure);
		assertEquals(badError, failure);
		assertEquals(pc.calls, ["set remote", "candidate bad", "candidate good"]);
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer bounds the installed remote-candidate chain", async () => {
	const held = deferred();
	const fake = installFakePeerConnection(async () => await held.promise);
	try {
		const peer = new RtcPeer({ offerer: false });
		const setRemote = peer.setRemoteOffer("offer");
		fake.instance().finishRemoteDescription();
		await setRemote;
		const admitted = Array.from(
			{ length: 256 },
			(_, index) => peer.addRemoteCandidate({ candidate: `candidate-${index}` }),
		);
		const error = await rejectionOf(
			peer.addRemoteCandidate({ candidate: "candidate-overflow" }),
		);
		if (!String(error).includes("too many pending ICE candidates")) throw error;
		held.resolve();
		await Promise.all(admitted);
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer refuses oversized remote-candidate text before retaining it", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const error = await rejectionOf(
			peer.addRemoteCandidate({ candidate: "x".repeat(4 * 1024 + 1) }),
		);
		if (!String(error).includes("ICE candidate is too large")) throw error;
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer close rejects a channel-open wait", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const opening = peer.waitOpen();
		peer.close();
		const error = await rejectionOf(opening);
		if (!String(error).includes("peer closed")) throw error;
	} finally {
		fake.restore();
	}
});
