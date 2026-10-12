// A pasted room link is one retained workspace transaction, including nickname
// selection and first directory acquisition. Refusal exposes no partial intent.
import { assert, assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { OPEN_ROOM_POLICY, PRIVATE_ROOM_POLICY } from "../../lib/room/policy.ts";
import { ManagedOperation } from "../../web/ui/session/managed/operation.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import { ManagedActions } from "../../web/ui/session/managed/actions.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import { initializeApplication } from "../support/application.ts";
import { ReadinessNotices } from "../../web/ui/session/managed/readiness.ts";

await initializeApplication();

Deno.test("direct retries keep one opening and ignore sibling readiness", async () => {
	for (const closing of [false, true]) {
		const notices = new ReadinessNotices();
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "access",
			source: "source",
			name: "name",
			inbox: "callback",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		const openings: string[] = [];
		let readiness: Parameters<ManagedRoomsSession["waitNotice"]>[0] | undefined;
		const session = {
			execute: async (
				_id: string,
				prepare: () => Promise<ManagedOperation>,
				complete: (op: ManagedOperation) => Promise<void>,
				continuation?: { settled(): Promise<void> },
			) => {
				await complete(await prepare());
				await continuation?.settled();
			},
			refresh: () => Promise.resolve(current),
			workspace: {
				directoryReader: () =>
					Promise.resolve({ memberRegistration: () => Promise.resolve("peer"), free() {} }),
			},
			waitNotice: (predicate: typeof readiness) => {
				readiness = predicate;
				assert(predicate != null, "an introduction needs a readiness predicate");
				return notices.wait(predicate);
			},
			command: (_name: string, args: string[]) => {
				openings.push(args[3]);
				return Promise.resolve({
					id: "conversation",
					result: () =>
						Promise.resolve(
							openings.length === 1 ? { status: "pending" } : { status: "ready", inbox: "inbox" },
						),
				});
			},
			finish() {
				if (closing) notices.close();
				else {
					notices.notify({
						target: { kind: "directory", id: "directory" },
						notice: { kind: "introducible", registration: "peer", opening: openings[0] },
					});
				}
			},
			completeResult: () => {
				current.intent.conversations.push({
					kind: "direct",
					id: "conversation",
					directory: "directory",
					peer: "bob",
					access: "adopted",
					closed: false,
					draft: "",
					introduction: {
						access: "access",
						name: "name",
						callback: "callback",
						registration: "peer",
						opening: openings[0],
					},
				});
				return Promise.resolve();
			},
		} as unknown as ManagedRoomsSession;
		const [result] = await Promise.allSettled([new ManagedActions(session).direct("directory", "bob", false)]);
		notices.close();
		if (closing) {
			assertEquals(result.status, "rejected");
			assertEquals(openings.length, 1, "closing must not dispatch another introduction");
			assertEquals(current.intent.conversations.length, 0);
			continue;
		}
		assertEquals(result.status, "fulfilled");
		assertEquals(openings.length, 2);
		assertEquals(openings[0], openings[1]);
		assert(openings[0].length > 0, "one opening identity was minted");
		const notice = { kind: "introducible" as const, registration: "peer", opening: "sibling" };
		const event: Parameters<NonNullable<typeof readiness>>[0] = {
			target: { kind: "directory", id: "directory" },
			notice,
		};
		assert(readiness != null, "readiness was installed before introduction");
		assertEquals(readiness(event), false);
		notice.opening = openings[0];
		assertEquals(readiness(event), true);
	}
});

Deno.test("named direct contact reuses only the exact current registration", async () => {
	for (const change of ["none", "peer", "local", "manual", "lookup", "prepare"]) {
		const current = snapshot();
		current.intent.directories.push({
			id: "directory",
			access: "directory-access",
			source: "source",
			name: "current-name",
			inbox: "current-callback",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		current.intent.conversations.push({
			kind: "direct",
			id: "old-conversation",
			directory: "directory",
			peer: "bob",
			source: "source",
			access: "held-old-route",
			closed: false,
			draft: "",
			introduction: change === "manual" ? undefined : {
				access: "directory-access",
				name: change === "local" ? "old-name" : "current-name",
				callback: "current-callback",
				opening: "old-opening",
				registration: change === "peer" || change === "prepare" ? "old-peer" : "current-peer",
			},
		});
		const calls: string[] = [];
		let opening = "";
		const session = {
			execute: async (
				_id: string,
				prepare: () => Promise<ManagedOperation>,
				complete: (op: ManagedOperation) => Promise<void>,
				continuation?: { settled(): Promise<void> },
			) => {
				await complete(await prepare());
				await continuation?.settled();
			},
			refresh: () => Promise.resolve(structuredClone(current)),
			workspace: {
				directoryReader: () =>
					Promise.resolve({
						memberRegistration: () => {
							calls.push("lookup");
							if (change === "lookup") current.intent.directories[0].name = "replacement-name";
							return Promise.resolve("current-peer");
						},
						free: () => calls.push("free"),
					}),
			},
			waitNotice: () => ({ ready: Promise.resolve(), cancel: () => calls.push("cancel") }),
			command: (
				name: string,
				args: string[],
				_operation: string,
				validate: (snapshot: WorkspaceSnapshot) => void,
			) => {
				assertEquals([name, args.slice(0, 3)], ["startDirect", ["directory", "bob", "current-peer"]]);
				assertEquals(typeof args[3], "string");
				opening = args[3];
				if (change === "prepare") current.intent.directories[0].name = "replacement-name";
				validate(current);
				calls.push("introduce");
				return Promise.resolve({
					id: "new-conversation",
					result: () => Promise.resolve({ status: "ready", inbox: "actual-result" }),
				});
			},
			completeResult: () => {
				calls.push("acquire");
				current.intent.conversations.push({
					kind: "direct",
					id: "new-conversation",
					directory: "directory",
					peer: "bob",
					access: "adopted",
					closed: false,
					draft: "",
					introduction: {
						access: "directory-access",
						name: "current-name",
						callback: "current-callback",
						registration: "current-peer",
						opening,
					},
				});
				return Promise.resolve();
			},
		} as unknown as ManagedRoomsSession;
		const direct = new ManagedActions(session).direct("directory", "bob", false);
		if (change === "lookup" || change === "prepare") {
			await direct.then(() => {
				throw new Error("replaced registration was reused");
			}, (error) => {
				assertEquals(error.message, "The initiating registration changed while selecting the peer");
			});
			assertEquals(calls, change === "lookup" ? ["lookup", "free"] : ["lookup", "free", "cancel"]);
			continue;
		}
		assertEquals(
			await direct,
			change === "none" ? "old-conversation" : "new-conversation",
		);
		assertEquals(
			calls,
			change === "none" ? ["lookup", "free"] : ["lookup", "free", "introduce", "acquire", "cancel"],
		);
	}
});

for (const existing of [true, false]) {
	Deno.test(`managed room-link acquisition ${existing ? "updates" : "creates"} its directory atomically`, async () => {
		const accepted = snapshot();
		const directory = "ocapn://127.0.0.1%3A1234.tcp";
		if (existing) {
			accepted.intent.directories.push({
				id: directory,
				access: "directory-access",
				source: "original-source",
				home: true,
				nick: "visitor",
				nickAllocation: "automatic",
				assignedNick: "visitor-2",
				standing: null,
			});
		}
		const original = structuredClone(accepted);
		const started = deferred<void>();
		const finish = deferred<void>();
		let candidate!: WorkspaceSnapshot["intent"];
		let preparations = 0;
		let submissions = 0;
		let frees = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(accepted),
			prepareAcquisition: (
				revision: string,
				imports: string,
				releases: string,
				intent: string,
				source: string,
			) => {
				preparations++;
				assertEquals(revision, original.revision);
				assertEquals(JSON.parse(releases), []);
				candidate = JSON.parse(intent);
				const imported = JSON.parse(imports);
				assertEquals(
					imported.map((row: { coordinate: { role: string } }) => row.coordinate.role),
					existing ? ["roomAccess"] : ["roomAccess", "directoryAccess"],
				);
				const initiating = JSON.parse(source);
				assertEquals(initiating.role, "sessionAccess");
				assertEquals(candidate.conversations[0].source, initiating.key);
				if (!existing) assertEquals(candidate.directories[0].source, initiating.key);
				return Promise.resolve({
					async submit() {
						submissions++;
						started.resolve();
						await finish.promise;
						if (submissions === 1) throw new Error("Acquisition acknowledgment unavailable");
						accepted.intent = candidate;
						return "committed";
					},
					free() {
						frees++;
					},
				});
			},
		});
		await session.refresh();
		const joining = session.actions.roomLink(directory, "ocapn://127.0.0.1%3A1234.tcp/s/cm9vbQ", "garden", {
			route: "127.0.0.1:1234",
			nick: { kind: "exact", name: "visitor" },
			home: true,
		});
		await started.promise;
		assertEquals(accepted, original, "pending acquisition leaked a nickname or directory change");
		assertEquals(candidate.directories[0].nick, "visitor");
		assertEquals(candidate.directories[0].nickAllocation, "exact");
		assertEquals(candidate.directories[0].assignedNick, undefined);
		const selected = candidate.conversations[0];
		assert(selected.kind === "room", "The acquired conversation must be a room");
		assertEquals(selected.name, "garden");
		finish.resolve();
		await joining.then(
			() => {
				throw new Error("The first submission must report its refusal");
			},
			(error) => assertEquals(error.message, "Acquisition acknowledgment unavailable"),
		);
		assertEquals(accepted, original, "refused acquisition leaked partial intent");
		assertEquals(frees, 0, "refusal must retain the original acquisition");
		assertEquals(session.actions.pending.length, 1);
		await session.actions.recoverAcquisition(session.actions.pending[0]);
		assertEquals(accepted.intent.active, original.intent.active, "acquisition preserves selection");
		assertEquals(preparations, 1);
		assertEquals(submissions, 2);
		assertEquals(frees, 1);
		await session.close();
	});
}

for (const policy of [OPEN_ROOM_POLICY, PRIVATE_ROOM_POLICY]) {
	Deno.test(`managed ${policy.visibility} room acquisition preserves reach and waits for commitment`, async () => {
		const accepted = snapshot();
		accepted.intent.directories.push({
			id: "directory",
			access: "access",
			home: true,
			nick: "nick",
			nickAllocation: "exact",
			standing: null,
		});
		const session = viewer({ snapshot: () => Promise.resolve(accepted) });
		let candidate: WorkspaceSnapshot | undefined;
		let args: string[] = [];
		const operation = new ManagedOperation("original", {
			originalIntent: () => ["original", 1, "openManagedRoom", args],
			adopted: () => Promise.resolve(false),
			result: () => Promise.resolve({ room: "original-room", control: "original-control" }),
			prepareCreatedRoomAcquisition: (
				_revision: string,
				_mappings: string,
				_releases: string,
				intent: string,
			) => {
				candidate = { revision: accepted.revision, intent: JSON.parse(intent) };
				return Promise.resolve({
					submit: () => Promise.reject(new Error("acquisition acknowledgement missing")),
					free() {},
				});
			},
			free() {},
		} as unknown as RoomsManagedCommand);
		session.command = (_name, submitted) => {
			args = submitted ?? [];
			return Promise.resolve(operation);
		};
		let refused = false;
		try {
			await session.actions.createRoom("directory", "Room", policy);
		} catch {
			refused = true;
		}
		assert(refused, "unacknowledged acquisition must remain unresolved");
		assertEquals(candidate?.intent.conversations.length, 1);
		const room = candidate?.intent.conversations[0];
		assert(room?.kind === "room", "Creation selects a room");
		assertEquals(room.reconnect, "requested");
		assert(room.access != null && room.source != null, "Membership keeps exact room and initiating source custody");
		assertEquals(room.accepted, undefined);
		assertEquals(room.publicEntry, undefined);
		assertEquals(args.slice(0, 5), [
			"directory",
			"Room",
			policy.visibility,
			policy.entry,
			policy.speaking,
		]);
		assert(args[5].startsWith("~"), "Creation retains its exact inbox destination");
		assertEquals(session.current?.intent.conversations, []);
		assertEquals(accepted.intent.active, null);
		await operation.close();
		await session.close();
	});
}
