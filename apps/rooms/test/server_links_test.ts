// Durable names, restarts, and the ways a server says it cannot start.
//
// A sturdyref has to mean the same room after the process that minted it is
// gone, which is the one claim here that a single run cannot make on its own —
// so these start servers, stop them, and start them again.

import { impossibleStatus, ROOM_LINKS_FULL, RoomError } from "../lib/errors.ts";
import { MAX_ROOM_LINKS } from "../lib/limits.ts";
import { loopbackTcpDesignator } from "../lib/locator.ts";
import { DIRECTORY, SNAPSHOT, SUBSCRIBE } from "../lib/protocol.ts";
import {
	Directory,
	Room,
	roomCalledAs,
	roomIsPrivate,
	snapshotDiagnostics,
	takeDiagnostics,
} from "../lib/room_client.ts";
import { RoomServerState } from "../server/state.ts";
import {
	assert,
	assertMatch,
	DENO_FLAGS,
	dial,
	enterOrOpen,
	freeServerPort,
	irohUsable,
	readPort,
	restartStatefulServer,
	roomLines,
	roomsTest,
	ROOT,
	SERVER,
	stablePort,
	startStatefulServer,
	stopServer,
	subscribeOnceIroh,
	until,
	waitForLine,
	waitForMatch,
	watchRoomIroh,
	withIrohServer,
	withServer,
} from "./support/rooms_server.ts";
import { DURABLE_SWISS_ENTROPY_BYTES } from "@pancake/runtime";
import { spawnOwned, stopOwned } from "./support/children.ts";

async function untilListed(room: Room): Promise<void> {
	await until(
		() => room.listed !== undefined,
		"subscribe did not say whether the occupancy is listed",
	);
}

