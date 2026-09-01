// Server-wide stewardship operation: recovery and true revocation of room
// moderation capabilities, including references already enlivened by a holder.

import type { Argument } from "@pancake/runtime";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { Directory } from "../../lib/directory.ts";
import { Room } from "../../lib/room/client.ts";
import {
	giveRoomManager,
	giveStewardship,
	operatorPage,
	operatorPageAnswer,
	operatorRetireMatching,
	parseOperatorPageAnswer,
	removeOperatorRoom,
	resetOperatorScope,
	revokeRoomAuthority,
	revokeStewardship,
	snapshotOperator,
	takeRoomsOperator,
} from "../../lib/operator.ts";
import { CALLED, GOVERNS, KICK, NOTIFY, ROOM_AUTHORITY_CHANGED, SUBSCRIBE } from "../../lib/protocol.ts";
import { GIVE_STEWARD } from "../../lib/protocol_operator.ts";
import { NOT_STEWARD, roomErrorOf } from "../../lib/errors.ts";
import { type RoomAuthorityChange, roomAuthorityToken } from "../../lib/room/authority.ts";
import { operationsSwiss } from "../../lib/operations.ts";
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
	until,
	within,
} from "../support/rooms_server.ts";

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
		const managed = await ownerDir.openManaged("harbor");
		const owner = await Room.subscribe(ownerDir.session, managed.room, "keeper");
		await owner.takeManager(managed.managerLink);
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
		const initial = taken.snapshot.stewardships.find((row) => row.label.toLowerCase() === "harbor");
		assert(initial?.issued === true, "the operator did not inventory the issued stewardship");
		assert(initial.steward !== null, "the issued operator row carried no steward sturdyref");
		const recovered = await giveStewardship(operatorSession, taken.cap, initial.name);
		assert(recovered.steward === initial.steward, "recovering stewardship minted a second generation");
		assert(recovered.generation === initial.generation, "recovering stewardship advanced an unchanged generation");

		const guestDir = await Directory.connect(locator, (address) => dial(address));
		const guest = await Room.subscribe(guestDir.session, await guestDir.enter("harbor"), "guest");
		await nextMessage(owner, (message) => message.text.includes("guest joined"));
		const baselineDir = await Directory.connect(locator, (address) => dial(address));
		const baselineNotices: Argument[][] = [];
		const baselineInbox = baselineDir.session.spawn((verb, args) => {
			if (verb !== NOTIFY) throw new Error(`baseline room inbox has no method ${verb}`);
			baselineNotices.push(args);
			return null;
		});
		await baselineDir.session.send(await baselineDir.enter("harbor"), SUBSCRIBE, ["baseline", baselineInbox]);

		// Import the old authority separately before revocation. Removing a swiss
		// from a publication index cannot reach this live reference; the behavior's
		// generation check is what must make it stop.
		const alreadyLive = await operatorSession.enliven(oldStewardLink);
		await within(operatorSession.send(alreadyLive, GOVERNS, []), "the old steward governing before revoke");
		await revokeRoomAuthority(operatorSession, taken.cap, "steward", roomAuthorityToken(oldStewardLink));
		const revoked = (await snapshotOperator(operatorSession, taken.cap)).stewardships.find((row) =>
			row.name === initial.name
		);
		assert(revoked !== undefined, "exact moderator revocation lost its operator row");
		assert(!revoked.issued && revoked.steward === null, "revoke did not leave an unissued operator row");
		assert(revoked.generation > initial.generation, "revoke did not advance the operator row revision");
		await until(
			() => baselineNotices.some((args) => args[2] === ROOM_AUTHORITY_CHANGED),
			"authority rotation did not use the baseline notify inbox",
		);

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

		const granted = await giveStewardship(operatorSession, taken.cap, initial.name);
		assert(granted.steward !== null, "give did not issue a replacement steward");
		assert(granted.generation > revoked.generation, "reissue did not advance the operator row revision");
		newStewardLink = granted.steward;
		assert(newStewardLink !== oldStewardLink, "give reused the revoked generation's sturdyref");
		const replacement = await operatorSession.enliven(newStewardLink);
		await within(operatorSession.send(replacement, GOVERNS, []), "the replacement steward governing");
		let staleRefused = false;
		try {
			await revokeRoomAuthority(operatorSession, taken.cap, "steward", roomAuthorityToken(oldStewardLink));
		} catch {
			staleRefused = true;
		}
		assert(staleRefused, "a stale moderator token was accepted after replacement");
		await within(operatorSession.send(replacement, GOVERNS, []), "the replacement after stale moderator revoke");
		await within(operatorSession.send(replacement, KICK, ["guest"]), "the replacement steward kicking");
		for (let attempt = 0; attempt < 20 && guest.endedReason == null; attempt += 1) {
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
		assert(guest.endedReason?.includes("asked to leave") === true, "the kicked guest received no terminal reason");

		await owner.leave();
		await ownerDir.close();
		await guestDir.close();
		await baselineDir.close();
		await operatorSession.close();
		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory, ["--operator"]);

		const after = await dial(locator);
		const operatorAfter = await takeRoomsOperator(after, operatorSwiss);
		const rows = (await snapshotOperator(after, operatorAfter.cap)).stewardships;
		assert(rows.find((row) => row.name === initial.name)?.issued === true, "restart lost the replacement steward");
		const replacementAfter = await after.enliven(newStewardLink);
		await within(after.send(replacementAfter, GOVERNS, []), "the replacement steward after restart");
		let oldStillWorks = true;
		try {
			const oldAfter = await after.enliven(oldStewardLink);
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
		assert(restoredRow.label === "", "durable state invented a private room label it never retained");
		await revokeStewardship(after, restored.cap, privateRow.name);
		await after.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the Rooms operator revokes one room-link generation and the room can issue another", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-operator-link-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory, ["--operator"]);
	let roomLink = "";
	let replacementLink = "";
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		const changed = Promise.withResolvers<RoomAuthorityChange>();
		const managedRoom = await ownerDir.openManaged("linked");
		const owner = await Room.subscribe(
			ownerDir.session,
			managedRoom.room,
			"keeper",
			{ onAuthorityChanged: (_room, change) => changed.resolve(change) },
		);
		await owner.takeManager(managedRoom.managerLink);
		roomLink = managedRoom.roomLink;

		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		assert(
			operator.snapshot.links.some((row) => row.label === "linked"),
			"the operator did not inventory the room link",
		);
		const alreadyLive = await operatorSession.enliven(roomLink);
		await within(operatorSession.send(alreadyLive, CALLED, []), "the room link before revocation");
		const linkedSession = await dial(locator);
		const linkedMember = await Room.subscribe(
			linkedSession,
			await linkedSession.enliven(roomLink),
			"linked-keeper",
		);
		await linkedMember.takeManager(managedRoom.managerLink);
		await revokeRoomAuthority(operatorSession, operator.cap, "room", roomAuthorityToken(roomLink));
		const retired = await within(changed.promise, "the room-link retirement notification");
		assert(retired.kind === "room", "the room-link retirement had the wrong authority kind");
		assert(retired.token === roomAuthorityToken(roomLink), "the room-link retirement named another generation");
		assert(owner.roomLink === null, "the active membership retained the revoked room link");
		let liveRefused = false;
		try {
			await within(operatorSession.send(alreadyLive, CALLED, []), "the live revoked room link refusing");
		} catch {
			liveRefused = true;
		}
		assert(liveRefused, "an already-enlivened room link survived operator revocation");
		replacementLink = await linkedMember.link();
		assert(replacementLink !== roomLink, "room-link reissue reused the revoked sturdyref");
		await linkedMember.leave();
		await linkedSession.close();
		const replacement = await operatorSession.enliven(replacementLink);
		await within(operatorSession.send(replacement, CALLED, []), "the replacement room link");
		let staleRefused = false;
		try {
			await revokeRoomAuthority(operatorSession, operator.cap, "room", roomAuthorityToken(roomLink));
		} catch {
			staleRefused = true;
		}
		assert(staleRefused, "a stale room authority token was accepted after replacement");
		await within(operatorSession.send(replacement, CALLED, []), "the replacement after stale revocation");
		let revived = false;
		try {
			await within(operatorSession.send(alreadyLive, CALLED, []), "the old room link after reissue");
			revived = true;
		} catch {
			// The old generation stays dead after the same room name returns.
		}
		assert(!revived, "room-link reissue revived an already-enlivened old generation");
		await owner.leave();
		await ownerDir.close();
		await operatorSession.close();
		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory, ["--operator"]);

		const after = await dial(locator);
		let restored = true;
		try {
			await after.enliven(roomLink);
		} catch {
			restored = false;
		}
		assert(!restored, "restart republished the revoked room link");
		const restoredReplacement = await after.enliven(replacementLink);
		await within(after.send(restoredReplacement, CALLED, []), "the replacement room link after restart");
		await after.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the Rooms operator recovers and rotates a lost room manager across restart", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-manager-recovery-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	let server = startStatefulServer(port, stateDirectory, ["--operator"]);
	let replacementManager = "";
	let identity = "";
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		const ownerDir = await Directory.connect(locator, (address) => dial(address));
		const managed = await ownerDir.openManaged("managed-recovery");
		const room = await Room.subscribe(ownerDir.session, managed.room, "keeper");
		await room.takeManager(managed.managerLink);
		identity = await room.managerIdentity();

		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(operatorSession, operatorSwiss);
		assert(
			await giveRoomManager(operatorSession, operator.cap, identity) === managed.managerLink,
			"operator recovery changed a current manager generation",
		);
		const alreadyLive = await operatorSession.enliven(managed.managerLink);
		await revokeRoomAuthority(
			operatorSession,
			operator.cap,
			"manager",
			roomAuthorityToken(managed.managerLink),
		);
		let oldManagerWorked = true;
		try {
			await within(operatorSession.send(alreadyLive, GOVERNS, []), "the revoked live manager refusing");
		} catch {
			oldManagerWorked = false;
		}
		assert(!oldManagerWorked, "an already-live manager survived exact generation revocation");

		replacementManager = await giveRoomManager(operatorSession, operator.cap, identity);
		assert(replacementManager !== managed.managerLink, "operator recovery reused a revoked manager generation");
		await room.takeManager(replacementManager);
		assert(await room.link() === managed.roomLink, "manager recovery changed an active room-link generation");
		operatorSession.release(alreadyLive);
		await room.leave();
		await ownerDir.close();
		await operatorSession.close();

		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory, ["--operator"]);
		const after = await dial(locator);
		const restored = await after.enliven(replacementManager);
		assert(
			await within(after.send(restored, GOVERNS, []), "the recovered manager after restart") === identity,
			"restart changed the recovered manager's room identity",
		);
		after.release(restored);
		await after.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});

