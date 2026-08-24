/**
 * An edit transaction that opens has to close, on the editor that
 * opened it, including when nobody tells it to.
 *
 * The engine records history only at transaction depth zero, so one
 * bracket left open silently stops the whole app being undoable. A
 * field opens on focus and closes on blur, and the cases that have no
 * blur are the ones that matter: selecting a different entity unmounts
 * the panel with the caret still in the field, and leaving Build takes
 * the editor out from under a field that is still mounted.
 *
 * Each case here drives the bracket the way `useEditBracket` does —
 * the editor arrives through a function the bracket asks, because in
 * the app it is a prop that changes — and calls `end` where React's
 * effect cleanup calls it.
 */

import { assert, assertEquals } from "@std/assert";
import { type EditBracket, editBracket } from "./edit-bracket.ts";

/** Records what one editor would have been asked to do. */
function recorder() {
	const calls: string[] = [];
	return {
		calls,
		session: {
			beginEdit: (label: string) => void calls.push(`begin:${label}`),
			endEdit: () => void calls.push("end"),
		} satisfies EditBracket,
	};
}

/** A field's view of the editor prop: whatever it is holding right
 *  now, which a test moves the way a re-render would. */
function editorProp(initial: EditBracket | undefined) {
	const held = { current: initial };
	return { held, ask: () => held.current };
}

Deno.test("focus then blur is one transaction", () => {
	const r = recorder();
	const b = editBracket(() => r.session);
	b.begin("Rename peer");
	b.end();
	assertEquals(r.calls, ["begin:Rename peer", "end"]);
	assertEquals(b.isOpen, false);
});

Deno.test("a panel unmounting mid-edit closes what it opened", () => {
	const r = recorder();
	const b = editBracket(() => r.session);
	b.begin("Edit claim");
	// Selecting another entity: React unmounts the input, and no blur
	// ever fires. Without this the depth sticks above zero and every
	// later dispatch is swallowed by a transaction with no end.
	b.end();
	assertEquals(r.calls, ["begin:Edit claim", "end"]);
	assertEquals(b.isOpen, false);
});

Deno.test("the editor that opened the transaction is the one that closes it", () => {
	const build = recorder();
	const prop = editorProp(build.session);
	const b = editBracket(prop.ask);
	b.begin("Edit claim");
	// Leaving Build with the caret in the field: the prop goes away, and
	// the close that follows is the field's unmount. A bracket that read
	// the prop here instead of at `begin` would find nothing to close and
	// leave the transaction open on an engine still holding history.
	prop.held.current = undefined;
	b.end();
	assertEquals(build.calls, ["begin:Edit claim", "end"]);
	assertEquals(b.isOpen, false);
});

Deno.test("a new editor does not inherit the old one's transaction", () => {
	const first = recorder();
	const second = recorder();
	const prop = editorProp(first.session);
	const b = editBracket(prop.ask);
	b.begin("Edit claim");
	// A fresh buffer means a fresh editor. The transaction belongs to the
	// engine that began it, and the new one never began anything.
	prop.held.current = second.session;
	b.end();
	assertEquals(first.calls, ["begin:Edit claim", "end"]);
	assertEquals(second.calls, []);
});

Deno.test("closing twice is not a second close", () => {
	const r = recorder();
	const b = editBracket(() => r.session);
	b.begin("Edit claim");
	b.end();
	// Blur, then unmount. Both want to close, and only one may.
	b.end();
	assertEquals(r.calls, ["begin:Edit claim", "end"]);
});

Deno.test("unmounting without an edit closes nothing", () => {
	const r = recorder();
	editBracket(() => r.session).end();
	assertEquals(r.calls, []);
});

Deno.test("focusing twice opens one transaction", () => {
	const r = recorder();
	const b = editBracket(() => r.session);
	b.begin("Edit claim");
	b.begin("Edit claim");
	assertEquals(r.calls, ["begin:Edit claim"]);
	assert(b.isOpen);
});

Deno.test("a read-only host brackets nothing", () => {
	const r = recorder();
	const prop = editorProp(undefined);
	const b = editBracket(prop.ask);
	b.begin("Edit claim");
	assertEquals(b.isOpen, false);
	// An editor arriving later did not open anything, so the close that
	// follows must not hand it an end it never began.
	prop.held.current = r.session;
	b.end();
	assertEquals(r.calls, []);
});
