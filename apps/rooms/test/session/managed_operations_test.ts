// Loaded inventories must follow exact custody and the latest requested query.
import { ManagedReads } from "../../web/ui/session/managed/reads.ts";
import { assert, assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomsPageContext } from "../../web/ui/page.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { RoomsPage } = await import("../../web/ui/page.ts");
const { managedOperations } = await import("../../web/ui/session/managed/operations.ts");
const { ManagedProjection } = await import("../../web/ui/session/managed/projection.ts");
const { presentationFiles } = await import("../../web/ui/session/managed/files.ts");
const store = await import("../../web/ui/store.ts");
const { formatOpsBundle } = await import("../../web/ui/ops/bundle.ts");

Deno.test("Operations acquisition keeps every refusal and commits no partial bundle", async () => {
	const current = snapshot();
	const before = JSON.stringify(current);
	let preparations = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(current),
		prepareOperationsAcquisition: (raw: string) => {
			preparations++;
			assertEquals(JSON.parse(raw).length, 2);
			return Promise.resolve({
				status: "refused",
				failures: [
					{ capability: "listeners", reason: "unknown swissnum", advice: "Use ROOMS-ADMIN-LISTENERS." },
					{ capability: "diagnostics", reason: "peer unavailable", advice: null },
				],
			});
		},
	});
	const page = new RoomsPage();
	const operations = managedOperations(page as RoomsPageContext, session);
	try {
		const requested = formatOpsBundle(
			new Map([
				["listeners", "ocapn://peer.tcp/s/c3RhbGU"],
				["diagnostics", "ocapn://peer.tcp/s/bWlzc2luZw"],
			]),
		);
		const result = await operations.replaceOpsBundle(requested);
		assertEquals(result.bundle, "");
		assertEquals(result.failures.map((row) => row.capability), ["listeners", "diagnostics"]);
		assert(result.failures[0].reason.includes("ROOMS-ADMIN-LISTENERS"), "repair advice was lost");
		assert(result.failures[0].reason.includes("unknown swissnum"), "wire refusal was lost");
		assert(result.failures[1].reason.includes("peer unavailable"), "unknown failure was lost");
		const trouble = page.projection.get().trouble;
		assertEquals(trouble.map((row) => row.source), ["Inspect this server", "Administer listeners"]);
		assertEquals(trouble.map((row) => row.reason), result.failures.map((row) => row.reason).toReversed());
		assertEquals(preparations, 1);
		assertEquals(JSON.stringify(current), before);
		assertEquals(session.actions.pending, []);
	} finally {
		await session.close();
	}
});

Deno.test("membership snapshots preserve journal history and report changed or recurring failures", async () => {
	const { membershipStatus } = await import("../../web/ui/session/managed/membership_status.ts");
	const { dirId } = await import("../../web/ui/types.ts");
	const page = new RoomsPage();
	store.openDir(page.projection, dirId("same"), "ocapn://peer.tcp");
	store.noteTrouble(page.projection, "Inspect this server", "original import refusal");
	const reports: unknown[] = [];
	const status = membershipStatus(page.projection, (source, error) => {
		reports.push(error);
		store.noteTrouble(page.projection, source, String(error));
	});
	const failures = [
		{ target: { kind: "room", id: "same" }, reason: "room unavailable" },
		{ target: { kind: "directory", id: "same" }, reason: "directory unavailable" },
	];
	for (let update = 0; update < 80; update++) {
		status({ failures: structuredClone(failures), sourceFailure: "source unavailable" });
	}
	assertEquals(reports.length, 3);
	assert(
		page.projection.get().trouble.some((row) => row.reason === "original import refusal"),
		"unchanged membership failures evicted the original import refusal",
	);
	assertEquals(page.projection.get().dirs.get(dirId("same"))?.session, "disconnected");
	status({ failures: [failures[0], { ...failures[1], reason: "directory refused" }] });
	assertEquals(reports.at(-1), "directory refused");
	status({});
	status({ failures, sourceFailure: "source unavailable" });
	assertEquals(reports.length, 7);
});