roomsTest("the Rooms operator can establish management for a live baseline room", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-baseline-manager-" });
	const port = stablePort();
	const locator = loopbackTcpDesignator(port);
	const server = startStatefulServer(port, stateDirectory, ["--operator"]);
	try {
		await readPort(server);
		const directory = await Directory.connect(locator, (address) => dial(address));
		const room = await Room.subscribe(directory.session, await directory.open("baseline-managed"), "keeper");
		let unmanagedLink = "";
		try {
			await room.link();
		} catch (error) {
			unmanagedLink = error instanceof Error ? error.message : String(error);
		}
		assert(
			unmanagedLink.includes("room manager must create one"),
			"baseline room possession silently created durable entry authority",
		);
		const identity = await room.managerIdentity();
		const operatorSession = await dial(locator);
		const operator = await takeRoomsOperator(
			operatorSession,
			(await Deno.readTextFile(`${stateDirectory}/operator`)).trim(),
		);
		const manager = await giveRoomManager(operatorSession, operator.cap, identity);
		await room.takeManager(manager);
		const entryLink = await room.link();
		assert(entryLink !== "", "operator-established management did not create a room entry link");
		operatorSession.release(await operatorSession.enliven(entryLink));
		await room.leave();
		await directory.close();
		await operatorSession.close();
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
		const firstManaged = await ownerDir.openManaged("replaceable");
		const first = await Room.subscribe(ownerDir.session, firstManaged.room, "keeper");
		await first.takeManager(firstManaged.managerLink);
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

		const resetChanges: RoomAuthorityChange[] = [];
		const replacement = await Room.subscribe(
			ownerDir.session,
			await ownerDir.enter("replaceable"),
			"keeper",
			{ onAuthorityChanged: (_room, change) => resetChanges.push(change) },
		);
		await replacement.takeManager(firstManaged.managerLink);
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
		await until(
			() => resetChanges.some((change) => change.kind === "manager"),
			"factory reset did not notify the current manager holder",
		);
		assert(replacement.managerLink === null, "factory reset left retired manager custody visible");
		const after = await snapshotOperator(operatorSession, operator.cap);
		assert(after.rooms.length === 0, "the full reset left a room owner");
		assert(after.links.length === 0, "the full reset left a durable room link");
		assert(after.registrations.length === 0, "the full reset left a nickname claim");
		// The sessions inventory lists the caller's own connection, marked, so a
		// full reset leaves exactly that one row: the door the operator is
		// standing in.
		assert(
			after.sessions.length === 1 && after.sessions[0].you,
			"the full reset left a peer session",
		);
		assert(after.trouble.length === 0, "the full reset left acknowledged trouble");
		let linkSurvived = true;
		try {
			await operatorSession.enliven(replacementLink);
		} catch {
			linkSurvived = false;
		}
		assert(!linkSurvived, "the full reset left the durable room authority redeemable");
		const reissuerDir = await Directory.connect(locator, (address) => dial(address));
		const reissuedManaged = await reissuerDir.openManaged("replaceable");
		const reissuedRoom = await Room.subscribe(
			reissuerDir.session,
			reissuedManaged.room,
			"new-keeper",
		);
		await reissuedRoom.takeManager(reissuedManaged.managerLink);
		const reissuedLink = await reissuedRoom.link();
		assert(reissuedLink !== replacementLink, "factory reset reused the retired room authority");
		await operatorSession.enliven(reissuedLink);
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
