// The separately published directory diagnostics capability and its failures.

import { DURABLE_SWISS_ENTROPY_BYTES, type Ref, type Session } from "@glowcap/runtime";
import { impossibleStatus } from "../../lib/errors.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { DIRECTORY, SNAPSHOT } from "../../lib/protocol.ts";
import { Directory, Room, snapshotDiagnostics, takeDiagnostics } from "../../lib/room/client.ts";
import { PRIVATE_ROOM_POLICY } from "../../lib/room/policy.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import {
	assert,
	DENO_FLAGS,
	dial,
	enterOrOpen,
	readPort,
	roomsTest,
	ROOT,
	SERVER,
	withServer,
} from "../support/rooms_server.ts";

Deno.test("a status no version defines is read as a mismatched library, not as iroh", () => {
	const said = (code: number) => impossibleStatus(code);
	assert(said(2_144_786_400), "a huge positive status was taken for a real one");
	assert(said(-1_643_128_864), "a huge negative status was taken for a real one");
	assert(!said(-2), "invalid-argument is a status this version defines");
	assert(!said(-15), "timed-out is a status this version defines");
	assert(!said(0), "ok is a status this version defines");
});

Deno.test("inspect rejects malformed rows instead of turning them into an empty view", async () => {
	for (const answer of [["room", "harbor"], ["room", "harbor", "live", "surplus"], ["", "harbor", "live"]]) {
		const session = { send: () => Promise.resolve([answer]) } as unknown as Session;
		let refused = "";
		try {
			await snapshotDiagnostics(session, {} as Ref);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assert(refused.includes("invalid row"), `malformed inspect row was accepted or refused unclearly: ${refused}`);
	}
});

roomsTest("inspect is a fetched capability, not a directory method", async () => {
	const stateDir = await Deno.makeTempDir();
	const spawn = () =>
		spawnOwned("deno", {
			args: [...DENO_FLAGS, "--allow-write", SERVER, "0"],
			cwd: ROOT,
			env: {
				...Deno.env.toObject(),
				GLOWCAP_ROOMS_DIAGNOSTICS: "1",
				GLOWCAP_ROOMS_STATE: stateDir,
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

			const privateDirectory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
			const managedPrivate = await privateDirectory.openManaged("quiet-corner", {
				policy: PRIVATE_ROOM_POLICY,
			});
			const privateMember = await Room.subscribe(privateDirectory.session, managedPrivate.room, "whisper");
			const withPrivate = await snapshotDiagnostics(session, taken.cap);
			const privateRow = withPrivate.find((row) => row.kind === "room" && row.name === "quiet-corner");
			assert(privateRow !== undefined, `inspect hid the operator's private room: ${JSON.stringify(withPrivate)}`);
			assert(
				privateRow.note.includes("private"),
				`inspect did not mark the private room private: ${privateRow.note}`,
			);
			assert(
				withPrivate.some((row) => row.kind === "occupant" && row.name === "whisper"),
				`inspect did not name the private-room occupant: ${JSON.stringify(withPrivate)}`,
			);
			const linkRow = withPrivate.find((row) => row.kind === "link");
			assert(linkRow !== undefined, `inspect listed no room link: ${JSON.stringify(withPrivate)}`);
			assert(
				linkRow.note.endsWith("durable publication active"),
				`inspect misstated room-link authority: ${JSON.stringify(linkRow)}`,
			);
			// Neither half of the row is authority. The name is what a reader
			// calls the room and the note is what the directory says about it;
			// the swiss that would enter it is never in either.
			for (const field of [linkRow.name, linkRow.note]) {
				let refused = "";
				try {
					await session.fetch(field);
				} catch (error) {
					refused = error instanceof Error ? error.message : String(error);
				}
				assert(refused !== "", `a diagnostic link field redeemed as room authority: ${field}`);
			}
			// Every room this server could grant moderation over is reported,
			// issued or not, and never with the capability itself.
			const moderator = withPrivate.filter((row) => row.kind === "moderator");
			assert(moderator.length > 0, `inspect reported no moderator authority: ${JSON.stringify(withPrivate)}`);
			for (const row of moderator) {
				assert(
					row.note === "moderator capability issued" || row.note === "no moderator capability issued",
					`inspect misstated moderator authority: ${JSON.stringify(row)}`,
				);
				let refusedModerator = "";
				try {
					await session.fetch(row.name);
				} catch (error) {
					refusedModerator = error instanceof Error ? error.message : String(error);
				}
				assert(refusedModerator !== "", `a moderator row redeemed as authority: ${row.name}`);
			}
			await privateMember.leave();
			await privateDirectory.close();
			let unknown = "";
			try {
				await session.fetch("not-the-inspect-swiss");
			} catch (error) {
				unknown = error instanceof Error ? error.message : String(error);
			}
			assert(unknown !== "", "fetching a swiss nothing published succeeded");
			let directorySnapshot = "";
			try {
				await session.send(await session.fetch(DIRECTORY), SNAPSHOT, []);
			} catch (error) {
				directorySnapshot = error instanceof Error ? error.message : String(error);
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
			assert(reused === swiss, "a respawn reminted the inspect swiss the operator already copied");
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
			await session.fetch("0".repeat(DURABLE_SWISS_ENTROPY_BYTES * 4));
		} catch (error) {
			unknown = error instanceof Error ? error.message : String(error);
		}
		assert(unknown !== "", "an unpublished inspect swiss fetched on a default server");
		let directorySnapshot = "";
		try {
			await session.send(await session.fetch(DIRECTORY), SNAPSHOT, []);
		} catch (error) {
			directorySnapshot = error instanceof Error ? error.message : String(error);
		}
		assert(directorySnapshot !== "", "the directory answered snapshot without an inspect capability");
	});
});
