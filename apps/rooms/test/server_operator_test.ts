// Server-wide stewardship operation: recovery and true revocation of room
// moderation capabilities, including references already enlivened by a holder.

import type { Argument } from "@pancake/runtime";
import { loopbackTcpDesignator, roomsSturdyrefForSession } from "../lib/locator.ts";
import { Directory } from "../lib/directory.ts";
import { Room } from "../lib/room_client.ts";
import {
	giveStewardship,
	operatorPage,
	operatorPageAnswer,
	operatorRetireMatching,
	parseOperatorPageAnswer,
	removeOperatorRoom,
	resetOperatorScope,
	revokeRoomLink,
	revokeStewardship,
	snapshotOperator,
	takeRoomsOperator,
} from "../lib/operator.ts";
import { CALLED, GIVE_STEWARD, GOVERNS, KICK } from "../lib/protocol.ts";
import { NOT_STEWARD, roomErrorOf } from "../lib/errors.ts";
import { operationsSwiss } from "../lib/operations.ts";
import {
	assert,
	dial,
	nextMessage,
	readPort,
	restartStatefulServer,
	roomsTest,
	stablePort,
	startStatefulServer,
	stopServer,
	within,
} from "./support/rooms_server.ts";

roomsTest("an operations swiss is scoped by the live directory, never retargeted from a sturdyref", () => {
	assert(operationsSwiss("  operator-swiss  ") === "operator-swiss", "the bare swiss was not trimmed");
	let refused = "";
	try {
		operationsSwiss("ocapn://elsewhere.example/s/operator-swiss");
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assert(refused.includes("bare swiss"), `a sturdyref was accepted or refused unclearly: ${refused}`);
});

roomsTest("the Rooms operator recovers and revokes stewardship across live references and restart", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-operator-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory, ["--operator"]);
	let oldStewardLink = "";
	let newStewardLink = "";
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		assert(operatorSwiss !== "", "the operator swiss was not persisted");

		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		const owner = await Room.subscribe(ownerDir.session, await ownerDir.open("harbor"), "keeper");
		assert(await owner.claimSteward(), "the opener was not issued stewardship");
		oldStewardLink = owner.stewardLink ?? "";
		assert(oldStewardLink !== "", "the opener did not retain the steward sturdyref");

		const operatorSession = await dial(locator);
		const taken = await takeRoomsOperator(operatorSession, operatorSwiss);
		const malformed: Array<[string, Argument[]]> = [[GIVE_STEWARD, ["harbor", "surplus"]]];
		for (const [verb, args] of malformed) {
			let accepted = true;
			try {
				await within(operatorSession.send(taken.cap, verb, args), `operator ${verb} with trailing arguments`);
			} catch {
				accepted = false;
			}
			assert(!accepted, `operator ${verb} accepted trailing arguments`);
		}
		const initial = taken.snapshot.stewardships.find((row) => row.name.toLowerCase() === "harbor");
		assert(initial?.issued === true, "the operator did not inventory the issued stewardship");
		assert(initial.steward !== null, "the issued operator row carried no steward sturdyref");
		const recovered = await giveStewardship(operatorSession, taken.cap, "HARBOR");
		assert(recovered.steward === initial.steward, "recovering stewardship minted a second generation");
		assert(recovered.generation === initial.generation, "recovering stewardship advanced an unchanged generation");

		const guestDir = await Directory.connect(locator, (address) => dial(address));
		const guest = await Room.subscribe(guestDir.session, await guestDir.enter("harbor"), "guest");
		await nextMessage(owner, (message) => message.text.includes("guest joined"));

		// Import the old authority separately before revocation. Removing a swiss
		// from a publication index cannot reach this live reference; the behavior's
		// generation check is what must make it stop.
		const alreadyLive = await operatorSession.enliven(roomsSturdyrefForSession(oldStewardLink, operatorSession));
		await within(operatorSession.send(alreadyLive, GOVERNS, []), "the old steward governing before revoke");
		const revoked = await revokeStewardship(operatorSession, taken.cap, "harbor");
		assert(!revoked.issued && revoked.steward === null, "revoke did not leave an unissued operator row");
		assert(revoked.generation > initial.generation, "revoke did not advance the operator row revision");

		let revokedCode: string | null = null;
		try {
			await within(operatorSession.send(alreadyLive, GOVERNS, []), "the live old steward refusing");
		} catch (error) {
			revokedCode = roomErrorOf(error)?.code ?? null;
		}
		assert(revokedCode === NOT_STEWARD, `an already-live revoked steward failed as ${revokedCode}`);
		let kickCode: string | null = null;
		try {
			await owner.kick("guest");
		} catch (error) {
			kickCode = roomErrorOf(error)?.code ?? null;
		}
		assert(kickCode === NOT_STEWARD, `the room client's revoked steward kicked or failed as ${kickCode}`);

		const granted = await giveStewardship(operatorSession, taken.cap, "harbor");
		assert(granted.steward !== null, "give did not issue a replacement steward");
		assert(granted.generation > revoked.generation, "reissue did not advance the operator row revision");
		newStewardLink = granted.steward;
		assert(newStewardLink !== oldStewardLink, "give reused the revoked generation's sturdyref");
		const replacement = await operatorSession.enliven(roomsSturdyrefForSession(newStewardLink, operatorSession));
		await within(operatorSession.send(replacement, GOVERNS, []), "the replacement steward governing");
		await within(operatorSession.send(replacement, KICK, ["guest"]), "the replacement steward kicking");
		await nextMessage(guest, (message) => message.text.includes("you were asked to leave"));

		await owner.leave();
		await ownerDir.close();
		await guestDir.close();
		await operatorSession.close();
		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory, ["--operator"]);

		const after = await dial(locator);
		const operatorAfter = await takeRoomsOperator(after, operatorSwiss);
		const rows = (await snapshotOperator(after, operatorAfter.cap)).stewardships;
		assert(rows.find((row) => row.name === "harbor")?.issued === true, "restart lost the replacement steward");
		const replacementAfter = await after.enliven(roomsSturdyrefForSession(newStewardLink, after));
		await within(after.send(replacementAfter, GOVERNS, []), "the replacement steward after restart");
		let oldStillWorks = true;
		try {
			const oldAfter = await after.enliven(roomsSturdyrefForSession(oldStewardLink, after));
			await within(after.send(oldAfter, GOVERNS, []), "the revoked steward after restart");
		} catch {
			oldStillWorks = false;
		}
		assert(!oldStillWorks, "the revoked sturdyref governed again after restart");
		await after.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the operator covers private rooms by opaque durable name, never by their label", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-private-operator-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory, ["--operator"]);
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const directory = await Directory.connect(locator, (address) => dial(address));
		const room = await Room.subscribe(directory.session, await directory.openPrivate("plans"), "keeper");
		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		const privateRow = operator.snapshot.stewardships.find((row) =>
			row.visibility === "private" && row.label === "plans"
		);
		assert(privateRow !== undefined, "the live private room was absent from the operator inventory");
		assert(
			/^~[0-9a-f]{32}$/.test(privateRow.name),
			"the private room was operated by its label, not an opaque name",
		);
		const issued = await giveStewardship(operatorSession, operator.cap, privateRow.name);
		assert(issued.steward !== null, "the operator did not issue private-room stewardship");

		await room.leave();
		await directory.close();
		await operatorSession.close();
		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory, ["--operator"]);

		const after = await dial(locator);
		const restored = await takeRoomsOperator(after, operatorSwiss);
		const restoredRow = restored.snapshot.stewardships.find((row) => row.name === privateRow.name);
		assert(restoredRow?.visibility === "private", "restart lost the private stewardship scope");
		assert(restoredRow.label === "", "durable state retained a private room's human label");
		await revokeStewardship(after, restored.cap, privateRow.name);
		await after.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the Rooms operator permanently revokes a room link", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-operator-link-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory, ["--operator"]);
	let roomLink = "";
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		const owner = await Room.subscribe(ownerDir.session, await ownerDir.open("linked"), "keeper");
		roomLink = await owner.link();

		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		assert(
			operator.snapshot.links.some((row) => row.name === "linked"),
			"the operator did not inventory the room link",
		);
		const alreadyLive = await operatorSession.enliven(roomsSturdyrefForSession(roomLink, operatorSession));
		await within(operatorSession.send(alreadyLive, CALLED, []), "the room link before revocation");
		await revokeRoomLink(operatorSession, operator.cap, "linked");
		let liveRefused = false;
		try {
			await within(operatorSession.send(alreadyLive, CALLED, []), "the live revoked room link refusing");
		} catch {
			liveRefused = true;
		}
		assert(liveRefused, "an already-enlivened room link survived operator revocation");
		await owner.leave();
		await ownerDir.close();
		await operatorSession.close();
		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory, ["--operator"]);

		const after = await dial(locator);
		let restored = true;
		try {
			await after.enliven(roomsSturdyrefForSession(roomLink, after));
		} catch {
			restored = false;
		}
		assert(!restored, "restart republished the revoked room link");
		await after.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the Rooms operator removes exact room owners and resets all directory authority", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-operator-reset-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	const server = startStatefulServer(port, stateDirectory, ["--operator"]);
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		const first = await Room.subscribe(ownerDir.session, await ownerDir.open("replaceable"), "keeper");
		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		const firstRow = operator.snapshot.rooms.find((row) => row.name === "replaceable");
		assert(firstRow?.kind === "local", "the operator did not inventory the local room owner");
		assert((firstRow.retainedCapabilities ?? 0) >= 2, "the room did not report its retained member capabilities");

		await removeOperatorRoom(operatorSession, operator.cap, firstRow.id);
		let removedRefused = false;
		try {
			await first.say("after operator removal");
		} catch {
			removedRefused = true;
		}
		assert(removedRefused, "a removed local room still accepted its old membership");

		const replacement = await Room.subscribe(ownerDir.session, await ownerDir.open("replaceable"), "keeper");
		let staleRemoved = true;
		try {
			await removeOperatorRoom(operatorSession, operator.cap, firstRow.id);
		} catch {
			staleRemoved = false;
		}
		assert(!staleRemoved, "a stale room id removed its replacement generation");
		await replacement.say("replacement still live");
		const replacementLink = await replacement.link();

		await resetOperatorScope(operatorSession, operator.cap, "all");
		const after = await snapshotOperator(operatorSession, operator.cap);
		assert(after.rooms.length === 0, "the full reset left a room owner");
		assert(after.links.length === 0, "the full reset left a durable room link");
		assert(after.registrations.length === 0, "the full reset left a nickname claim");
		assert(after.sessions.length === 0, "the full reset left a peer session");
		assert(after.trouble.length === 0, "the full reset left acknowledged trouble");
		let linkSurvived = true;
		try {
			await operatorSession.enliven(roomsSturdyrefForSession(replacementLink, operatorSession));
		} catch {
			linkSurvived = false;
		}
		assert(!linkSurvived, "the full reset left the durable room authority redeemable");
		const reissuerDir = await Directory.connect(locator, (address) => dial(address));
		const reissuedRoom = await Room.subscribe(
			reissuerDir.session,
			await reissuerDir.open("replaceable"),
			"new-keeper",
		);
		const reissuedLink = await reissuedRoom.link();
		assert(reissuedLink !== replacementLink, "factory reset reused the retired room authority");
		await operatorSession.enliven(roomsSturdyrefForSession(reissuedLink, operatorSession));
		await reissuedRoom.leave();
		await reissuerDir.close();
		await operatorSession.close();
		await ownerDir.close().catch(() => {});
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the Rooms operator pages bounded inventory under one revision", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-operator-page-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	const server = startStatefulServer(port, stateDirectory, ["--operator"]);
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		for (let at = 0; at < 34; at += 1) {
			await Room.subscribe(ownerDir.session, await ownerDir.open(`page-${at}`), "keeper");
		}
		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		assert(operator.snapshot.rooms.length === 32, "the initial room inventory exceeded its page bound");
		assert(operator.snapshot.next.rooms === 32, "the initial room inventory lost its next cursor");
		const second = await operatorPage(operatorSession, operator.cap, "rooms", 32);
		assert(second.rows.length === 2 && second.next === null, "the second room page did not finish the inventory");
		assert(second.revision === operator.snapshot.revision, "an unchanged paged inventory changed revision");
		const forwarded = parseOperatorPageAnswer("rooms", operatorPageAnswer(second));
		assert(
			forwarded.revision === second.revision && forwarded.rows.length === second.rows.length,
			"the durable-session operator page tuple changed the validated inventory",
		);
		await Room.subscribe(ownerDir.session, await ownerDir.open("page-later"), "keeper");
		const changed = await operatorPage(operatorSession, operator.cap, "rooms");
		assert(changed.revision > second.revision, "a room-owner mutation did not advance the operator revision");
		await resetOperatorScope(operatorSession, operator.cap, "rooms");
		await operatorSession.close();
		await ownerDir.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