Deno.test("operations possession follows custody and replacement clears the old inventory", () => {
	const page = new RoomsPage();
	const current = snapshot();
	const session = {
		reads: new ManagedReads(),
		current,
		effects: {
			cancelledConversations: [],
			standingVersion: "",
			roomStandingPending: () => false,
			standing: (_name: string, _target: string | null, accepted: string | null) => accepted,
		},
		access: { status: "active" },
		pending: [],
		pendingOperations: [],
		recoverable: [],
		actions: { pending: [], recoverable: [], cancelledConversations: [] },
		openings: { destination: null },
		navigation: {},
	} as unknown as ManagedRoomsSession;
	const files = presentationFiles(page.projection, () => null);
	const projection = new ManagedProjection(page, session, files, () => {}, () => {});
	const apply = () => {
		current.revision = String(Number(current.revision) + 1);
		projection.apply();
	};
	try {
		current.intent.operations = [{ kind: "listeners", handle: { role: "operations", key: "original" } }];
		apply();
		assertEquals(page.projection.get().opsHeld.listeners, true);
		assertEquals(page.projection.get().listeners, null);
		store.setListeners(page.projection, []);
		apply();
		assertEquals(page.projection.get().listeners, []);
		current.intent.operations[0].handle.key = "replacement";
		apply();
		assertEquals(page.projection.get().listeners, null);
		assertEquals(page.projection.get().opsHeld.listeners, true);
		current.intent.operations = [];
		apply();
		assertEquals(page.projection.get().opsHeld.listeners, false);
	} finally {
		files.close();
	}
});

for (const change of ["replace", "drop", "newer"] as const) {
	Deno.test(`managed inventory drops an answer after ${change}`, async () => {
		const current = snapshot();
		current.intent.operations = [{ kind: "listeners", handle: { role: "operations", key: "original" } }];
		const first = deferred<unknown[]>();
		const second = deferred<unknown[]>();
		let reads = 0;
		let freed = 0;
		const session = {
			reads: new ManagedReads(),
			current,
			effects: {
				standingVersion: "",
				roomStandingPending: () => false,
				standing: (_name: string, _target: string | null, accepted: string | null) => accepted,
			},
			workspace: {
				operationsReader: () => {
					const answer = reads++ === 0 ? first : second;
					return Promise.resolve({ snapshot: () => answer.promise, free: () => freed++ });
				},
			},
		} as unknown as ManagedRoomsSession;
		const page = new RoomsPage();
		const operations = managedOperations(page as RoomsPageContext, session);
		const old = operations.refreshOpsCap("listeners");
		if (change === "replace") current.intent.operations[0].handle.key = "replacement";
		else if (change === "drop") current.intent.operations = [];
		else {
			const latest = operations.refreshOpsCap("listeners");
			second.resolve([]);
			await latest;
		}
		first.resolve([{ id: 1 }]);
		await old;
		assertEquals(page.projection.get().listeners, change === "newer" ? [] : null);
		assertEquals(freed, change === "newer" ? 2 : 1);
	});
}

Deno.test("peering publication and revoke update the pane from its held leases", async () => {
	const current = snapshot();
	current.intent.directories.push({
		id: "foreign",
		access: "directory-access",
		home: false,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	current.intent.conversations.push({
		kind: "room",
		id: "source-room",
		directory: "foreign",
		name: "annex",
		source: "source",
		access: "room-access",
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	current.intent.operations = [{ kind: "peering", handle: { role: "operations", key: "publisher" } }];
	const page = new RoomsPage();
	const session = {
		reads: new ManagedReads(),
		current,
		effects: {
			standingVersion: "",
			roomStandingPending: () => false,
			cancelledConversations: [],
			standing: (_name: string, _target: string | null, accepted: string | null) => accepted,
		},
		access: { status: "active" },
		pending: [],
		pendingOperations: [],
		recoverable: [],
		openings: { destination: null },
		navigation: {},
		drafts: { value: (_id: string, text: string) => text },
		workspace: {
			peeringSnapshot: () =>
				Promise.resolve(current.intent.peering.map((row) => ({
					id: row.id,
					name: row.name,
					source: row.directory,
					phase: "live",
				}))),
		},
		command: () => Promise.resolve({}),
		completeResult: () => {
			current.intent.peering.push({
				id: "publication",
				directory: "foreign",
				name: "annex-here",
				room: "room-access",
				lease: "exact-lease",
			});
			return Promise.resolve();
		},
		actions: {
			pending: [],
			recoverable: [],
			cancelledConversations: [],
			run: (name: string, args: string[]) => {
				assertEquals([name, args], ["revokePeeredRoom", ["publication", JSON.stringify("exact-lease")]]);
				current.intent.peering = [];
				return Promise.resolve();
			},
		},
	} as unknown as ManagedRoomsSession;
	const files = presentationFiles(page.projection, () => null);
	try {
		new ManagedProjection(page, session, files, () => {}, () => {}).apply();
		const operations = managedOperations(page, session);
		await operations.refreshOpsCap("peering");
		assertEquals(page.projection.get().peering?.publications, []);
		const room = store.convByPersistId(page.projection, "source-room")!;
		assertEquals(await operations.publishPeeredRoom(room.key, "annex-here"), "");
		assertEquals(page.projection.get().peering?.publications, [{
			id: "publication",
			name: "annex-here",
			source: "foreign",
			phase: "live",
		}]);
		assertEquals(await operations.revokePeeredPublication("publication"), "");
		assertEquals(page.projection.get().peering?.publications, []);
	} finally {
		files.close();
	}
});
