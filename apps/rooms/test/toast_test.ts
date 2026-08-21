// The page-notice stack: several may be up, dismissing one leaves the others
// in order, and a looping failure cannot grow it without bound. An operations
// capability that stops answering says so here too, which is the one way one
// of them ends that the reader neither asked for nor can see coming.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../web/ui/store.ts");
const { opsLost } = await import("../web/ui/net/common.ts");
const { OPS_CAPS } = await import("../web/ui/types.ts");
const { OPS_CATALOG } = await import("../web/ui/ops/catalog.ts");
const { assertEquals } = await import("./assert.ts");

function clearToasts(): void {
	for (const notice of [...store.get().toasts]) store.dismissToast(notice.id);
}

Deno.test("toasts stack, and dismissing one leaves the others in order", () => {
	clearToasts();
	store.toast("success", "Room created");
	store.toast("failure", "Would not copy");
	store.toast("warning", "Look at this");
	const stacked = store.get().toasts;
	assertEquals(stacked.map((notice) => [notice.kind, notice.text]), [
		["warning", "Look at this"],
		["failure", "Would not copy"],
		["success", "Room created"],
	], "three notices stand with the newest on top");
	store.dismissToast(stacked[1].id);
	assertEquals(store.get().toasts.map((notice) => notice.text), [
		"Look at this",
		"Room created",
	], "the gap closes rather than leaving a hole");
	clearToasts();
});

Deno.test("a looping failure cannot bury the page in notices", () => {
	clearToasts();
	for (let n = 0; n < 8; n++) store.toast("failure", "again " + n);
	const left = store.get().toasts;
	assertEquals(left.length, 5, "the stack is capped");
	assertEquals(left[0].text, "again 7", "the newest remain on top");
	assertEquals(left[4].text, "again 3", "the oldest above the cap were dropped");
	clearToasts();
});

Deno.test("dismissing a notice that is already gone is nothing", () => {
	clearToasts();
	store.toast("success", "Room created");
	const id = store.get().toasts[0].id;
	store.dismissToast(id);
	store.dismissToast(id);
	assertEquals(store.get().toasts.length, 0);
});

Deno.test("a capability that stops answering is named, with the reason", () => {
	clearToasts();
	for (const cap of OPS_CAPS) opsLost(cap, "the server said no.");
	const said = store.get().toasts.map((notice) => [notice.kind, notice.text]).reverse();
	assertEquals(
		said,
		OPS_CAPS.map((cap) => [
			"failure",
			`${OPS_CATALOG[cap].pane}: this tab no longer holds that capability. the server said no.`,
		]),
		"every capability the page knows can say it has gone, by the name its pane wears",
	);
	clearToasts();
});
