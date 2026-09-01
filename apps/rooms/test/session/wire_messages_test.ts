import { MAX_AWAY, MAX_LINE, MAX_ROSTER_SEEN } from "../../lib/limits.ts";
import { type Argument, Ref } from "@pancake/runtime";
import { parseLineEvent, parseOperationsSnapshot, parseRoomsSessionSnapshot } from "../../lib/session/messages.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { assertEquals } from "../assert.ts";
import { assertSessionSnapshotSize, fitSessionSnapshot } from "../../session/snapshot_wire.ts";
import { registrationId } from "../support/registration.ts";

function refused(work: () => unknown): boolean {
	try {
		work();
		return false;
	} catch {
		return true;
	}
}

function snapshot(): unknown[] {
	return [
		0n,
		JSON.stringify(emptyRoomsSessionState()),
		[],
		[],
		[],
		[],
		null,
		"[]",
		"[]",
		"[]",
		JSON.stringify({ version: 1, rights: "admin", workspaceAdoption: "closed", grants: [] }),
		"[]",
	];
}

function line(presence: string | null = null): unknown[] {
	return ["room-lines", 1n, "room-1", "ada", "hello", 0n, null, null, false, null, null, null, false, presence, null];
}

Deno.test("Rooms session schemas accept a bounded snapshot and operation rows", () => {
	const parsed = parseRoomsSessionSnapshot(snapshot());
	assertEquals(parsed.revision, 0);
	assertEquals(parsed.roomViews, []);
	assertEquals(parsed.handedRooms, []);
	const withDirectories = snapshot();
	withDirectories[9] = JSON.stringify([{
		directoryId: "directory",
		rooms: [{
			id: "general",
			name: "general",
			kind: "local",
			count: 1,
			origin: "",
			proof: "local",
			offers: "participant",
		}],
		peers: [{ name: "ada", registrationId: registrationId(1) }],
		truncated: false,
	}]);
	withDirectories[10] = JSON.stringify({
		version: 1,
		rights: "admin",
		workspaceAdoption: "available",
		grants: [{
			id: "00000000-0000-4000-8000-000000000001",
			label: "Wall display",
			rights: "observe",
			history: false,
			suspended: false,
			note: "",
			sturdyref: "ocapn://session.id/s/grant",
		}],
	});
	const projected = parseRoomsSessionSnapshot(withDirectories);
	assertEquals(projected.directoryViews?.[0]?.peers, [{ name: "ada", registrationId: registrationId(1) }]);
	assertEquals(projected.access, "admin");
	assertEquals(projected.workspaceAdoption, "available");
	assertEquals(projected.grants?.[0]?.label, "Wall display");
	const diagnostics = parseOperationsSnapshot(
		"diagnostics",
		JSON.stringify([{ kind: "room", name: "general", note: "live" }]),
	);
	assertEquals(diagnostics.capability, "diagnostics");
	assertEquals(diagnostics.capability === "diagnostics" ? diagnostics.rows.length : 0, 1);
	assertEquals(
		parseOperationsSnapshot(
			"viz",
			JSON.stringify({ url: "ws://timeline.test/viz", connected: true, refusal: null }),
		),
		{ capability: "viz", url: "ws://timeline.test/viz", connected: true, refusal: null },
	);
});

Deno.test("Rooms session line events enforce the UTF-8 byte ceiling", () => {
	const oversized = line();
	oversized[4] = "🫓".repeat(MAX_LINE);
	assertEquals(refused(() => parseLineEvent(oversized)), true);
});

Deno.test("session snapshots refuse obsolete tuple and access envelopes", () => {
	const priorAccess = snapshot();
	priorAccess[10] = JSON.stringify({ rights: "admin", grants: [] });
	assertEquals(refused(() => parseRoomsSessionSnapshot(priorAccess)), true);
	assertEquals(refused(() => parseRoomsSessionSnapshot(snapshot().slice(0, 11))), true);
});

