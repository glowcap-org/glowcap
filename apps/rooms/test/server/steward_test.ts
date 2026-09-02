// The moderator: the room's authority to ask a member out, issued only through
// its passable manager, and an ordinary departure once used —
// the member hears the ask directly, the room reads why the leave happened,
// and nothing durable stands in the way of walking straight back in.

import { loopbackTcpDesignator, parseRoomsSturdyref } from "../../lib/locator.ts";
import { roomAuthorityIdentity } from "../../lib/authority_identity.ts";
import { Room } from "../../lib/room/client.ts";
import { Directory } from "../../lib/directory.ts";
import { RoomManager, RoomManagerMismatch } from "../../lib/room/manager.ts";
import { roomAuthorityToken } from "../../lib/room/authority.ts";
import { OPEN_ROOM_POLICY } from "../../lib/room/policy.ts";
import { ROOM_EXISTS, roomErrorOf } from "../../lib/errors.ts";
import { GOVERNS, KICK, MEMBERSHIP_ENDED, NOTIFY, SUBSCRIBE } from "../../lib/protocol.ts";
import {
	assert,
	dial,
	enterOrOpen,
	nextMessage,
	readPort,
	restartStatefulServer,
	roomsTest,
	stablePort,
	startStatefulServer,
	stopServer,
	until,
	within,
	withServer,
} from "../support/rooms_server.ts";

const swissDecoder = new TextDecoder("utf-8", { fatal: true });

async function waitForRoomEnd(room: Room): Promise<void> {
	const reader = room.messages.getReader();
	try {
		for (let at = 0; at < 50; at += 1) if ((await reader.read()).done) return;
		throw new Error("the room stream did not end within its message bound");
	} finally {
		reader.releaseLock();
	}
}

async function createManagedRoom(locator: string, name: string, nick: string) {
	const directory = await Directory.connect(locator, (address) => dial(address));
	const managed = await directory.openManaged(name);
	const room = await Room.subscribe(directory.session, managed.room, nick);
	await room.takeManager(managed.managerLink);
	return { directory, managed, room };
}

roomsTest("a room manager passes between peers without keeping an empty room live", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const owner = await Directory.connect(locator, (address) => dial(address));
		const managed = await owner.openManaged("managed");
		const ownerRoom = await Room.subscribe(owner.session, managed.room, "owner");
		await ownerRoom.takeManager(managed.managerLink);
		assert(await ownerRoom.claimSteward(), "the room manager did not issue moderation");
		const moderator = ownerRoom.stewardLink;
		assert(moderator !== null, "manager-issued moderation had no sturdyref");

		const guest = await Directory.connect(locator, (address) => dial(address));
		const guestRef = await guest.session.enliven(managed.roomLink);
		const guestRoom = await Room.subscribe(guest.session, guestRef, "guest");
		await guestRoom.takeManager(managed.managerLink);
		const guestManager = await RoomManager.take(guest.session, guestRef, managed.managerLink);
		const otherManaged = await guest.openManaged("other-managed");
		const otherRoom = await Room.subscribe(guest.session, otherManaged.room, "guest");
		let mismatch = false;
		try {
			await otherRoom.takeManager(managed.managerLink);
		} catch (error) {
			mismatch = error instanceof RoomManagerMismatch;
		}
		assert(mismatch, "a manager for another room was accepted or lost its typed refusal");
		await otherRoom.leave();
		await guestManager.revokeModerator(roomAuthorityToken(moderator));
		let kicked = true;
		try {
			await ownerRoom.kick("guest");
		} catch {
			kicked = false;
		}
		assert(!kicked, "a manager delegated to another peer did not revoke old moderation");

		await guestRoom.leave();
		await ownerRoom.leave();
		assert(
			!(await owner.list()).some((room) => room.name === "managed"),
			"manager authority kept an empty room live",
		);
		assert(
			(await guestManager.roomLink()) === managed.roomLink,
			"an empty room lost its durable manager authority",
		);
		assert(
			!(await owner.list()).some((room) => room.name === "managed"),
			"using a manager recreated live membership",
		);
		let nameStayedRegistered = false;
		try {
			await owner.open("managed");
		} catch (error) {
			nameStayedRegistered = roomErrorOf(error)?.code === ROOM_EXISTS;
		}
		assert(nameStayedRegistered, "an empty managed room released its registered public name");
		const returned = await Room.subscribe(owner.session, await owner.enter("managed"), "returning");
		assert(
			(await guestManager.roomLink()) === managed.roomLink,
			"entering a registered room replaced its durable identity",
		);
		await returned.leave();
		await owner.close();
		await guest.close();
	});
});

