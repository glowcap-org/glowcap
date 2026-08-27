import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { loopbackTcpDesignator, roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { applyRoomsSessionCommand } from "../session/commands.ts";
import { DurableRoomsPeering } from "../session/peering.ts";
import { assertEquals } from "./assert.ts";
import type { Directory } from "../lib/directory.ts";
import type { LiveDirectory } from "../session/live.ts";

const directory = loopbackTcpDesignator(42101);
const directoryId = roomsPeerAuthority(roomsLocator(directory));

Deno.test("peering intent is versioned, destination-scoped, and duplicate-free", () => {
	const base = {
		...emptyRoomsSessionState(),
		directories: [{ id: directoryId, locator: directory, home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "source-room",
			directory: directoryId,
			name: "source",
			held: false,
			standing: null,
			draft: "",
		}],
	};
	const destination = loopbackTcpDesignator(42102);
	const destinationId = roomsPeerAuthority(roomsLocator(destination));
	const withDestination = {
		...base,
		directories: [...base.directories, {
			id: destinationId,
			locator: destination,
			home: false,
			nick: "ada",
			standing: null,
		}],
		capabilities: {
			...base.capabilities,
			operations: [{ capability: "peering" as const, scope: destinationId, swiss: "peering" }],
		},
	};
	const intent = { id: "publication-1", destination: destinationId, source: "source-room", name: "annex" };
	const next = applyRoomsSessionCommand(withDestination, "publishPeeredRoom", [JSON.stringify(intent)]);
	assertEquals(next.peering, [intent]);
	assertEquals(
		applyRoomsSessionCommand(next, "publishPeeredRoom", [JSON.stringify(intent)]),
		next,
	);
	let refused = false;
	try {
		applyRoomsSessionCommand(next, "publishPeeredRoom", [JSON.stringify({ ...intent, id: "publication-2" })]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(
		applyRoomsSessionCommand(next, "revokePeeredRoom", [intent.id]).peering,
		[],
	);
});

Deno.test("peering snapshots retain desired rows while leases are reconnecting", () => {
	const peering = new DurableRoomsPeering(() => false, () => {});
	assertEquals(
		peering.snapshot([{ id: "publication", destination: "destination", source: "source", name: "annex" }]),
		[{ id: "publication", name: "annex", source: "source", phase: "publishing" }],
	);
});

Deno.test("durable peering keeps, revokes, and releases publication leases at their owning boundaries", async () => {
	let opened = 0;
	let closed = 0;
	let published = 0;
	let revoked = 0;
	let released = 0;
	const peering = new DurableRoomsPeering(
		() => false,
		() => {},
		() => {
			opened += 1;
			return Promise.resolve({
				publish: () => {
					published += 1;
					return Promise.resolve({
						revoke: () => {
							revoked += 1;
							return Promise.resolve();
						},
						release: () => released += 1,
					});
				},
				close: () => {
					closed += 1;
					return Promise.resolve();
				},
			});
		},
	);
	const sourceDirectory = { session: {} } as Directory;
	const destinationDirectory = { session: {} } as Directory;
	const source = {
		directory: sourceDirectory,
		roomRealization: { rooms: new Map([["source-room", { room: { room: {} } }]]) },
	} as unknown as LiveDirectory;
	const destination = {
		directory: destinationDirectory,
		roomRealization: { rooms: new Map() },
	} as unknown as LiveDirectory;
	const directories = new Map<string, LiveDirectory>([
		[directoryId, source],
		["destination", destination],
	]);
	const intent = { id: "publication", destination: "destination", source: "source-room", name: "annex" };
	const checkpoint = (swiss: string | null) => ({
		...emptyRoomsSessionState(),
		capabilities: {
			operations: swiss == null ? [] : [{ capability: "peering" as const, scope: "destination", swiss }],
			archivePeer: null,
		},
		peering: swiss == null ? [] : [intent],
	});

	await peering.reconcile(checkpoint("first"), directories);
	assertEquals({ opened, published, revoked, released }, { opened: 1, published: 1, revoked: 0, released: 0 });
	await peering.reconcile(checkpoint("rotated"), directories);
	assertEquals({ opened, closed, published, revoked, released }, {
		opened: 2,
		closed: 1,
		published: 1,
		revoked: 0,
		released: 0,
	});
	await peering.reconcile(checkpoint(null), directories);
	assertEquals({ closed, revoked, released }, { closed: 2, revoked: 1, released: 0 });

	await peering.reconcile(checkpoint("third"), directories);
	assertEquals(published, 2);
	await peering.releaseFor("destination");
	assertEquals({ closed, revoked, released }, { closed: 3, revoked: 1, released: 1 });
	await peering.close();
});

Deno.test("a refused durable publication revoke retains its lease for reconciliation retry", async () => {
	const issues = new Map<string, string>();
	let revokes = 0;
	const peering = new DurableRoomsPeering(
		(subject, error) => {
			if (error == null) issues.delete(subject);
			else issues.set(subject, error instanceof Error ? error.message : String(error));
			return true;
		},
		() => {},
		() =>
			Promise.resolve({
				publish: () =>
					Promise.resolve({
						revoke: () => {
							revokes += 1;
							return revokes <= 2 ? Promise.reject(new Error("revoke refused")) : Promise.resolve();
						},
						release: () => {},
					}),
				close: () => Promise.resolve(),
			}),
	);
	const source = {
		directory: { session: {} },
		roomRealization: { rooms: new Map([["source-room", { room: { room: {} } }]]) },
	} as unknown as LiveDirectory;
	const destination = {
		directory: { session: {} },
		roomRealization: { rooms: new Map() },
	} as unknown as LiveDirectory;
	const directories = new Map([
		["source", source],
		["destination", destination],
	]);
	const present = {
		...emptyRoomsSessionState(),
		capabilities: {
			operations: [{ capability: "peering" as const, scope: "destination", swiss: "peering" }],
			archivePeer: null,
		},
		peering: [{ id: "publication", destination: "destination", source: "source-room", name: "annex" }],
	};
	const removed = { ...present, capabilities: { operations: [], archivePeer: null }, peering: [] };
	await peering.reconcile(present, directories);
	await peering.reconcile(removed, directories);
	assertEquals({ revokes, issue: issues.get("peering:publication") }, {
		revokes: 2,
		issue: "revoke refused",
	});
	await peering.reconcile(removed, directories);
	assertEquals({ revokes, issue: issues.get("peering:publication") }, { revokes: 3, issue: undefined });
	await peering.close();
});

Deno.test("a late peering publication returns its lease after the destination disconnects", async () => {
	const pending = Promise.withResolvers<{ revoke(): Promise<void>; release(): void }>();
	let released = 0;
	let closed = 0;
	const issues = new Map<string, string>();
	const peering = new DurableRoomsPeering(
		(subject, error) => {
			if (error == null) issues.delete(subject);
			else issues.set(subject, error instanceof Error ? error.message : String(error));
			return true;
		},
		() => {},
		() =>
			Promise.resolve({
				publish: () => pending.promise,
				close: () => {
					closed += 1;
					return Promise.resolve();
				},
			}),
	);
	const source = {
		directory: { session: {} },
		roomRealization: { rooms: new Map([["source-room", { room: { room: {} } }]]) },
	} as unknown as LiveDirectory;
	const destination = {
		directory: { session: {} },
		roomRealization: { rooms: new Map() },
	} as unknown as LiveDirectory;
	const directories = new Map([
		["source", source],
		["destination", destination],
	]);
	const checkpoint = {
		...emptyRoomsSessionState(),
		capabilities: {
			operations: [{ capability: "peering" as const, scope: "destination", swiss: "peering" }],
			archivePeer: null,
		},
		peering: [{ id: "publication", destination: "destination", source: "source-room", name: "annex" }],
	};
	const reconciling = peering.reconcile(checkpoint, directories);
	await Promise.resolve();
	await peering.releaseFor("destination");
	pending.resolve({ revoke: () => Promise.resolve(), release: () => released += 1 });
	await reconciling;
	assertEquals({ released, closed }, { released: 1, closed: 1 });
	assertEquals(
		issues.get("peering:publication"),
		"the peering source or destination changed while publication was opening",
	);
	assertEquals(peering.snapshot(checkpoint.peering)[0]?.phase, "failed");
	await peering.close();
});
