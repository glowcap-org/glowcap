// One-shot room entrances mint one membership claim without becoming a reusable room link.

import { Directory, Room, RoomInvitation } from "../../lib/room/client.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { assert, dial, roomsTest, withServer } from "../support/rooms_server.ts";
import { MODERATED_ROOM_POLICY, OPEN_ROOM_POLICY, PRIVATE_ROOM_POLICY } from "../../lib/room/policy.ts";
import { MAX_ROOM_INVITATIONS } from "../../lib/limits.ts";

roomsTest("one invitation claim mints a participant membership and copied authority cannot claim again", async () => {
	await withServer(async (port) => {
		const directory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		try {
			const managed = await directory.openManaged("invitations");
			const owner = await Room.subscribe(directory.session, managed.room, "owner");
			const invitation = await owner.invite("participant");
			const copied = new RoomInvitation(directory.session, invitation.reference);
			const entrance = await invitation.claim();
			const retriedEntrance = await invitation.claim();
			const guest = await Room.subscribe(directory.session, entrance, "guest");
			let reused = false;
			try {
				await Room.subscribe(directory.session, retriedEntrance, "second guest");
			} catch {
				reused = true;
			}
			assert(reused, "retrying one invitation claim minted a second membership");
			await guest.say("claimed once");
			let refused = false;
			try {
				await copied.claim();
			} catch {
				refused = true;
			}
			assert(refused, "a copied invitation created a second claim");
			await guest.leave();
			await directory.close();
		} finally {
			await directory.close().catch(() => {});
		}
	});
});

roomsTest("live invitations are bounded and cannot resurrect an emptied room generation", async () => {
	await withServer(async (port) => {
		const directory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		try {
			const managed = await directory.openManaged("bounded invitations");
			const owner = await Room.subscribe(directory.session, managed.room, "owner");
			const invitations: RoomInvitation[] = [];
			for (let at = 0; at < MAX_ROOM_INVITATIONS; at += 1) invitations.push(await owner.invite());
			let bounded = false;
			try {
				await owner.invite();
			} catch {
				bounded = true;
			}
			assert(bounded, "a room retained invitations without a bound");
			await owner.leave();
			let retired = false;
			try {
				await invitations[0].claim();
			} catch {
				retired = true;
			}
			assert(retired, "an invitation resurrected an empty room generation");
		} finally {
			await directory.close().catch(() => {});
		}
	});
});

roomsTest("an invitation stops admitting once the membership that minted it ends", async () => {
	await withServer(async (port) => {
		const ownerDirectory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		const stayingDirectory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		try {
			// Listed and open, so a second connection can hold the room up on its
			// own. Without one this proves nothing the test above does not: an
			// emptied room retires its whole generation, and a refusal then would
			// be that rather than the membership ending.
			const managed = await ownerDirectory.openManaged("outliving", { policy: OPEN_ROOM_POLICY });
			const owner = await Room.subscribe(ownerDirectory.session, managed.room, "owner");
			const staying = await Room.subscribe(
				stayingDirectory.session,
				await stayingDirectory.enter("outliving"),
				"staying",
			);

			// One claimed while the minter is still a member, so the refusal below
			// is a retirement rather than a claim that could never have worked.
			// Claimed and not subscribed: taking the entrance on this connection
			// would replace the very membership whose ending is the subject.
			const spent = await owner.invite("participant");
			await spent.claim();

			const stranded = await owner.invite("participant");
			await owner.leave();

			await staying.say("still here");
			let refused = false;
			try {
				await stranded.claim();
			} catch {
				refused = true;
			}
			assert(refused, "an invitation went on admitting after the membership that minted it left");

			// And the room it was minted into is the same one, so what was cut is
			// the membership rather than everything the room was holding.
			const rejoined = await Room.subscribe(
				ownerDirectory.session,
				await ownerDirectory.enter("outliving"),
				"owner",
			);
			const survivor = await rejoined.invite("participant");
			await survivor.claim();
			await rejoined.leave();
			await staying.leave();
		} finally {
			await ownerDirectory.close().catch(() => {});
			await stayingDirectory.close().catch(() => {});
		}
	});
});

roomsTest("public policy offers observer memberships and failed registration changes nothing", async () => {
	await withServer(async (port) => {
		const ownerDirectory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		const readerDirectory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		try {
			const managed = await ownerDirectory.openManaged("briefing", { policy: MODERATED_ROOM_POLICY });
			const owner = await Room.subscribe(ownerDirectory.session, managed.room, "owner");
			await owner.takeManager(managed.managerLink);
			const observer = await Room.subscribe(
				readerDirectory.session,
				await readerDirectory.enter("briefing"),
				"reader",
			);
			assert(!observer.canSpeak, "a moderated public entrance minted a participant membership");
			let readOnly = false;
			try {
				await observer.say("should not send");
			} catch {
				readOnly = true;
			}
			assert(readOnly, "an observer membership spoke");

			await owner.setPolicy(PRIVATE_ROOM_POLICY, "briefing");
			await owner.say("existing participant remains");
			await readerDirectory.openManaged("occupied");
			let collided = false;
			try {
				await owner.setPolicy(MODERATED_ROOM_POLICY, "occupied");
			} catch {
				collided = true;
			}
			assert(collided, "a private room replaced an occupied public registration");
			assert(
				(await owner.policy()).visibility === "secret",
				"a failed public-name claim changed the room policy",
			);
			let absent = false;
			try {
				await readerDirectory.enter("briefing");
			} catch {
				absent = true;
			}
			assert(absent, "a private room remained publicly enterable");
			assert(observer.membershipKind === "observer", "policy withdrawal replaced an existing membership");
			await observer.leave();
			await owner.leave();
		} finally {
			await ownerDirectory.close().catch(() => {});
			await readerDirectory.close().catch(() => {});
		}
	});
});