// The page is thirty-two rows whatever the directory holds, so a search and a
// count have to come from the directory. This is the surgical half of the
// operator at scale: forty rooms, a search that names nine of them, a count
// that says nine while the page still carries at most thirty-two, and a bulk
// retire that takes exactly those nine and leaves the rest standing.
roomsTest("the Rooms operator searches and retires past its page", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-operator-search-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	const server = startStatefulServer(port, stateDirectory, ["--operator"]);
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		for (let at = 0; at < 31; at += 1) {
			await Room.subscribe(ownerDir.session, await ownerDir.open(`keep-${at}`), "keeper");
		}
		for (let at = 0; at < 9; at += 1) {
			await Room.subscribe(ownerDir.session, await ownerDir.open(`sweep-${at}`), "keeper");
		}
		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		assert(operator.snapshot.rooms.length === 32, "the unsearched inventory exceeded its page bound");
		assert(operator.snapshot.totals.rooms === 40, "the unsearched count did not include rows past the page");

		const searched = await snapshotOperator(operatorSession, operator.cap, "sweep-");
		assert(searched.totals.rooms === 9, `a search counted ${searched.totals.rooms} rooms rather than nine`);
		assert(searched.rooms.length === 9, "a search that fits on one page did not send all of it");
		assert(
			searched.rooms.every((row) => row.name.startsWith("sweep-")),
			"a search sent rows it does not match",
		);
		assert(searched.totals.references > 0, "a room search left the reference inventory uncounted");

		const swept = await operatorRetireMatching(operatorSession, operator.cap, "rooms", "sweep-", 4);
		assert(swept.retired === 4, `a bounded retire took ${swept.retired} rows rather than its batch of four`);
		assert(swept.remaining === 5, `a bounded retire left ${swept.remaining} rows rather than five`);
		const rest = await operatorRetireMatching(operatorSession, operator.cap, "rooms", "sweep-", 256);
		assert(rest.retired === 5 && rest.remaining === 0, "a second sweep did not finish the matching rows");

		const after = await snapshotOperator(operatorSession, operator.cap);
		assert(after.totals.rooms === 31, `the sweep left ${after.totals.rooms} rooms rather than thirty-one`);
		assert(
			after.rooms.every((row) => !row.name.startsWith("sweep-")),
			"the sweep left a matching room standing",
		);
		await operatorSession.close();
		await ownerDir.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});