roomsTest("a room manager unregisters its public name without ending current memberships", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const opened = await createManagedRoom(locator, "released-name", "owner");
		assert(await opened.room.claimSteward(), "the registered room did not issue moderation");
		const stewardLink = opened.room.stewardLink;
		assert(stewardLink !== null, "the registered room retained no moderator link");
		const managerRoom = await opened.directory.session.enliven(opened.managed.roomLink);
		const manager = await RoomManager.take(
			opened.directory.session,
			managerRoom,
			opened.managed.managerLink,
		);
		opened.directory.session.release(managerRoom);

		const guestDirectory = await Directory.connect(locator, (address) => dial(address));
		const guest = await Room.subscribe(
			guestDirectory.session,
			await guestDirectory.enter("released-name"),
			"guest",
		);
		await manager.unregisterRoom();
		await opened.room.say("membership survives unregistration");
		await nextMessage(guest, (message) => message.text === "membership survives unregistration");
		assert((await manager.roomLink()) === opened.managed.roomLink, "unregistration discarded the room entry link");
		assert(opened.room.stewardLink === stewardLink, "unregistration discarded moderator authority");
		const registered = await manager.setPolicy(OPEN_ROOM_POLICY, "released-name");
		assert(registered.policy.visibility === "listed", "the same manager could not register the room again");
		const returned = await Room.subscribe(
			guestDirectory.session,
			await guestDirectory.enter("released-name"),
			"returning",
		);
		assert(returned.membershipKind === "participant", "the restored registration offered the wrong membership");
		await returned.leave();
		await opened.room.leave();
		await guestDirectory.close();
		await opened.directory.close();
	});
});

roomsTest("the steward is the manager's to issue, and a kick is an ordinary departure", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const opened = await createManagedRoom(locator, "harbor", "keeper");
		const opener = opened.directory.session;
		const openerRoom = opened.room;
		assert(await openerRoom.claimSteward(), "the opener was not issued the steward");
		const retained = openerRoom.stewardLink;
		assert(retained !== null, "the opener did not retain its issued steward");
		await openerRoom.takeSteward(retained);
		assert(openerRoom.canKick, "taking an already-held steward discarded its live authority");

		const other = await dial(locator);
		const otherRoom = await within(
			Room.subscribe(other, await enterOrOpen(other, "harbor"), "guest"),
			"the guest subscribing",
		);
		await nextMessage(openerRoom, (message) => message.text.includes("guest joined"));
		const roomLink = openerRoom.roomLink;
		assert(roomLink !== null, "the issued moderator did not retain its room link");
		let wrongCapability = "";
		try {
			await otherRoom.takeSteward(roomLink);
		} catch (error) {
			wrongCapability = error instanceof Error ? error.message : String(error);
		}
		assert(
			wrongCapability.includes("could not validate that sturdyref as a room moderator capability"),
			`a room link pasted as moderator authority said: ${wrongCapability}`,
		);

		// Any other connection is refused in the room's own words.
		assert(!(await otherRoom.claimSteward()), "the guest was answered a steward");

		// A steward's kick of a name nobody wears is refused by name.
		let refused = "";
		try {
			await within(openerRoom.kick("nobody"), "kicking an absent name");
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes('nobody here answers to "nobody"'), `an absent kick said: "${refused}"`);
		refused = "";
		try {
			await within(openerRoom.kick(" guest "), "kicking a silently changed name");
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes('nobody here answers to " guest "'), `a padded kick said: "${refused}"`);

		// The real kick: the member's stream ends with the reason, everyone else
		// reads the steward's word, and the ordinary leave follows it.
		await within(openerRoom.kick("guest"), "the opener's kick");
		await within(waitForRoomEnd(otherRoom), "the kicked room stream ending");
		assert(
			otherRoom.endedReason?.includes("You were asked to leave #harbor") === true,
			`the retired member stream ended as ${otherRoom.endedReason}`,
		);
		await nextMessage(openerRoom, (message) => message.text === "guest was asked to leave");
		await nextMessage(openerRoom, (message) => message.text.includes("guest left"));

		// Nothing durable was minted against them: walking back in works.
		const back = await within(
			Room.subscribe(other, await enterOrOpen(other, "harbor"), "guest"),
			"the guest returning",
		);
		await nextMessage(openerRoom, (message) => message.text.includes("guest joined"));
		await within(back.leave(), "the returned guest leaving");

		await openerRoom.leave().catch(() => {});
		await opener.close().catch(() => {});
		await other.close().catch(() => {});
	});
});

