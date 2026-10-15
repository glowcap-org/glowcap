/// <reference lib="dom" />

import {
	WEBRTC_MAX_ICE_CANDIDATE_BYTES,
	WEBRTC_MAX_SIGNAL_BYTES,
	WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES,
} from "@glowcap/abi";
import { acceptRemoteCandidate } from "../exchange.ts";
import { RtcPeer } from "../peer.ts";
import { assertDeepEquals, deferred } from "../../dogfood/assert.ts";
import { fakeChannel, installFakePeerConnection } from "./fake_peer_connection.ts";

async function rejectionOf(promise: Promise<unknown>): Promise<unknown> {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	throw new Error("expected promise to reject");
}

Deno.test("RtcPeer gives the browser the embedding's ICE configuration", () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const iceServers = [{
			urls: ["turn:turn.example:3478?transport=udp", "turns:turn.example:5349?transport=tcp"],
			username: "short-lived-user",
			credential: "short-lived-secret",
		}];
		const peer = new RtcPeer({ offerer: false, iceServers });
		assertDeepEquals(fake.instance().configuration, { iceServers });
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer applies pre-SDP ICE candidates in arrival order", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const first = peer.addRemoteCandidate({ candidate: "first" });
		const second = peer.addRemoteCandidate({ candidate: "second" });
		const setRemote = peer.setRemoteOffer("offer");
		const pc = fake.instance();
		assertDeepEquals(pc.calls, ["set remote"]);
		pc.finishRemoteDescription();
		await Promise.all([setRemote, first, second]);
		assertDeepEquals(pc.calls, ["set remote", "candidate first", "candidate second"]);
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
		assertDeepEquals(pc.calls, ["set remote", "candidate original"]);
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
		assertDeepEquals(setError, failure);
		assertDeepEquals(badError, failure);
		assertDeepEquals(pc.calls, ["set remote", "candidate bad", "candidate good"]);
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
			peer.addRemoteCandidate({ candidate: "x".repeat(WEBRTC_MAX_ICE_CANDIDATE_BYTES + 1) }),
		);
		if (!String(error).includes("ICE candidate is too large")) throw error;
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer measures remote-candidate text in UTF-8 bytes", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const tooManyBytes = "é".repeat(Math.floor(WEBRTC_MAX_ICE_CANDIDATE_BYTES / 2) + 1);
		const error = await rejectionOf(
			peer.addRemoteCandidate({ candidate: tooManyBytes }),
		);
		if (!String(error).includes("ICE candidate is too large")) throw error;
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer bounds pending remote-candidate bytes", async () => {
	const held = deferred();
	const fake = installFakePeerConnection(async () => await held.promise);
	try {
		const peer = new RtcPeer({ offerer: false });
		const setRemote = peer.setRemoteOffer("offer");
		fake.instance().finishRemoteDescription();
		await setRemote;
		const maxCandidateBytes = "é".repeat(WEBRTC_MAX_ICE_CANDIDATE_BYTES / 2);
		const admittedCount = Math.floor(
			WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES / WEBRTC_MAX_ICE_CANDIDATE_BYTES,
		);
		const admitted = Array.from(
			{ length: admittedCount },
			() => peer.addRemoteCandidate({ candidate: maxCandidateBytes }),
		);
		const error = await rejectionOf(
			peer.addRemoteCandidate({ candidate: maxCandidateBytes }),
		);
		if (!String(error).includes("too many pending ICE candidates")) throw error;
		held.resolve();
		await Promise.all(admitted);
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer rejects oversized remote SDP before browser parsing", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const error = await rejectionOf(
			Promise.resolve().then(() => peer.setRemoteOffer("x".repeat(WEBRTC_MAX_SIGNAL_BYTES + 1))),
		);
		if (!String(error).includes("SDP is too large")) throw error;
		assertDeepEquals(fake.instance().calls, []);
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer rejects oversized generated offer before browser commit", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve(), {
		offerSdp: "x".repeat(WEBRTC_MAX_SIGNAL_BYTES + 1),
	});
	try {
		const peer = new RtcPeer({ offerer: true });
		const error = await rejectionOf(peer.createOffer());
		if (!String(error).includes("SDP is too large")) throw error;
		assertDeepEquals(fake.instance().calls, ["create offer"]);
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer rejects oversized generated answer before browser commit", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve(), {
		answerSdp: "x".repeat(WEBRTC_MAX_SIGNAL_BYTES + 1),
	});
	try {
		const peer = new RtcPeer({ offerer: false });
		const error = await rejectionOf(peer.createAnswer());
		if (!String(error).includes("SDP is too large")) throw error;
		assertDeepEquals(fake.instance().calls, ["create answer"]);
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer measures remote SDP in UTF-8 bytes", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const tooManyBytes = "é".repeat(Math.floor(WEBRTC_MAX_SIGNAL_BYTES / 2) + 1);
		const error = await rejectionOf(Promise.resolve().then(() => peer.setRemoteOffer(tooManyBytes)));
		if (!String(error).includes("SDP is too large")) throw error;
		assertDeepEquals(fake.instance().calls, []);
		peer.close();
	} finally {
		fake.restore();
	}
});

Deno.test("acceptRemoteCandidate rejects oversized JSON before parsing", async () => {
	let called = false;
	const peer = {
		addRemoteCandidate(): Promise<void> {
			called = true;
			return Promise.resolve();
		},
	};
	const error = await rejectionOf(
		acceptRemoteCandidate(peer, "x".repeat(WEBRTC_MAX_SIGNAL_BYTES + 1)),
	);
	if (!String(error).includes("signaling message is too large")) throw error;
	assertDeepEquals(called, false);
});

Deno.test("acceptRemoteCandidate measures JSON in UTF-8 bytes before parsing", async () => {
	let called = false;
	const peer = {
		addRemoteCandidate(): Promise<void> {
			called = true;
			return Promise.resolve();
		},
	};
	const tooManyBytes = "é".repeat(Math.floor(WEBRTC_MAX_SIGNAL_BYTES / 2) + 1);
	const error = await rejectionOf(acceptRemoteCandidate(peer, tooManyBytes));
	if (!String(error).includes("signaling message is too large")) throw error;
	assertDeepEquals(called, false);
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

Deno.test("RtcPeer refuses unreliable data channels", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const opening = peer.waitOpen();
		fake.instance().emitDataChannel(fakeChannel({ maxRetransmits: 0 }));
		const error = await rejectionOf(opening);
		if (!String(error).includes("reliable ordered ocapn")) throw error;
	} finally {
		fake.restore();
	}
});

Deno.test("RtcPeer turns the ICE agent's terminal failure into a rejected open", async () => {
	const fake = installFakePeerConnection(() => Promise.resolve());
	try {
		const peer = new RtcPeer({ offerer: false });
		const opening = peer.waitOpen();
		// Two peers with no route to each other never open a data channel and
		// never fail one either; the connection state is the only verdict. It
		// must settle the open with a reason a person can act on, not hang.
		fake.instance().failConnection();
		const error = await rejectionOf(opening);
		if (!String(error).includes("ICE failed")) throw error;
		peer.close();
	} finally {
		fake.restore();
	}
});
