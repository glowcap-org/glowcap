// Archive-target projection follows shared session authority without needless identity changes.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { ArchiveTargetProjection } = await import("../../web/ui/session/archive_target_projection.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");

Deno.test("attached archive target follows the shared session snapshot", () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		capabilities: {
			operations: [],
			archivePeer: "ocapn://127.0.0.1.tcp/s/archive",
		},
	};
	const snapshot = (issues: { subject: string; reason: string }[]) =>
		roomsSessionSnapshot({ revision: 1, checkpoint, issues });
	projection.apply(snapshot([]));
	assertEquals(page.projection.get().archiveTarget, {
		owner: "session",
		kind: "peer",
		status: "connected",
		label: "Shared session archive peer",
		remembered: true,
		error: "",
	});
	projection.apply(snapshot([{ subject: "archive", reason: "archive peer is down" }]));
	assertEquals(page.projection.get().archiveTarget, {
		owner: "session",
		kind: "peer",
		status: "unavailable",
		label: "Shared session archive peer",
		remembered: true,
		error: "archive peer is down",
	});
	assertEquals(page.projection.get().trouble[0], {
		source: "shared session archive",
		reason: "archive peer is down",
		count: 1,
	});
	assertEquals(page.projection.get().toasts.map(({ kind, text }) => ({ kind, text })), [{
		kind: "failure",
		text: "archive peer is down",
	}]);
	projection.apply(snapshot([{ subject: "archive", reason: "archive peer is down" }]));
	assertEquals(page.projection.get().trouble[0]?.count, 1, "an unchanged snapshot duplicated the failure");
	assertEquals(page.projection.get().toasts.length, 1, "an unchanged failure repeated its toast");
	projection.apply(snapshot([]));
	projection.apply(snapshot([{ subject: "archive:direct", reason: "archive peer is down again" }]));
	assertEquals(page.projection.get().toasts.map(({ text }) => text), [
		"archive peer is down again",
		"archive peer is down",
	]);
	projection.apply(roomsSessionSnapshot({
		...snapshot([]),
		checkpoint: { ...checkpoint, capabilities: { operations: [], archivePeer: null } },
	}));
	assertEquals(page.projection.get().archiveTarget, { kind: "owned", owner: "session" });
});

Deno.test("archive target projection changes identity only when its source or availability changes", () => {
	const target = new ArchiveTargetProjection();
	const first = target.update("first peer", "");
	if (target.update("first peer", "") !== first) throw new Error("unchanged snapshots restart archive reads");
	const second = target.update("second peer", "");
	if (second === first) throw new Error("peer replacement kept the previous share list identity");
	const failed = target.update("second peer", "unavailable");
	if (failed === second || failed.kind !== "peer" || failed.status !== "unavailable") {
		throw new Error("availability change was hidden");
	}
	assertEquals(target.update(null, "").kind, "owned");
});
