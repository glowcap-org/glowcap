/**
 * What the Inspector shows, as against what is logically selected.
 *
 * The two come apart on purpose. A selection survives a mode switch so that
 * leaving Play for Live and coming back puts the reader where they were — which
 * means that while Live is up, the selection names entities the live stream has
 * never mentioned.
 *
 * Every part of the pane has to agree about that, and each part asking for itself
 * is how they stopped agreeing: the bodies showed their placeholder while the
 * Details heading, deciding from the logical anchor, left its title off, so an
 * empty pane came with a title in one mode and without one in another. So the
 * distinction is drawn once, by `inspectorView`, and that is what these test.
 *
 * The section bodies subscribe locally (`useDocVersion` /
 * `useClockSnapshot` on the shell, `useEngineVersion` on field panels that
 * follow live world position) and cannot be called as plain functions, so
 * they are not covered here. Verified in a browser: selecting a peer
 * in Play and switching to Live shows the placeholder in both sections, under a
 * "DETAILS" title, and switching back shows the peer again.
 *
 * Validated by injection, one per claim: returning the anchor unresolved fails "an
 * entity this buffer never heard of is not being shown"; returning the selection
 * unfiltered fails "a selection is narrowed to what the buffer holds"; and dropping
 * the all-held shortcut fails "a selection the buffer holds whole comes back by
 * identity", which is the one that would otherwise rot silently, since a copy is
 * correct in everything but cost.
 */

import { assert, assertEquals } from "@std/assert";
import { connectionsSectionTitle, inspectorView } from "./Sidebar.tsx";
import { Engine } from "../engine/engine.ts";
import { TimelineDocument } from "../engine/timeline.ts";
import { entityKey, type EntityRefKey } from "../interactions/types.ts";

/** Two peers and one session between them, so a peer anchor has an edge to
 *  count and the count is a number the title has to get right. */
function docEngine(): Engine {
	return new Engine(TimelineDocument.parse({
		id: "inspector-anchor",
		duration: 10_000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "pancake",
			},
			{
				id: "e2",
				t: 0,
				kind: "peer-joined",
				peerId: "bob",
				profile: "goblins",
			},
			{
				id: "e3",
				t: 1000,
				kind: "session-opened",
				sessionId: "s1",
				a: "alice",
				b: "bob",
				codec: "capnp",
				captpVersion: "v1_0",
			},
		],
	}));
}

/** An engine with no entities at all — what Live is before anything arrives. */
function emptyEngine(): Engine {
	return new Engine(TimelineDocument.parse({
		id: "empty",
		duration: 1000,
		events: [],
	}));
}

const alice = entityKey({ kind: "peer", id: "alice" });
const bob = entityKey({ kind: "peer", id: "bob" });

Deno.test("what the buffer holds is shown as picked", () => {
	const e = docEngine();
	const shown = inspectorView(
		e,
		{ kind: "peer", id: "alice" },
		new Set([alice]),
	);
	assertEquals(shown.anchor, { kind: "peer", id: "alice" });
	assertEquals([...(shown.selection ?? [])], [alice]);
});

Deno.test("an entity this buffer never heard of is not being shown", () => {
	// The Live case. The anchor is real — it names a peer the reader picked in Play
	// — and this engine has no record of it, so nothing is being shown and the pane
	// reads exactly as it does with nothing picked, title included.
	const live = emptyEngine();
	const shown = inspectorView(
		live,
		{ kind: "peer", id: "alice" },
		new Set([alice]),
	);
	assertEquals(shown.anchor, null);
	assertEquals([...(shown.selection ?? [])], []);
});

Deno.test("a session the buffer dropped takes its end with it", () => {
	// A session end has no identity of its own — it is one end of one session and
	// dies with it — so an end of a session this buffer does not hold is not shown
	// either.
	const live = emptyEngine();
	assertEquals(
		inspectorView(live, { kind: "session", id: "s1" }, undefined).anchor,
		null,
	);
	assertEquals(
		inspectorView(docEngine(), { kind: "session", id: "s1" }, undefined)
			.anchor,
		{ kind: "session", id: "s1" },
	);
});

Deno.test("a selection is narrowed to what the buffer holds", () => {
	// The group panel counts what it is given, so a selection of two peers where
	// the buffer holds one has to arrive as one — otherwise the heading counts
	// entities that are not on the stage.
	const e = docEngine();
	const both: ReadonlySet<EntityRefKey> = new Set([
		alice,
		entityKey({ kind: "peer", id: "ghost" }),
	]);
	const shown = inspectorView(e, { kind: "peer", id: "alice" }, both);
	assertEquals([...(shown.selection ?? [])], [alice]);
});

Deno.test("a selection the buffer holds whole comes back by identity", () => {
	// The common case allocates nothing, the same way `reconcile-with-doc` returns
	// the same state when it finds everything in place.
	const e = docEngine();
	const held: ReadonlySet<EntityRefKey> = new Set([alice, bob]);
	assert(
		inspectorView(e, { kind: "peer", id: "alice" }, held).selection ===
			held,
		"a fully held selection was copied",
	);
	assertEquals(inspectorView(e, null, undefined).selection, undefined);
});

Deno.test("the connections title is given what is shown", () => {
	// It takes the resolved anchor, so it cannot name a peer over a list that says
	// nothing is picked.
	const e = docEngine();
	assertEquals(connectionsSectionTitle(e, null), "Connections");
	assertEquals(
		connectionsSectionTitle(e, { kind: "peer", id: "alice" }),
		"Session edges (1)",
	);
	assertEquals(
		connectionsSectionTitle(e, { kind: "session", id: "s1" }),
		"Endpoint edges",
	);
});
