// Durable names, restarts, and the ways a server says it cannot start.
//
// A sturdyref has to mean the same room after the process that minted it is
// gone, which is the one claim here that a single run cannot make on its own —
// so these start servers, stop them, and start them again.

import { ROOM_EXISTS, ROOM_LINKS_FULL, RoomError, roomErrorOf } from "../../lib/errors.ts";
import { MAX_ROOM_LINKS } from "../../lib/limits.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { SUBSCRIBE } from "../../lib/protocol.ts";
import { Directory, Room, roomCalledAs, roomIsPrivate } from "../../lib/room/client.ts";
import { RoomServerState } from "../../server/state.ts";
import { type PublishRoomAuthorities, RoomLinks } from "../../server/room_links.ts";
import { RoomServer } from "../../server/room_server.ts";
import {
	assert,
	assertMatch,
	assertRoster,
	DENO_FLAGS,
	dial,
	ephemeralRoomsEnv,
	freePort,
	irohUsable,
	readPort,
	roomLines,
	roomsTest,
	ROOT,
	SERVER,
	subscribeOnceIroh,
	until,
	waitForLine,
	waitForRoster,
	watchRoomIroh,
	withIrohServer,
	withServer,
} from "../support/rooms_server.ts";
import { DURABLE_SWISS_ENTROPY_BYTES, type Session } from "@pancake/runtime";
import { spawnOwned, stopOwned } from "../support/children.ts";

async function untilListed(room: Room): Promise<void> {
	await until(
		() => room.listed !== undefined,
		"subscribe did not say whether the occupancy is listed",
	);
}

roomsTest("a public room's link is that listed room", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const owner = await Directory.connect(locator, (address) => dial(address));
		const guest = await Directory.connect(locator, (address) => dial(address));
		try {
			// A leading `~` is an ordinary public name. Only the exact 16-byte
			// private-key shape belongs to the private namespace.
			const managed = await owner.openManaged("~general");
			const room = await Room.subscribe(owner.session, managed.room, "ada");
			await room.takeManager(managed.managerLink);
			const link = managed.roomLink;
			const other = await Room.subscribe(guest.session, await guest.open("foo"), "cy");
			const guestRef = await guest.session.enliven(link);
			assert(
				(await roomCalledAs(guest.session, guestRef)) === "~general",
				"a public room's link did not say the listed name",
			);
			const heard = roomLines(room);
			// Join is subscribe. Asking `private()` first is what aborted `/join`
			// of a locator on an older occupancy: pancake error -12, "room has
			// no method private". Listed-ness arrives on the welcome.
			const asGuest = await Room.subscribe(guest.session, guestRef, "bo");
			await untilListed(asGuest);
			assert(asGuest.listed === true, "a public room's welcome did not say it is listed");
			assert((await room.isPrivate()) === false, "a public room answered as unlisted");
			assert(
				(await roomIsPrivate(guest.session, guestRef)) === false,
				"a public room's link answered as unlisted while this peer was in another room",
			);
			await asGuest.say("here by the public link");
			await waitForLine(heard, /here by the public link/);
			await asGuest.leave();
			await other.leave();
			await room.leave();
		} finally {
			await owner.close();
			await guest.close();
		}
	});
});

