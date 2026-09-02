// Product-level diagnosis for opening a durable Rooms session capability.

import { IO } from "@glowcap/abi";
import { GlowcapError } from "@glowcap/runtime";

export function attachedSessionFailureText(error: unknown): string {
	const reason = error instanceof Error ? error.message : String(error);
	if (
		error instanceof GlowcapError && error.code === IO &&
		(error.detail?.includes("NetworkUnreachable") === true || reason.includes("NetworkUnreachable"))
	) {
		return "The shared session peer could not be reached. Make sure it is running and retry the " +
			"capability it currently announces. An iroh session needs either a reachable advertised address " +
			"or working iroh discovery and relay access.";
	}
	// `unknown swissnum` is the engine's answer when a peer is asked for a
	// capability it does not publish (src/ocapn/engine/bootstrap.zig). On this
	// path that is a link the session has stopped honoring, which is a fact
	// about the link and not about the paste, so it must not be answered with
	// advice to check the paste.
	if (reason.includes("unknown swissnum")) {
		return "The session peer does not know this capability. It was probably revoked, or belongs to a " +
			"session that no longer exists. Use one the session shows now.";
	}
	if (reason.includes("did not finish the OCapN handshake")) {
		return "The session peer was reached, but it did not finish the OCapN handshake. " +
			"Check that the Rooms session peer is running compatible code, then retry.";
	}
	// Directory signaling refusals are facts about the hosting tab, not about
	// whether the paste contained every character. `locatorRefusal` wraps any
	// remaining `glowcap error` string as paste advice, so these must not
	// leave here still looking like a native parse failure.
	if (reason.includes("no signaling inbox for that designator")) {
		return "The hosting tab is not answering WebRTC on the directory this capability names. On that " +
			"tab, join a room on the directory that served its page, Share, and leave it open. Reloading " +
			"it ends sharing.";
	}
	if (reason.includes("signalOffer needs a registered name")) {
		return "This browser could not signal through the directory the capability names. Retry after " +
			"that directory is reachable from here.";
	}
	if (reason.includes("PeerIdentityUnverified")) {
		return "The session peer answered, but this browser could not authenticate that it is the peer " +
			"the capability names. Retry with a capability the session shows now.";
	}
	return reason;
}
