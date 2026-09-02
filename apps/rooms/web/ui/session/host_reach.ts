// Whether a tab-hosted Share can be reached over the advertised WebRTC door.

import { TRANSPORT_WEBRTC } from "@glowcap/runtime";

/** Refusal when Share would publish a WebRTC sturdyref nobody can signal to.
 *
 * Attach signals through the directory the capability names — this page's home
 * directory, where Share files the inbox. A live membership on some other
 * directory, or a connection that never registered a name, does not file it. */
export function webrtcShareRefusal(transport: string, homeDirectoryReady: boolean): string {
	if (transport !== TRANSPORT_WEBRTC || homeDirectoryReady) return "";
	return "Join a room on this page's directory, then Share again. The capability names that " +
		"directory so another browser can Attach even from a different Rooms page.";
}

/** Refusal unless this page's home directory is live and registered, so Attach
 * can `signalOffer` to the inbox Share just filed. */
export function webrtcHomeShareReady(
	transport: string,
	homeId: string,
	connectedDirectories: readonly string[],
	nick: string,
): string {
	return webrtcShareRefusal(transport, connectedDirectories.includes(homeId) && nick !== "");
}