roomsTest("a private room mints a link that reaches it, and nothing else does", async () => {
	// The capability answer to inviting somebody: a durable authority asked for
	// with the reference, handed over as data. It is the same mint a public room
	// makes — keyed by the room's own unguessable name rather than by a label
	// two rooms may share — and it survives the server that made it.
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-private-" });
	// A stable locator across the restart needs one number for the whole
	// scenario, and a learned ephemeral one is any concurrent test step's to
	// take during the restart gap; `stablePort` sits below that range.
	const port = stablePort();
	let server = startStatefulServer(port, stateDirectory);
	try {
		await readPort(server);
		const locator = loopbackTcpDesignator(port);
		const dir = await Directory.connect(locator, (address) => dial(address));
		const room = await Room.subscribe(dir.session, await dir.open("plans", true), "ada");
		const link = await room.link(locator);
		assert((await room.called()) === "plans", "a live private room did not say what it is called");
		assert((await room.isPrivate()) === true, "a live private room did not say it is unlisted");
		// The label is not in the link and the link is not reachable by label:
		// asking the directory for one by that name finds nothing, because a
		// private room is not in the table names are looked up in.
		let byName = "";
		try {
			await dir.link("plans", locator);
		} catch (err) {
			byName = err instanceof Error ? err.message : String(err);
		}
		assertMatch(byName, /no room named "plans"/);

		// Somebody else, holding the string and nothing else, is in the room.
		const guest = await Directory.connect(locator, (address) => dial(address));
		const guestRef = await guest.session.enliven(link);
		assert(
			(await roomCalledAs(guest.session, guestRef)) === "plans",
			"enlivening a live private room's link did not say what the room is called",
		);
		const asGuest = await Room.subscribe(guest.session, guestRef, "bo");
		await untilListed(asGuest);
		assert(asGuest.listed === false, "a private room's welcome did not say it is unlisted");
		await asGuest.say("here by the link alone");
		await room.leave();
		await asGuest.leave();
		await dir.close();
		await guest.close();

		// And it outlives the process that minted it, which is what makes it a
		// way back rather than a way in for the moment.
		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory);
		const later = await Directory.connect(locator, (address) => dial(address));
		const again = await Room.subscribe(later.session, await later.session.enliven(link), "ada");
		await again.say("still here");
		await again.leave();
		await later.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("a public room's link is that listed room", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const owner = await Directory.connect(locator, (address) => dial(address));
		const guest = await Directory.connect(locator, (address) => dial(address));
		try {
			const room = await Room.subscribe(owner.session, await owner.open("general"), "ada");
			const link = await room.link(locator);
			const other = await Room.subscribe(guest.session, await guest.open("foo"), "cy");
			const guestRef = await guest.session.enliven(link);
			assert(
				(await roomCalledAs(guest.session, guestRef)) === "general",
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
		const firstEntropy = bytes(await first.entropyFor("General"));
		await first.remember("General");

		const restored = await RoomServerState.open(directory);
		assert(
			[...restored.identitySeed].join(",") === [...first.identitySeed].join(","),
			"the room Host identity changed across state restore",
		);
		assert(
			bytes(await restored.entropyFor("general")) === firstEntropy,
			"the same case-insensitive room did not restore the same swiss authority",
		);
		assert(
			bytes(await restored.entropyFor("elsewhere")) !== firstEntropy,
			"one room link granted a different room",
		);
		assert(
			(await restored.entropyFor("General")).length === DURABLE_SWISS_ENTROPY_BYTES,
			"a room's derived entropy is not the width the Host mints from",
		);
		assert(
			restored.linkedRooms().join(",") === "General",
			"the explicitly linked room was not restored",
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
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

roomsTest("a room sturdyref reaches the same room publication after server restart", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-links-" });
	// One stable number for the whole scenario, as above.
	const port = stablePort();
	let link = "";
	let first = startStatefulServer(port, stateDirectory);
	try {
		await readPort(first);
		const locator = loopbackTcpDesignator(port);
		const dir = await Directory.connect(locator, (address) => dial(address));
		const room = await Room.subscribe(dir.session, await dir.open("kept"), "before");
		link = await dir.link("kept", locator);
		await room.leave();
		await dir.close();
		await stopServer(first);

		first = await restartStatefulServer(port, stateDirectory);
		const after = await Directory.connect(locator, (address) => dial(address));
		// Redeem the link itself rather than picking it apart. A holder of a room
		// link has the string and nothing else, so enlivening it is the act under
		// test; reading the swiss out and fetching it by name would prove the
		// server published something, not that the link reaches it.
		const roomAfter = await Room.subscribe(after.session, await after.session.enliven(link), "after");
		assert(
			await after.link("kept", locator) === link,
			"the server returned a different sturdyref after restoring its state",
		);
		await roomAfter.say("the link still reaches the room");
		await roomAfter.leave();
		await after.close();
	} finally {
		await stopServer(first);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("a refused first subscription leaves no cold linked room behind", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const directory = await Directory.connect(locator, (address) => dial(address));
		try {
			const room = await Room.subscribe(directory.session, await directory.open("cold-rollback"), "maker");
			const link = await room.link(locator);
			await room.leave();

			const cold = await directory.session.enliven(link);
			let refused = "";
			await directory.session.send(cold, SUBSCRIBE, ["broken", null]).catch((error) => {
				refused = error instanceof Error ? error.message : String(error);
			});
			assertMatch(refused, /subscribe needs an inbox capability/);

			// The failed first call did not commit the reconstructed room. Its
			// public name is free again, and a valid open can take it immediately.
			const recovered = await Room.subscribe(
				directory.session,
				await directory.open("cold-rollback"),
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
		const ownerRoom = await Room.subscribe(owner.session, await owner.open("linked"), "owner");
		const ownerLines = roomLines(ownerRoom);
		const link = await owner.link("linked", uri);

		const joinerSession = await dial(uri);
		joinerSession.serve().catch(() => {});
		const joinerRoom = await Room.subscribe(
			joinerSession,
			await joinerSession.enliven(link),
			"joiner",
		);
		await waitForLine(roomLines(joinerRoom), /^room: in the room:/);
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
		assertMatch(
			await subscribeOnceIroh(uri, "general", "iroh-first"),
			/^in the room: iroh-first$/,
		);
		// A name freed by a clean close is grantable again to the next dialer.
		await waitForMatch(
			() => subscribeOnceIroh(uri, "general", "iroh-second"),
			/^in the room: iroh-second$/,
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
	const port = freeServerPort();
	const first = spawnOwned("deno", {
		args: [...DENO_FLAGS, SERVER, String(port)],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
	try {
		await readPort(first);
		const second = spawnOwned("deno", {
			args: [...DENO_FLAGS, SERVER, String(port)],
			cwd: ROOT,
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

Deno.test("a status no version defines is read as a mismatched library, not as iroh", () => {
	// The shape of the real incident: a container mounting shared libraries built
	// from one revision and source from another. The call returns whatever was in
	// the register, the binding reads it as a status, and the number sends an
	// operator looking at the network, at iroh, and at their own configuration —
	// none of which is the problem. Every pancake status is a small negative
	// integer, so this is decidable rather than a guess.
	const said = (code: number) => impossibleStatus(code);
	assert(said(2_144_786_400), "a huge positive status was taken for a real one");
	assert(said(-1_643_128_864), "a huge negative status was taken for a real one");
	assert(!said(-2), "invalid-argument is a status this version defines");
	assert(!said(-15), "timed-out is a status this version defines");
	assert(!said(0), "ok is a status this version defines");
});

roomsTest("inspect is a fetched capability, not a directory method", async () => {
	const stateDir = await Deno.makeTempDir();
	const spawn = () =>
		spawnOwned("deno", {
			args: [...DENO_FLAGS, "--allow-write", SERVER, "0"],
			cwd: ROOT,
			env: {
				...Deno.env.toObject(),
				PANCAKE_ROOMS_DIAGNOSTICS: "1",
				PANCAKE_ROOMS_STATE: stateDir,
			},
			stdout: "piped",
			stderr: "piped",
		});
	try {
		const proc = spawn();
		let swiss = "";
		try {
			const port = await readPort(proc);
			swiss = (await Deno.readTextFile(`${stateDir}/diagnostics`)).trim();
			assert(swiss.length > 0, "the server did not write an inspect swiss");
			const session = await dial(loopbackTcpDesignator(port));
			session.serve().catch(() => {});
			const taken = await takeDiagnostics(session, swiss);
			assert(
				taken.rows.some((row) => row.kind === "directory" && row.name === DIRECTORY),
				`inspect did not name the directory: ${JSON.stringify(taken.rows)}`,
			);
			await Room.subscribe(session, await enterOrOpen(session, "inspected"), "inspector");
			const again = await snapshotDiagnostics(session, taken.cap);
			assert(
				again.some((row) => row.kind === "room" && row.name === "inspected"),
				`inspect did not name the live room: ${JSON.stringify(again)}`,
			);
			assert(
				again.some((row) => row.kind === "occupant" && row.name === "inspector"),
				`inspect did not name the occupant: ${JSON.stringify(again)}`,
			);
			let unknown = "";
			try {
				await session.fetch("not-the-inspect-swiss");
			} catch (err) {
				unknown = err instanceof Error ? err.message : String(err);
			}
			assert(unknown !== "", "fetching a swiss nothing published succeeded");
			let directorySnapshot = "";
			try {
				await session.send(await session.fetch(DIRECTORY), SNAPSHOT, []);
			} catch (err) {
				directorySnapshot = err instanceof Error ? err.message : String(err);
			}
			assert(
				directorySnapshot !== "",
				"the directory answered snapshot, so inspect is not a separate capability",
			);
		} finally {
			await stopOwned(proc);
		}
		const againProc = spawn();
		try {
			const againPort = await readPort(againProc);
			const reused = (await Deno.readTextFile(`${stateDir}/diagnostics`)).trim();
			assert(
				reused === swiss,
				"a respawn reminted the inspect swiss the operator already copied",
			);
			const againSession = await dial(loopbackTcpDesignator(againPort));
			againSession.serve().catch(() => {});
			const takenAgain = await takeDiagnostics(againSession, swiss);
			assert(
				takenAgain.rows.some((row) => row.kind === "directory" && row.name === DIRECTORY),
				`the reused swiss did not fetch inspect: ${JSON.stringify(takenAgain.rows)}`,
			);
		} finally {
			await stopOwned(againProc);
		}
	} finally {
		await Deno.remove(stateDir, { recursive: true });
	}
});

roomsTest("a directory started without diagnostics does not publish inspect", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		let unknown = "";
		try {
			await session.fetch("0".repeat(64));
		} catch (err) {
			unknown = err instanceof Error ? err.message : String(err);
		}
		assert(unknown !== "", "an unpublished inspect swiss fetched on a default server");
		let directorySnapshot = "";
		try {
			await session.send(await session.fetch(DIRECTORY), SNAPSHOT, []);
		} catch (err) {
			directorySnapshot = err instanceof Error ? err.message : String(err);
		}
		assert(
			directorySnapshot !== "",
			"the directory answered snapshot without an inspect capability",
		);
	});
});