Deno.test("Rooms session snapshots refuse aggregate fan-out before projection", () => {
	const pending = snapshot();
	pending[2] = Array.from({ length: 257 }, (_, at) => `operation-${at}`);
	assertEquals(refused(() => parseRoomsSessionSnapshot(pending)), true);

	const duplicateRoster = snapshot();
	duplicateRoster[7] = JSON.stringify([{
		conversationId: "room-1",
		members: [
			["ada", { online: true, away: "" }],
			["ada", { online: false, away: "" }],
		],
		topic: null,
		lineBytes: null,
	}]);
	assertEquals(refused(() => parseRoomsSessionSnapshot(duplicateRoster)), true);

	const duplicatePeers = snapshot();
	duplicatePeers[9] = JSON.stringify([{
		directoryId: "directory",
		rooms: [],
		peers: [
			{ name: "Ada", registrationId: registrationId(1) },
			{ name: "ada", registrationId: registrationId(2) },
		],
		truncated: false,
	}]);
	assertEquals(refused(() => parseRoomsSessionSnapshot(duplicatePeers)), true);

	const duplicateGrants = snapshot();
	const grant = {
		id: "00000000-0000-4000-8000-000000000001",
		label: "Wall display",
		rights: "observe",
		sturdyref: "ocapn://session.id/s/grant",
	};
	duplicateGrants[10] = JSON.stringify({
		version: 1,
		rights: "admin",
		workspaceAdoption: "closed",
		grants: [grant, grant],
	});
	assertEquals(refused(() => parseRoomsSessionSnapshot(duplicateGrants)), true);
});

Deno.test("Rooms session event schemas bound text, presence, and roster state", () => {
	const valid = parseLineEvent(line(JSON.stringify({ kind: "away", name: "ada", reason: "lunch" })));
	assertEquals(valid.presence, { kind: "away", name: "ada", reason: "lunch" });

	const longLine = line();
	longLine[4] = "x".repeat(MAX_LINE + 1);
	assertEquals(refused(() => parseLineEvent(longLine)), true);
	assertEquals(
		refused(() =>
			parseLineEvent(line(JSON.stringify({ kind: "away", name: "ada", reason: "x".repeat(MAX_AWAY + 1) })))
		),
		true,
	);
	assertEquals(
		refused(() =>
			parseLineEvent(line(JSON.stringify({
				kind: "roster",
				names: Array.from({ length: MAX_ROSTER_SEEN + 1 }, (_, at) => `member-${at}`),
			})))
		),
		true,
	);
	assertEquals(refused(() => parseOperationsSnapshot("viz", JSON.stringify({ connected: "yes" }))), true);
});

Deno.test("Rooms session line mutations refuse impossible identity and attachment shapes", () => {
	const blob = Object.create(Ref.prototype) as Ref;
	const missingId = line();
	missingId[7] = "edited";
	assertEquals(refused(() => parseLineEvent(missingId)), true);

	const attachedEdit = line();
	attachedEdit[6] = 1n;
	attachedEdit[7] = "edited";
	attachedEdit.push("file", "edit.txt", "text/plain", 1n, blob, 0n, 0n);
	assertEquals(refused(() => parseLineEvent(attachedEdit)), true);

	const attachedSystem = line();
	attachedSystem[12] = true;
	attachedSystem.push("file", "system.txt", "text/plain", 1n, blob, 0n, 0n);
	assertEquals(refused(() => parseLineEvent(attachedSystem)), true);
});

Deno.test("Rooms operation schemas refuse malformed rows as a whole", () => {
	assertEquals(
		refused(() =>
			parseOperationsSnapshot("diagnostics", JSON.stringify([{ kind: "", name: "general", note: "" }]))
		),
		true,
	);
	assertEquals(
		refused(() =>
			parseOperationsSnapshot(
				"listeners",
				JSON.stringify([{
					transport: "tcp",
					description: "TCP",
					reference: "",
					referenceName: "",
					takes: [{ name: "port", kind: "number", hint: "" }],
					unavailable: "",
					id: null,
					locator: null,
					serving: false,
				}]),
			)
		),
		true,
	);
});

Deno.test("the complete session snapshot is bounded before CapTP encoding", () => {
	assertEquals(refused(() => assertSessionSnapshotSize(["x".repeat(901 * 1024)])), true);
	assertSessionSnapshotSize(["x".repeat(899 * 1024)]);
	const oversized = snapshot();
	oversized[9] = JSON.stringify([{
		directoryId: "directory",
		rooms: [],
		peers: [{ name: "x".repeat(901 * 1024), registrationId: registrationId(1) }],
		truncated: false,
	}]);
	const fitted = fitSessionSnapshot(oversized as Argument[]);
	assertEquals(fitted[7], "[]");
	assertEquals(fitted[9], "[]");
	assertEquals((fitted[3] as unknown[][]).at(-1)?.[0], "snapshot-overflow");
});
