// The page-notice stack: several may be up, dismissing one leaves the others
// in order, and a looping failure cannot grow it without bound. An operations
// capability that stops answering says so here too, which is the one way one
// of them ends that the reader neither asked for nor can see coming. The
// server ask an act raises on a page with no Rooms server is held here too.

/// <reference lib="dom" />

import "./support/match_media.ts";
const store = await import("../web/ui/store.ts");
const projection = new store.PageProjection();
const { assertEquals } = await import("./assert.ts");

function clearToasts(): void {
	for (const notice of [...projection.get().toasts]) store.dismissToast(projection, notice.id);
}

Deno.test("toasts stack, and dismissing one leaves the others in order", () => {
	clearToasts();
	store.toast(projection, "success", "Room created");
	store.toast(projection, "failure", "Would not copy");
	store.toast(projection, "warning", "Look at this");
	const stacked = projection.get().toasts;
	assertEquals(stacked.map((notice) => [notice.kind, notice.text]), [
		["warning", "Look at this"],
		["failure", "Would not copy"],
		["success", "Room created"],
	], "three notices stand with the newest on top");
	store.dismissToast(projection, stacked[1].id);
	assertEquals(projection.get().toasts.map((notice) => notice.text), [
		"Look at this",
		"Room created",
	], "the gap closes rather than leaving a hole");
	clearToasts();
});

Deno.test("a looping failure cannot bury the page in notices", () => {
	clearToasts();
	for (let n = 0; n < 8; n++) store.toast(projection, "failure", "again " + n);
	const left = projection.get().toasts;
	assertEquals(left.length, 5, "the stack is capped");
	assertEquals(left[0].text, "again 7", "the newest remain on top");
	assertEquals(left[4].text, "again 3", "the oldest above the cap were dropped");
	clearToasts();
});

Deno.test("dismissing a notice that is already gone is nothing", () => {
	clearToasts();
	store.toast(projection, "success", "Room created");
	const id = projection.get().toasts[0].id;
	store.dismissToast(projection, id);
	store.dismissToast(projection, id);
	assertEquals(projection.get().toasts.length, 0);
});

Deno.test("an act that needs a Rooms server holds where it resumes until the ask is answered", () => {
	store.askServer(projection, "/join?room=general");
	assertEquals(projection.get().serverAsk, { resume: "/join?room=general" }, "the ask names where to resume");
	store.askServer(projection, null);
	assertEquals(projection.get().serverAsk, { resume: null }, "a later ask replaces the first");
	store.dismissServerAsk(projection);
	assertEquals(projection.get().serverAsk, null, "dismissing takes the ask down");
	store.dismissServerAsk(projection);
	assertEquals(projection.get().serverAsk, null, "dismissing an ask that is gone is nothing");
});
