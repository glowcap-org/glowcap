// Restored room intent yields to the membership authority learned after reconnect.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/types.ts");

Deno.test("live admission replaces a restored room's provisional access", () => {
	const dir = dirId("restored-observer-directory");
	const restored = store.ensureRoom(projection, dir, "moderated-room");
	if (restored.membershipKind !== "participant") throw new Error("the fixture did not begin with provisional access");
	const admitted = store.ensureRoom(projection, dir, "moderated-room", {
		membershipKind: "observer",
		policy: { visibility: "listed", entry: "open", speaking: "moderated" },
	});
	if (admitted.membershipKind !== "observer") {
		throw new Error("live observer authority did not replace restored access");
	}
	if (admitted.policy.speaking !== "moderated") throw new Error("live room policy did not replace restored policy");
	store.forgetConv(projection, admitted.key);
});
