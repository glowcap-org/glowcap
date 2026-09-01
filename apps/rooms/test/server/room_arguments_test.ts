import { type Behavior, Ref, type Session } from "@pancake/runtime";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import {
	ATTACH,
	AWAY,
	CALLED,
	DIRECTORY,
	DISCARD,
	ENTER,
	HISTORY,
	LEAVE,
	LINK,
	LIST,
	OPEN,
	POST,
	POST_FILES,
	PRIVATE,
	STEWARD,
	TYPING,
} from "../../lib/protocol.ts";
import { Directory, Room } from "../../lib/room/client.ts";
import { ROOM_FULL, roomErrorOf } from "../../lib/errors.ts";
import { assert, dial, roomsTest, withServer } from "../support/rooms_server.ts";
import { roomManagerBehavior } from "../../server/room_manager.ts";
import { rosterForAdmission } from "../../server/room.ts";
import { linkedRoomBehavior } from "../../server/room_link.ts";
import type { RoomLinks } from "../../server/room_links.ts";
import type { RoomState } from "../../server/registry.ts";
import { MAX_ROOM_MEMBERS } from "../../lib/limits.ts";
import { RoomServer } from "../../server/room_server.ts";

Deno.test("revoked room authorities return capability arguments before refusing", () => {
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	const links = () => ({}) as RoomLinks;
	const roomServer = new RoomServer();
	const history = roomServer.history;
	const behaviors: Behavior[] = [
		roomManagerBehavior("revoked-manager", links, () => false, () => session),
		linkedRoomBehavior(roomServer, "revoked-room", links, history, {
			active: () => false,
			sessionFor: () => session,
		}),
	];
	for (const behavior of behaviors) {
		const capability = Object.create(Ref.prototype) as Ref;
		let refused = false;
		try {
			behavior("unknown", [capability]);
		} catch {
			refused = true;
		}
		assert(refused, "a revoked room authority accepted a call");
		assert(released.at(-1) === capability, "a revoked room authority retained a capability argument");
	}
});

Deno.test("room admission bounds member count and the encoded roster", () => {
	const sessions = Array.from({ length: MAX_ROOM_MEMBERS }, () => ({}) as Session);
	const state = {
		members: sessions.map((session, at) => ({ session, nick: `member-${at}` })),
	} as RoomState;
	let code = "";
	try {
		rosterForAdmission(state, {} as Session, "one-more");
	} catch (error) {
		code = roomErrorOf(error)?.code ?? "";
	}
	assert(code === ROOM_FULL, `room member overflow answered ${code || "no typed code"}`);
	assert(
		rosterForAdmission(state, sessions[0], "renamed").length === MAX_ROOM_MEMBERS,
		"same-session room admission consumed another seat",
	);
	const wideSession = {} as Session;
	const wide = {
		members: Array.from({ length: 63 }, () => ({ session: {} as Session, nick: "🫓".repeat(32) })),
	} as RoomState;
	code = "";
	try {
		rosterForAdmission(wide, wideSession, "🫓".repeat(32));
	} catch (error) {
		code = roomErrorOf(error)?.code ?? "";
	}
	assert(code === ROOM_FULL, `room roster byte overflow answered ${code || "no typed code"}`);
});

roomsTest("directory data verbs refuse surplus and contradictory arguments", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			assert(
				await session.send(directory, OPEN, ["explicit-public", false]) instanceof Ref,
				"open refused its documented explicit public flag",
			);
			for (
				const [verb, args] of [
					[LIST, ["surplus"]],
					[OPEN, ["room", false, "not-a-private-recovery"]],
					[ENTER, ["room", "surplus"]],
				] as const
			) {
				let refused = false;
				try {
					await session.send(directory, verb, [...args]);
				} catch {
					refused = true;
				}
				assert(refused, `${verb} accepted invalid arguments`);
			}
		} finally {
			await session.close();
		}
	});
});

roomsTest("room data verbs refuse missing, surplus, and contradictory arguments", async () => {
	await withServer(async (port) => {
		const directory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		const room = await Room.subscribe(directory.session, await directory.open("exact-room"), "reader");
		try {
			for (
				const [verb, args] of [
					[POST, []],
					[POST_FILES, []],
					[ATTACH, ["file", "text/plain", 1n, 1n]],
					[TYPING, ["yes"]],
					[HISTORY, ["surplus"]],
					[STEWARD, ["surplus"]],
					[CALLED, ["surplus"]],
					[PRIVATE, ["surplus"]],
					[LINK, ["surplus"]],
					[AWAY, []],
					[LEAVE, ["surplus"]],
				] as const
			) {
				let refused = false;
				try {
					const membershipVerb = verb === POST || verb === POST_FILES || verb === ATTACH ||
						verb === TYPING || verb === HISTORY || verb === AWAY || verb === LEAVE;
					await directory.session.send(
						membershipVerb ? room.membershipReference : room.reference,
						verb,
						[...args],
					);
				} catch {
					refused = true;
				}
				assert(refused, `${verb} accepted invalid arguments`);
			}
			const upload = await directory.session.send(
				room.membershipReference,
				ATTACH,
				["exact.txt", "text/plain", 1n],
			);
			assert(upload instanceof Ref, "attach did not answer an upload capability");
			let refusedDiscard = false;
			try {
				await directory.session.send(upload, DISCARD, ["surplus"]);
			} catch {
				refusedDiscard = true;
			}
			assert(refusedDiscard, "discard accepted surplus data");
			await directory.session.send(upload, DISCARD, []);
			await room.say("still joined after refused leave");
			const retiredMembership = room.membershipReference;
			await room.leave();
			let postRefused = false;
			try {
				await directory.session.send(retiredMembership, POST, ["after leaving"]);
			} catch {
				postRefused = true;
			}
			assert(postRefused, "a released membership accepted a post");
		} finally {
			await room.leave();
			await directory.close();
		}
	});
});
