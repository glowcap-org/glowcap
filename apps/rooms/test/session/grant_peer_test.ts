// Process proof for restart-stable attenuated Rooms session grants.

import { parseSturdyRef } from "@pancake/runtime";
import { RoomsSessionClient } from "../../lib/session/client.ts";
import { roomsAddress, roomsHost } from "../../lib/locator.ts";
import { stopOwned } from "../support/children.ts";
import { assert, dial, freePort, roomsTest } from "../support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "../support/standalone_peer.ts";

const GRANT_ID = "00000000-0000-4000-8000-000000000001";
const SECOND_GRANT_ID = "00000000-0000-4000-8000-000000000002";

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

/** Wait until anything the session has already been asked to do has been done
 * and handed out.
 *
 * A round trip is the barrier: the session answers one caller at a time, so a
 * reply to a question asked after a change means the change was applied and
 * whatever it sends to attached views was handed to the connection before that
 * reply was. Two of them, because the reply and a notice travel as separate
 * messages and only the second trip is behind both. */
async function settled(client: RoomsSessionClient): Promise<void> {
	await client.snapshot();
	await client.snapshot();
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
		firstSession = await dial(address, roomsHost(undefined, "interop"));
		const admin = new RoomsSessionClient(
			firstSession,
			await firstSession.enliven(root),
		);
		const adminSnapshot = await admin.snapshot();
		assert(adminSnapshot.access === "admin", "the administration sturdyref did not report admin access");
		assert(adminSnapshot.grants?.length === 0, "a fresh session exposed a durable grant");
		const grant = await admin.issueGrant(GRANT_ID, "interact", "Shared tablet", false);
		assert(
			(await admin.snapshot()).grants?.[0]?.sturdyref === grant.sturdyref,
			"the issued grant was absent from admin state",
		);
		const interaction = new RoomsSessionClient(
			firstSession,
			await firstSession.enliven(grant.sturdyref),
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

		restoredSession = await dial(address, roomsHost(undefined, "interop"));
		const restoredAdmin = new RoomsSessionClient(
			restoredSession,
			await restoredSession.enliven(root),
		);
		const restoredInteraction = new RoomsSessionClient(
			restoredSession,
			await restoredSession.enliven(grant.sturdyref),
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
		const afterRevocation = await dial(address, roomsHost(undefined, "interop"));
		try {
			assert(
				await refused(() => afterRevocation.enliven(grant.sturdyref)),
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

// What a link grants can change; which link it is cannot.
//
// An access link names a grant, and the grant says what that access is now. So
// narrowing one takes effect on whoever is holding it, without their
// reconnecting and without their link changing — which is the only way a
// narrowing is worth anything, since the moment you want it is the moment
// somebody is using it. Suspension is the same mechanism at its narrowest: the
// intended access is remembered, so lifting it needs no one to recall what it
// was.
roomsTest("a durable grant's access changes under one unchanging link", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-grant-tier-" });
	const port = freePort();
	let peer = startRoomsSessionPeer(directory, port);
	let session: Awaited<ReturnType<typeof dial>> | null = null;
	try {
		const root = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "grant tier Rooms session peer");
		const address = roomsAddress(parseSturdyRef(root, "v1_0").locator);
		session = await dial(address, roomsHost(undefined, "interop"));
		const admin = new RoomsSessionClient(session, await session.enliven(root));
		const grant = await admin.issueGrant(GRANT_ID, "interact", "Shared tablet", false);
		assert(!grant.history, "a link issued without the history answer was given it anyway");
		// Reading what was recorded before a link existed is its own authority, so
		// it is asked for at the point of issue and answered either way.
		const reading = await admin.issueGrant(SECOND_GRANT_ID, "interact", "Historian", true);
		assert(reading.history, "a link issued with the history answer was refused it");
		assert(reading.sturdyref !== grant.sturdyref, "two grants share one link");
		await admin.revokeGrant(SECOND_GRANT_ID);
		const held = new RoomsSessionClient(session, await session.enliven(grant.sturdyref));
		const first = await held.snapshot();
		assert(first.access === "interact", "the grant did not report the access it was issued with");
		await held.setStanding("tier-while-interacting", first.revision, "shared tablet");

		// Narrowed while it is being held. No reconnection, no new link.
		const narrowed = await admin.setGrantAccess(GRANT_ID, "observe");
		assert(narrowed.sturdyref === grant.sturdyref, "narrowing the grant changed its link");
		const observing = await held.snapshot();
		assert(observing.access === "observe", `the held grant still reports ${observing.access}`);
		assert(
			await refused(() => held.setStanding("tier-after-narrowing", observing.revision, "still typing")),
			"a narrowed grant still accepted a command from the view already holding it",
		);

		// Attached before the suspension and still attached through it, because
		// staying attached is how it is told the moment access comes back. That
		// makes what it hears in between the question: a suspended view is left in
		// every fan-out table the session walks, so it goes on receiving the whole
		// session unless each of those asks whether it should.
		let heard = 0;
		await held.watch(() => {
			heard += 1;
		});
		await admin.setStanding("heard-while-observing", (await admin.snapshot()).revision, "shared tablet");
		await settled(admin);
		assert(heard > 0, "a view with access heard nothing the session did");

		// Suspended: no access at all, and a reason the holder can read.
		await admin.suspendGrant(GRANT_ID, "Paused while the tablet is lent out");
		const suspended = await held.snapshot();
		assert(suspended.access === "none", `a suspended grant reports ${suspended.access}`);
		assert(
			suspended.suspendedNote === "Paused while the tablet is lent out",
			`a suspended grant did not say why: ${suspended.suspendedNote}`,
		);
		// And it is answered with no session, rather than with the session it may
		// not read.
		assert(
			suspended.checkpoint.conversations.length === 0 && suspended.checkpoint.directories.length === 0,
			`a suspended grant was handed the session it may not read: ${JSON.stringify(suspended.checkpoint)}`,
		);

		// The pause itself reaches it, and then nothing does. What the session does
		// while a link is paused is not that link's business, and a reader still
		// receiving every change is reading the session whatever its snapshot says
		// its access is.
		await settled(admin);
		const atPause = heard;
		await admin.setStanding("unheard-while-paused", (await admin.snapshot()).revision, "lent out");
		await settled(admin);
		assert(
			heard === atPause,
			`a paused view was still hearing the session: ${heard - atPause} deliveries while paused`,
		);

		// Lifted, and the access it was issued with comes back on its own.
		await admin.resumeGrant(GRANT_ID);
		const resumed = await held.snapshot();
		assert(resumed.access === "observe", `lifting a suspension did not restore the access: ${resumed.access}`);
		// And it is listening again, which is what makes the silence above a
		// refusal rather than a view that had quietly stopped hearing anything.
		await settled(admin);
		const atResume = heard;
		await admin.setStanding("heard-again", (await admin.snapshot()).revision, "back in hand");
		await settled(admin);
		assert(heard > atResume, "a resumed view was never given the session back");

		// And none of it moved the link.
		await stopOwned(peer);
		peer = startRoomsSessionPeer(directory, port);
		await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "restored grant tier Rooms session peer");
		await session.close().catch(() => {});
		session = await dial(address, roomsHost(undefined, "interop"));
		const again = new RoomsSessionClient(session, await session.enliven(grant.sturdyref));
		assert((await again.snapshot()).access === "observe", "the changed access did not survive a restart");
	} finally {
		await session?.close().catch(() => {});
		await stopOwned(peer);
		await Deno.remove(directory, { recursive: true });
	}
});
