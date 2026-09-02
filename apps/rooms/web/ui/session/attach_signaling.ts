// WebRTC Attach signals through the directory the session capability names.
//
// A webrtc designator does not say which directory filed the answering inbox.
// Share writes that directory on the sturdyref. This Host reuses a session it
// already holds to that peer; it opens one only when it holds none.

import { retainCleanupFailures } from "@glowcap/runtime";
import { Directory } from "../../../lib/room/client.ts";
import { NICK_TAKEN, roomErrorOf } from "../../../lib/errors.ts";
import { suggestedNick } from "../../../lib/limits.ts";
import { dialDirectory, roomsSturdyrefLocator, webrtcSignalingDirectoryHint } from "../../../lib/locator.ts";
import { homeLocator } from "../net/bootstrap.ts";
import { iceServers } from "../net/ice.ts";
import { bootRuntime } from "../net/runtime_boot.ts";
import { ensureInbox, selfLocator } from "../net/reachable.ts";
import { dropMismatchedWebrtcAttachSignaling, webrtcAttachSignalingHeld } from "../net/webrtc_route.ts";
import type { RoomsPageContext } from "../page.ts";
import { attachSignalingNick } from "./attach_signaling_nick.ts";

const REGISTER_ATTEMPTS = 4;

export async function ensureWebrtcAttachSignaling(page: RoomsPageContext, sturdyref: string): Promise<void> {
	const locator = webrtcSignalingDirectoryHint(roomsSturdyrefLocator(sturdyref)) ??
		await homeLocator(page);
	dropMismatchedWebrtcAttachSignaling(page, locator);
	if (webrtcAttachSignalingHeld(page, locator)) {
		page.reachable.signalingDirectoryLocator = locator;
		return;
	}
	const runtime = await bootRuntime(page);
	ensureInbox(page, runtime, iceServers);
	const advertised = selfLocator(page);
	const owner = page.reachable.inboxOwner;
	if (advertised == null || owner == null) {
		throw new Error("this tab has no direct-message locator to signal an attach through");
	}
	const dir = await Directory.connect(
		locator,
		(address) => dialDirectory(address, runtime),
	);
	try {
		await registerAttachSignaling(dir, advertised, attachSignalingNick(owner.host.designator()));
	} catch (error) {
		throw await retainCleanupFailures(error, [() => dir.close()]);
	}
	page.reachable.signalingDirectory = dir;
	page.reachable.signalingDirectoryLocator = locator;
}

async function registerAttachSignaling(dir: Directory, advertised: string, nick: string): Promise<void> {
	let asked = nick;
	for (let attempt = 0; attempt < REGISTER_ATTEMPTS; attempt++) {
		try {
			await dir.register(asked, advertised);
			return;
		} catch (error) {
			if (roomErrorOf(error)?.code !== NICK_TAKEN || attempt + 1 === REGISTER_ATTEMPTS) throw error;
			asked = suggestedNick(asked);
		}
	}
}
