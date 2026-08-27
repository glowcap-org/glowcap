// Process proof for restart-stable attenuated Rooms session grants.

import { parseSturdyRef } from "@pancake/runtime";
import { RoomsSessionClient } from "../lib/rooms_session.ts";
import { roomsAddress, roomsHost, roomsSturdyrefForSession } from "../lib/locator.ts";
import { stopOwned } from "./support/children.ts";
import { assert, dial, freePort, roomsTest } from "./support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "./support/standalone_peer.ts";

const GRANT_ID = "00000000-0000-4000-8000-000000000001";

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

roomsTest("a durable session grant survives restart and stays revoked", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-grant-peer-" });
	const port = freePort();
	let peer = startRoomsSessionPeer(directory, port);
	let firstSession: Awaited<ReturnType<typeof dial>> | null = null;
	let restoredSession: Awaited<ReturnType<typeof dial>> | null = null;
	try {
		const root = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "grant Rooms session peer");
		const address = roomsAddress(parseSturdyRef(root, "v1_0").locator);
		firstSession = await dial(address, roomsHost(undefined, "v1-syrup"));
		const admin = new RoomsSessionClient(
			firstSession,
			await firstSession.enliven(roomsSturdyrefForSession(root, firstSession)),
		);
		const adminSnapshot = await admin.snapshot();
		assert(adminSnapshot.access === "admin", "the administration sturdyref did not report admin access");
		assert(adminSnapshot.grants?.length === 0, "a fresh session exposed a durable grant");
		const grant = await admin.issueGrant(GRANT_ID, "interact", "Shared tablet");
		assert(
			(await admin.snapshot()).grants?.[0]?.sturdyref === grant.sturdyref,
			"the issued grant was absent from admin state",
		);
		const interaction = new RoomsSessionClient(
			firstSession,
			await firstSession.enliven(roomsSturdyrefForSession(grant.sturdyref, firstSession)),
		);
		const initial = await interaction.snapshot();
		assert(initial.access === "interact", "the durable interaction grant reported the wrong access");
		assert(initial.grants?.length === 0, "an interaction grant received session administration state");
		await interaction.setStanding("grant-before-restart", initial.revision, "shared tablet");

		await stopOwned(peer);
		peer = startRoomsSessionPeer(directory, port);
		const restoredRoot = await announcedSturdyref(
			peer,
			"ROOMS-SESSION-LISTENING",
			"restored grant Rooms session peer",
		);
		assert(restoredRoot === root, "the session administration sturdyref changed across restart");
		await firstSession.close().catch(() => {});
		firstSession = null;

		restoredSession = await dial(address, roomsHost(undefined, "v1-syrup"));
		const restoredAdmin = new RoomsSessionClient(
			restoredSession,
			await restoredSession.enliven(roomsSturdyrefForSession(root, restoredSession)),
		);
		const restoredInteraction = new RoomsSessionClient(
			restoredSession,
			await restoredSession.enliven(roomsSturdyrefForSession(grant.sturdyref, restoredSession)),
		);
		const restored = await restoredInteraction.snapshot();
		assert(restored.checkpoint.standing === "shared tablet", "the durable grant returned to a different workspace");
		await restoredAdmin.revokeGrant(GRANT_ID);
		assert(
			await refused(() => restoredInteraction.snapshot()),
			"a live durable grant still answered after revocation",
		);

		await stopOwned(peer);
		peer = startRoomsSessionPeer(directory, port);
		await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "twice-restored grant Rooms session peer");
		await restoredSession.close().catch(() => {});
		restoredSession = null;
		const afterRevocation = await dial(address, roomsHost(undefined, "v1-syrup"));
		try {
			assert(
				await refused(() =>
					afterRevocation.enliven(roomsSturdyrefForSession(grant.sturdyref, afterRevocation))
				),
				"restart republished a revoked durable session grant",
			);
		} finally {
			await afterRevocation.close();
		}
	} finally {
		await firstSession?.close().catch(() => {});
		await restoredSession?.close().catch(() => {});
		await stopOwned(peer);
		await Deno.remove(directory, { recursive: true });
	}
});
