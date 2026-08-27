// The steward: the room's authority to ask a member out, answered only to
// the connection that opened the room, and an ordinary departure once used —
// the member hears the ask directly, the room reads why the leave happened,
// and nothing durable stands in the way of walking straight back in.

import { loopbackTcpDesignator, parseRoomsSturdyref, roomsSturdyrefForSession } from "../lib/locator.ts";
import { roomAuthorityIdentity } from "../lib/authority_identity.ts";
import { Room } from "../lib/room_client.ts";
import { GOVERNS, KICK, STEWARD } from "../lib/protocol.ts";
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
	within,
	withServer,
} from "./support/rooms_server.ts";

const swissDecoder = new TextDecoder("utf-8", { fatal: true });

roomsTest("the steward is the opener's, and a kick is an ordinary departure", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		// The opener's connection makes the room; the steward answers to it.
		const opener = await dial(locator);
		const openerRoom = await within(
			Room.subscribe(opener, await enterOrOpen(opener, "harbor"), "keeper"),
			"the opener subscribing",
		);
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

		// The real kick: the member hears the ask themselves, everyone reads
		// the steward's word, and the ordinary leave follows it.
		await within(openerRoom.kick("guest"), "the opener's kick");
		await nextMessage(otherRoom, (message) => message.text.includes("you were asked to leave #harbor"));
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

roomsTest("the steward capability itself refuses unknown verbs and blank names", async () => {
	await withServer(async (port) => {
		const opener = await dial(loopbackTcpDesignator(port));
		const room = await enterOrOpen(opener, "quay");
		await within(Room.subscribe(opener, room, "keeper"), "subscribing");
		const grant = await within(opener.send(room, STEWARD, []), "asking for the steward");
		if (
			!Array.isArray(grant) || typeof grant[0] !== "string" ||
			typeof grant[1] !== "string" || typeof grant[2] !== "string"
		) {
			throw new Error("the steward grant did not carry room identity and both authorities");
		}
		const roomSwiss = swissDecoder.decode(parseRoomsSturdyref(grant[0]).swissnum);
		assert(
			grant[1] === await roomAuthorityIdentity(roomSwiss),
			"the steward grant's public room identity did not match its room authority",
		);
		assert(grant[1] !== roomSwiss, "the steward disclosed the room's bearer swiss number as its identity");
		const steward = await opener.enliven(roomsSturdyrefForSession(grant[2], opener));
		assert(
			(await within(opener.send(steward, GOVERNS, []), "asking what the steward governs")) === grant[1],
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
		const session = await dial(locator);
		const harbor = await Room.subscribe(session, await enterOrOpen(session, "harbor"), "keeper");
		const quay = await Room.subscribe(session, await enterOrOpen(session, "quay"), "keeper");
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
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-steward-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory);
	try {
		await readPort(server);
		const first = await dial(locator);
		const opened = await Room.subscribe(first, await enterOrOpen(first, "harbor-master"), "keeper");
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
			await firstBack.enliven(roomsSturdyrefForSession(roomLink, firstBack)),
			"guest",
		);
		assert(
			!(await guest.claimSteward()),
			"the first member after restart inherited already-issued stewardship",
		);

		const holderSession = await dial(locator);
		const holder = await Room.subscribe(
			holderSession,
			await holderSession.enliven(roomsSturdyrefForSession(roomLink, holderSession)),
			"keeper",
		);
		await holder.takeSteward(stewardLink);
		await holder.kick("guest");
		await nextMessage(guest, (message) => message.text.includes("you were asked to leave"));

		await holder.leave();
		await holderSession.close();
		await firstBack.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});
