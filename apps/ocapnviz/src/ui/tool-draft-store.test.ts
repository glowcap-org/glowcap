/**
 * `ToolDraftStore`, the two-reader contract the tool bar's draft
 * values live under.
 *
 * The bar paints them every keystroke. The canvas click handlers
 * read them once, at the click that commits an authored peer,
 * session, or message. Those handlers are long-lived closures, so
 * the store must answer "what is in the field right now" rather
 * than "what was in the field when this closure was built", the
 * difference is a session authored with the codec the user had
 * selected a moment ago, committed with no error shown.
 *
 * What these tests do not pin: that the canvas click handlers
 * read through the store rather than through a captured copy. Deno
 * has no DOM, so nothing here renders the app. The reading is one
 * `toolDrafts.read()` per handler in `use-stage-build-gestures.ts`.
 */

import { assertEquals } from "@std/assert";
import { EMPTY_TOOL_DRAFTS, ToolDraftStore } from "./ToolOptionsBar.tsx";

Deno.test("a handler built early reads a field edited later", () => {
	// The corruption, in miniature: arm the first peer (which is
	// what rebuilds the click handler), then change a field, then
	// commit.
	const store = new ToolDraftStore();
	const commit = () => store.read().sessionCodec;
	assertEquals(commit(), "capnp");
	store.set({ ...store.read(), sessionCodec: "syrup" });
	assertEquals(commit(), "syrup");
});

Deno.test("update patches fields and leaves the rest", () => {
	// How the peer drop clears its id without dropping the sticky
	// session and message values beside it.
	const store = new ToolDraftStore();
	store.set({
		...EMPTY_TOOL_DRAFTS,
		peerId: "alice",
		peerLabel: "Alice",
		sessionCodec: "syrup",
		messageLabel: "greet",
	});
	store.update({ peerId: "", peerLabel: "" });
	assertEquals(store.read().peerId, "");
	assertEquals(store.read().peerLabel, "");
	assertEquals(store.read().sessionCodec, "syrup");
	assertEquals(store.read().messageLabel, "greet");
});

Deno.test("subscribers hear every write and stop on unsubscribe", () => {
	const store = new ToolDraftStore();
	const seen: string[] = [];
	const stop = store.subscribe(() => seen.push(store.read().peerId));
	store.update({ peerId: "a" });
	store.update({ peerId: "ab" });
	stop();
	store.update({ peerId: "abc" });
	assertEquals(seen, ["a", "ab"]);
	assertEquals(store.read().peerId, "abc");
});

Deno.test("the snapshot is stable between writes", () => {
	// `useSyncExternalStore` re-renders whenever the snapshot's
	// identity changes, so an unchanged store must return the same
	// object or the bar repaints on every render of its parent.
	const store = new ToolDraftStore();
	assertEquals(store.read() === store.read(), true);
	store.update({ peerId: "a" });
	assertEquals(store.read() === store.read(), true);
});
