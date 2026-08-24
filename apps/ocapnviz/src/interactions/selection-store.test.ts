import { assert, assertEquals } from "@std/assert";
import {
	allEntityKeys,
	documentHolds,
	hasAnySelection,
	selectionActionFor,
	selectionReducer,
	selectionRefs,
} from "./selection-store.ts";
import { EMPTY_SELECTION, entityKey, type EntityRef, type EntityRefKey, type SelectionState } from "./types.ts";

const peerA: EntityRef = { kind: "peer", id: "a" };
const peerB: EntityRef = { kind: "peer", id: "b" };

function state(
	refs: readonly EntityRef[] = [],
	anchor: EntityRef | null = refs.at(-1) ?? null,
): SelectionState {
	return {
		anchor,
		selection: new Set(refs.map(entityKey)),
	};
}

Deno.test("set-selection owns a fresh set and follows its last member", () => {
	const supplied = new Set<EntityRefKey>([
		entityKey(peerA),
		entityKey(peerB),
	]);
	const result = selectionReducer(EMPTY_SELECTION, {
		kind: "set-selection",
		entities: supplied,
	});
	assert(result.selection !== supplied);
	assertEquals([...result.selection], [...supplied]);
	assertEquals(result.anchor, peerB);
});

Deno.test("add-to-selection keeps members and follows the latest addition", () => {
	const result = selectionReducer(state([peerA]), {
		kind: "add-to-selection",
		entities: new Set([entityKey(peerB)]),
	});
	assertEquals([...result.selection], [entityKey(peerA), entityKey(peerB)]);
	assertEquals(result.anchor, peerB);
});

Deno.test("remove-to-empty clears the Inspector anchor", () => {
	const result = selectionReducer(state([peerA]), {
		kind: "remove-from-selection",
		entities: new Set([entityKey(peerA)]),
	});
	assertEquals(result.selection.size, 0);
	assertEquals(result.anchor, null);
});

Deno.test("removing the anchor follows a surviving member", () => {
	const result = selectionReducer(state([peerA, peerB]), {
		kind: "remove-from-selection",
		entities: new Set([entityKey(peerB)]),
	});
	assertEquals([...result.selection], [entityKey(peerA)]);
	assertEquals(result.anchor, peerA);
});

Deno.test("empty selection clicks clear once; modified empty gestures do nothing", () => {
	assertEquals(selectionActionFor("replace", new Set()), {
		kind: "clear-on-empty-click",
	});
	assertEquals(selectionActionFor("add", new Set()), null);
	assertEquals(selectionActionFor("remove", new Set()), null);
	assertEquals(
		selectionReducer(state([peerA]), { kind: "clear-on-empty-click" }),
		EMPTY_SELECTION,
	);
});

Deno.test("selectionActionFor is the one modifier-mode interpreter", () => {
	const hits = new Set<EntityRefKey>([entityKey(peerA)]);
	assertEquals(selectionActionFor("replace", hits), {
		kind: "set-selection",
		entities: hits,
	});
	assertEquals(selectionActionFor("add", hits), {
		kind: "add-to-selection",
		entities: hits,
	});
	assertEquals(selectionActionFor("remove", hits), {
		kind: "remove-from-selection",
		entities: hits,
	});
});

Deno.test("rename-entity rewrites membership and only the matching anchor", () => {
	const result = selectionReducer(state([peerA, peerB], peerA), {
		kind: "rename-entity",
		entityKind: "peer",
		oldId: "a",
		newId: "renamed",
	});
	assertEquals([...result.selection], [entityKey(peerB), "peer:renamed"]);
	assertEquals(result.anchor, { kind: "peer", id: "renamed" });
});

Deno.test("reconcile-with-doc drops absent members and anchors", () => {
	const result = selectionReducer(
		state([peerA, { kind: "peer", id: "gone" }], {
			kind: "peer",
			id: "gone",
		}),
		{
			kind: "reconcile-with-doc",
			entities: { peers: { a: {} } },
		},
	);
	assertEquals([...result.selection], [entityKey(peerA)]);
	assertEquals(result.anchor, null);
});

Deno.test("reconcile-with-doc returns the same state when every identity remains", () => {
	const before = state([peerA, peerB]);
	const result = selectionReducer(before, {
		kind: "reconcile-with-doc",
		entities: { peers: { a: {}, b: {} } },
	});
	assert(result === before);
});

Deno.test("documentHolds reads declarations, including a session end", () => {
	const entities = {
		peers: { a: {} },
		sessions: { wire: {} },
		messages: { call: {} },
	};
	assert(documentHolds(entities, peerA));
	assert(documentHolds(entities, { kind: "session", id: "wire" }));
	assert(documentHolds(entities, { kind: "message", id: "call" }));
	assert(documentHolds(entities, { kind: "endpoint", id: "wire::a" }));
	assert(!documentHolds(entities, { kind: "endpoint", id: "gone::a" }));
});

Deno.test("Select All names each declared top-level identity once", () => {
	assertEquals(
		[...allEntityKeys({
			peers: { a: {}, b: {} },
			sessions: { wire: {} },
			messages: { call: {} },
		})],
		["peer:a", "peer:b", "session:wire", "message:call"],
	);
});

Deno.test("selectors decode members and report only real selection", () => {
	const selected = state([peerA, peerB]);
	assertEquals(selectionRefs(selected), [peerA, peerB]);
	assert(hasAnySelection(selected));
	assert(!hasAnySelection(EMPTY_SELECTION));
});