roomsTest("membership retirement stays on the baseline notify inbox", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const opened = await createManagedRoom(locator, "common-inbox", "keeper");
		const opener = opened.directory.session;
		const openerRoom = opened.room;
		assert(await openerRoom.claimSteward(), "the opener was not issued the steward");

		const guest = await dial(locator);
		const guestRoom = await enterOrOpen(guest, "common-inbox");
		const notices: unknown[][] = [];
		const inbox = guest.spawn((verb, args) => {
			if (verb !== NOTIFY) throw new Error(`baseline room inbox has no method ${verb}`);
			notices.push(args);
			return null;
		});
		await guest.send(guestRoom, SUBSCRIBE, ["guest", inbox]);
		await within(openerRoom.kick("guest"), "kicking the baseline-inbox member");
		await until(
			() => notices.some((args) => args[2] === MEMBERSHIP_ENDED),
			"membership retirement did not use the baseline notify inbox",
		);

		await openerRoom.leave().catch(() => {});
		await opener.close().catch(() => {});
		await guest.close().catch(() => {});
	});
});

roomsTest("the steward capability itself refuses unknown verbs and blank names", async () => {
	await withServer(async (port) => {
		const managed = await createManagedRoom(loopbackTcpDesignator(port), "quay", "keeper");
		const opener = managed.directory.session;
		assert(await managed.room.claimSteward(), "the room manager did not issue moderation");
		const roomLink = managed.room.roomLink;
		const stewardLink = managed.room.stewardLink;
		assert(roomLink !== null && stewardLink !== null, "manager issuance retained incomplete authority");
		const roomSwiss = swissDecoder.decode(parseRoomsSturdyref(roomLink).swissnum);
		const identity = await roomAuthorityIdentity(roomSwiss);
		assert(
			identity === await roomAuthorityIdentity(roomSwiss),
			"the steward grant's public room identity did not match its room authority",
		);
		assert(identity !== roomSwiss, "the steward disclosed the room's bearer swiss number as its identity");
		const steward = await opener.enliven(stewardLink);
		assert(
			(await within(opener.send(steward, GOVERNS, []), "asking what the steward governs")) === identity,
			"the steward did not identify its room without disclosing room authority",
		);
		let refused = "";
		try {
			await within(opener.send(steward as never, KICK, [""]), "a blank kick");
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("kick names the member"), `a blank kick said: "${refused}"`);
		await opener.close().catch(() => {});
	});
});

roomsTest("a steward for another room is rejected without replacing the one held", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const directory = await Directory.connect(locator, (address) => dial(address));
		const session = directory.session;
		const harborManaged = await directory.openManaged("harbor");
		const harbor = await Room.subscribe(session, harborManaged.room, "keeper");
		await harbor.takeManager(harborManaged.managerLink);
		const quayManaged = await directory.openManaged("quay");
		const quay = await Room.subscribe(session, quayManaged.room, "keeper");
		await quay.takeManager(quayManaged.managerLink);
		assert(await harbor.claimSteward(), "harbor did not issue its steward");
		assert(await quay.claimSteward(), "quay did not issue its steward");
		const quaySteward = quay.stewardLink;
		assert(quaySteward !== null, "quay did not retain its steward link");

		let refused = "";
		try {
			await harbor.takeSteward(quaySteward);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("different room"), `a cross-room steward said: ${refused}`);
		assert(harbor.canKick, "a rejected replacement discarded the steward already held");

		await harbor.leave();
		await quay.leave();
		await session.close();
	});
});

roomsTest("stewardship survives restart and never falls to the first member back", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "glowcap-rooms-steward-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory);
	try {
		await readPort(server);
		const firstManaged = await createManagedRoom(locator, "harbor-master", "keeper");
		const first = firstManaged.directory.session;
		const opened = firstManaged.room;
		assert(await opened.claimSteward(), "the opener was not issued durable stewardship");
		const roomLink = opened.roomLink;
		const stewardLink = opened.stewardLink;
		assert(roomLink !== null, "issuing stewardship did not retain the room link");
		assert(stewardLink !== null, "issuing stewardship did not retain the steward link");
		await opened.leave();
		await first.close();

		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory);

		// The first arrival reconstructs the live room and is its resource owner,
		// but that fact is not stewardship. The already-issued secret is the only
		// route back to moderation authority.
		const firstBack = await dial(locator);
		const guest = await Room.subscribe(
			firstBack,
			await firstBack.enliven(roomLink),
			"guest",
		);
		assert(
			!(await guest.claimSteward()),
			"the first member after restart inherited already-issued stewardship",
		);

		const holderSession = await dial(locator);
		const holder = await Room.subscribe(
			holderSession,
			await holderSession.enliven(roomLink),
			"keeper",
		);
		await holder.takeSteward(stewardLink);
		await holder.kick("guest");
		await within(waitForRoomEnd(guest), "the restored steward ending the guest stream");
		assert(guest.endedReason?.includes("asked to leave") === true, "the kicked guest received no terminal reason");

		await holder.leave();
		await holderSession.close();
		await firstBack.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});