roomsTest("room link state restores its identity and sealed room names", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-state-" });
	try {
		const bytes = (entropy: Uint8Array) => [...entropy].join(",");
		const first = await RoomServerState.open(directory);
		const firstEntropy = bytes(await first.roomEntropyFor("General"));
		const firstStewardEntropy = bytes(await first.stewardEntropyFor("General"));
		await first.remember("General");

		const restored = await RoomServerState.open(directory);
		assert(
			[...restored.identitySeed].join(",") === [...first.identitySeed].join(","),
			"the room Host identity changed across state restore",
		);
		const exposedSeed = restored.identitySeed;
		exposedSeed[0] ^= 0xff;
		assert(exposedSeed[0] !== restored.identitySeed[0], "a caller could mutate the room Host identity seed");
		assert(
			bytes(await restored.roomEntropyFor("general")) === firstEntropy,
			"the same case-insensitive room did not restore the same swiss authority",
		);
		assert(
			bytes(await restored.roomEntropyFor("elsewhere")) !== firstEntropy,
			"one room link granted a different room",
		);
		assert(
			(await restored.roomEntropyFor("General")).length === DURABLE_SWISS_ENTROPY_BYTES,
			"a room's derived entropy is not the width the Host mints from",
		);
		assert(
			bytes(await restored.stewardEntropyFor("general")) === firstStewardEntropy,
			"the same room did not restore the same steward authority",
		);
		assert(
			firstStewardEntropy !== firstEntropy,
			"the steward and room publication shared one durable-name domain",
		);
		assert(
			restored.linkedRooms().join(",") === "General",
			"the explicitly linked room was not restored",
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("revoked room-link generations stay dead while the room name can issue a fresh one", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-link-revoke-" });
	try {
		const state = await RoomServerState.open(directory);
		await state.remember("General");
		const firstEntropy = [...await state.roomEntropyFor("General")].join(",");
		const firstGeneration = state.roomLinkGeneration("General");
		assert(state.roomLinkActive("general"), "a remembered room link was not active");
		await state.revokeRoomLink("GENERAL");
		assert(!state.roomLinkActive("general"), "revoking left the room link active");
		assert(
			!state.roomLinkGenerationIsCurrent("general", firstGeneration),
			"the revoked room-link generation remained current",
		);
		assert(state.revokedRooms().join(",") === "General", "the tombstone lost the room's durable name");

		const restored = await RoomServerState.open(directory);
		assert(!restored.roomLinkActive("General"), "restart republished a revoked room link");
		await restored.remember("general");
		const replacementGeneration = restored.roomLinkGeneration("general");
		const replacementEntropy = [...await restored.roomEntropyFor("general")].join(",");
		assert(replacementGeneration > firstGeneration, "room-link reissue did not advance its generation");
		assert(replacementEntropy !== firstEntropy, "room-link reissue recreated the revoked swiss authority");
		assert(
			!restored.roomLinkGenerationIsCurrent("general", firstGeneration) &&
				restored.roomLinkGenerationIsCurrent("general", replacementGeneration),
			"room-link reissue revived the old generation or failed to activate the new one",
		);

		const reloaded = await RoomServerState.open(directory);
		assert(
			reloaded.roomLinkGeneration("General") === replacementGeneration,
			"restart lost the replacement generation",
		);
		assert(
			[...await reloaded.roomEntropyFor("General")].join(",") === replacementEntropy,
			"restart changed the replacement room authority",
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("room and moderator reissue mint fresh authority without reviving live old holders", async () => {
	const state = await RoomServerState.open();
	const active: Array<() => boolean> = [];
	const publish: PublishRoomAuthorities = {
		room: (_name, entropy, current) => {
			active.push(current);
			return `room-${[...entropy].join("-")}`;
		},
		steward: (_name, _identity, entropy, current) => {
			active.push(current);
			return `moderator-${[...entropy].join("-")}`;
		},
		manager: (_name, entropy, current) => {
			active.push(current);
			return `manager-${[...entropy].join("-")}`;
		},
		unpublish: () => true,
	};
	const links = await RoomLinks.restore(new RoomServer(), state, publish, () => "127.0.0.1:1");
	const session = {} as Session;
	const first = await links.steward("General", session);
	assert(active[0]?.() === true && active[1]?.() === true, "the first room authorities were not active");
	await links.revokeRoomLink("General");
	assert(active[0]?.() === false && active[1]?.() === false, "revocation left a live old holder active");
	const replacement = await links.steward("General", session);
	assert(first.room !== replacement.room, "room-link reissue returned the revoked sturdyref");
	assert(first.steward !== replacement.steward, "moderator reissue returned the revoked sturdyref");
	assert(active[0]?.() === false && active[1]?.() === false, "replacement issuance revived an old holder");
	assert(active[2]?.() === true && active[3]?.() === true, "replacement authorities were not active");
});

roomsTest("room and moderator revocation remove their durable Host publications", async () => {
	const exercise = async (remove: "moderator" | "room") => {
		const directory = await Deno.makeTempDir({ prefix: `pancake-rooms-unpublish-${remove}-` });
		try {
			const state = await RoomServerState.open(directory);
			await state.rememberSteward("General");
			const unpublished: string[] = [];
			const publish: PublishRoomAuthorities = {
				room: (name) => `room-${name}`,
				steward: (name) => `moderator-${name}`,
				manager: (name) => `manager-${name}`,
				unpublish: (swiss) => {
					unpublished.push(swiss);
					return true;
				},
			};
			const links = await RoomLinks.restore(new RoomServer(), state, publish, () => "127.0.0.1:1");
			if (remove === "moderator") {
				await links.revokeSteward("General");
				assert(unpublished.join(",") === "moderator-General", `moderator revoke unpublished ${unpublished}`);
			} else {
				await links.revokeRoomLink("General");
				assert(
					new Set(unpublished).size === 2 && unpublished.includes("room-General") &&
						unpublished.includes("moderator-General"),
					`room revoke unpublished ${unpublished}`,
				);
			}
		} finally {
			await Deno.remove(directory, { recursive: true });
		}
	};
	await exercise("moderator");
	await exercise("room");
});

roomsTest("room link state refuses an unbounded durable name registry", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-link-limit-" });
	try {
		await RoomServerState.open(directory);
		const path = `${directory}/rooms.json`;
		const disk = JSON.parse(await Deno.readTextFile(path));
		disk.linkedRooms = Array.from({ length: MAX_ROOM_LINKS }, (_, index) => `r${index}`);
		await Deno.writeTextFile(path, JSON.stringify(disk) + "\n");

		const full = await RoomServerState.open(directory);
		let code: string | null = null;
		try {
			await full.remember("one-more");
		} catch (err) {
			code = err instanceof RoomError ? err.code : null;
		}
		assert(code === ROOM_LINKS_FULL, `expected room-links-full, got ${code}`);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("room state refuses unknown versions without rewriting them", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-state-version-" });
	try {
		await RoomServerState.open(directory);
		const path = `${directory}/rooms.json`;
		const current = JSON.parse(await Deno.readTextFile(path));
		for (const version of [2, 3, 4, 5, 6, 7]) {
			await Deno.writeTextFile(path, JSON.stringify({ ...current, version }) + "\n");
			let refused = "";
			try {
				await RoomServerState.open(directory);
			} catch (error) {
				refused = error instanceof Error ? error.message : String(error);
			}
			assertMatch(refused, new RegExp(`rooms state version ${version} is not supported`));
			assert(
				JSON.parse(await Deno.readTextFile(path)).version === version,
				`refusing version ${version} rewrote it as current state`,
			);
		}
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("a refused first subscription leaves no cold linked room behind", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const directory = await Directory.connect(locator, (address) => dial(address));
		try {
			const managed = await directory.openManaged("cold-rollback");
			const room = await Room.subscribe(directory.session, managed.room, "maker");
			const link = managed.roomLink;
			await room.leave();

			const cold = await directory.session.enliven(link);
			let refused = "";
			await directory.session.send(cold, SUBSCRIBE, ["broken", null]).catch((error) => {
				refused = error instanceof Error ? error.message : String(error);
			});
			assertMatch(refused, /subscribe needs an inbox capability/);

			// The failed first call did not commit a live room. The manager's
			// registration still owns the public name, and named entry reconstructs
			// that room rather than letting an unrelated open take it.
			assert(
				!(await directory.list()).some((room) => room.name === "cold-rollback"),
				"a refused cold subscription left a live room behind",
			);
			let nameStayedRegistered = false;
			try {
				await directory.open("cold-rollback");
			} catch (error) {
				nameStayedRegistered = roomErrorOf(error)?.code === ROOM_EXISTS;
			}
			assert(nameStayedRegistered, "a refused cold subscription released the managed room's registration");
			const recovered = await Room.subscribe(
				directory.session,
				await directory.enter("cold-rollback"),
				"recovered",
			);
			await recovered.leave();
		} finally {
			await directory.close();
		}
	});
});

roomsTest("an iroh room sturdyref enlivens directly into its room capability", async () => {
	if (!(await irohUsable())) return;
	await withIrohServer(async (uri) => {
		const owner = await Directory.connect(uri, (address) => dial(address));
		const managed = await owner.openManaged("linked");
		const ownerRoom = await Room.subscribe(owner.session, managed.room, "owner");
		const ownerLines = roomLines(ownerRoom);
		const link = managed.roomLink;

		const joinerSession = await dial(uri);
		joinerSession.serve().catch(() => {});
		const joinerRoom = await Room.subscribe(
			joinerSession,
			await joinerSession.enliven(link),
			"joiner",
		);
		await waitForLine(roomLines(joinerRoom), /^room: .+ are in the room\.$/);
		// The welcome only says the link handed back a room. This says it handed
		// back *this* one: a redemption that reached a fresh room of the same name
		// would welcome the joiner just as warmly and never reach the owner.
		await waitForLine(ownerLines, /^room: joiner joined \(2 here\)$/);

		await joinerRoom.leave();
		joinerSession.close();
		await joinerSession.serve().catch(() => {});
		await ownerRoom.leave();
		await owner.close();
	});
});

roomsTest("rooms server over iroh answers a subscriber dialing its ocapn:// URI", async () => {
	if (!(await irohUsable())) return; // needs `zig build iroh-abi` (cargo)
	await withIrohServer(async (uri) => {
		assertMatch(uri, /^ocapn:\/\/[0-9a-f]+\.iroh/);
		assertRoster(
			await subscribeOnceIroh(uri, "general", "iroh-first"),
			["iroh-first"],
		);
		// A name freed by a clean close is grantable again to the next dialer.
		await waitForRoster(
			() => subscribeOnceIroh(uri, "general", "iroh-second"),
			["iroh-second"],
		);
	});
});

roomsTest(
	"rooms server over iroh broadcasts joins and leaves through the capability callback",
	async () => {
		if (!(await irohUsable())) return; // needs `zig build iroh-abi` (cargo)
		await withIrohServer(async (uri) => {
			const watcher = await watchRoomIroh(uri, "general", "iroh-watcher");
			const leaver = await watchRoomIroh(uri, "general", "iroh-leaver");
			await waitForLine(watcher.lines, /^room: iroh-leaver joined \(2 here\)$/);

			await leaver.leave();

			await waitForLine(watcher.lines, /^room: iroh-leaver left \(1 here\)$/);
			await watcher.leave();
		});
	},
);

roomsTest("a second server on one port stops rather than sharing it", async () => {
	// A pancake listener asks for a reusable address, so two servers can hold one
	// address with neither being told: both announce, and the kernel gives each
	// arriving connection to whichever it likes. Two members then join the same
	// room name at the same address and never see each other, and nothing
	// anywhere says why. Refusing is the only honest answer, so it is checked
	// against a real one already listening rather than against a bind in
	// isolation.
	const port = freePort();
	const first = spawnOwned("deno", {
		args: [...DENO_FLAGS, SERVER, String(port)],
		cwd: ROOT,
		env: ephemeralRoomsEnv(),
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await readPort(first);
		const second = spawnOwned("deno", {
			args: [...DENO_FLAGS, SERVER, String(port)],
			cwd: ROOT,
			env: ephemeralRoomsEnv(),
			stdout: "piped",
			stderr: "piped",
		});
		const [status, said] = await Promise.all([
			second.status,
			new Response(second.stderr).text(),
			new Response(second.stdout).text(),
		]);
		assert(!status.success, `the second server exited ${status.code} instead of refusing the port`);
		assertMatch(said, /already in use/);
		assertMatch(said, new RegExp(String(port)));
	} finally {
		await stopOwned(first);
	}
});

roomsTest("a server that cannot start says so and exits saying so", async () => {
	// The backstop that keeps one stray notify from taking CapTP down was
	// catching startup too: a state file it could not read printed a stack trace,
	// left the process running with nothing listening, and exited 0. A supervisor
	// reading that exit code is told the server ran and stopped cleanly, which is
	// the worst of the three things that could be said.
	const dir = await Deno.makeTempDir();
	try {
		await Deno.writeTextFile(
			`${dir}/rooms.json`,
			JSON.stringify({ version: 1, identitySeed: "zz", roomLinkSecret: "zz", linkedRooms: [] }) + "\n",
		);
		const proc = spawnOwned("deno", {
			// Its own write grant, because reading the state file is the point and
			// the ordinary server child is given none.
			args: [...DENO_FLAGS, `--allow-write=${dir}`, SERVER, "0"],
			cwd: ROOT,
			env: { PANCAKE_ROOMS_STATE: dir },
			stdout: "piped",
			stderr: "piped",
		});
		const [status, said, out] = await Promise.all([
			proc.status,
			new Response(proc.stderr).text(),
			new Response(proc.stdout).text(),
		]);
		assert(!status.success, `a server with an unreadable state file exited ${status.code}`);
		assert(
			!out.includes("ROOMS-SERVER-LISTENING"),
			"a server that could not read its state announced itself as listening",
		);
		// Said as a sentence, and naming the file, because that file is the one
		// input here a person can repair by hand.
		assertMatch(said, /rooms: could not start: /);
		assertMatch(said, /rooms\.json/);
		assert(!said.includes("at parseState"), `the operator was handed a stack trace instead of a sentence: ${said}`);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});

roomsTest("the server creates a nested state path before publishing capabilities", async () => {
	const parent = await Deno.makeTempDir({ prefix: "pancake-rooms-state-parent-" });
	const state = `${parent}/nested/rooms-state`;
	const proc = spawnOwned("deno", {
		args: [...DENO_FLAGS, `--allow-write=${state}`, SERVER, "0", "--viz"],
		cwd: ROOT,
		env: {
			PANCAKE_ROOMS_STATE: state,
			PANCAKE_ROOMS_VIZ_PORT: "0",
		},
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await readPort(proc);
		assert((await Deno.stat(`${state}/rooms.json`)).isFile, "the server did not create its state document");
		assert((await Deno.stat(`${state}/viz`)).isFile, "capability publication ran before state path creation");
	} finally {
		await stopOwned(proc);
		await Deno.remove(parent, { recursive: true });
	}
});

roomsTest("a torn operator capability file refuses startup instead of reminting authority", async () => {
	const dir = await Deno.makeTempDir();
	try {
		await RoomServerState.open(dir);
		await Deno.writeTextFile(`${dir}/operator`, "partial-swiss\n");
		const proc = spawnOwned("deno", {
			args: [...DENO_FLAGS, `--allow-write=${dir}`, SERVER, "0", "--operator"],
			cwd: ROOT,
			env: { PANCAKE_ROOMS_STATE: dir },
			stdout: "piped",
			stderr: "piped",
		});
		const [status, said, out] = await Promise.all([
			proc.status,
			new Response(proc.stderr).text(),
			new Response(proc.stdout).text(),
		]);
		assert(!status.success, "a server with a torn operator swiss started");
		assert(!out.includes("ROOMS-SERVER-LISTENING"), "a server that reminted authority announced itself");
		assert(said.includes("operator state is not a complete swiss number"), `the refusal was: ${said}`);
		assert(
			(await Deno.readTextFile(`${dir}/operator`)).trim() === "partial-swiss",
			"startup rewrote corrupt authority",
		);
	} finally {
		await Deno.remove(dir, { recursive: true });
	}
});
