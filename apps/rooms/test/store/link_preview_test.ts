// Link preview gestures and asynchronous outcomes belong to one draft intent.
// These tests pin identity, removal, retry and stale completion independently
// from HTTP and React so a renderer cannot quietly redefine the state machine.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { previewSelection } = await import("../../web/ui/link_preview.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

function setup(name: string) {
	const projection = new store.PageProjection();
	const room = store.ensureRoom(projection, dirId(`preview-${name}`), name);
	store.switchTo(projection, room.key);
	return { projection, room };
}

Deno.test("unchanged targets preserve outcome and removal intent", () => {
	const { projection, room } = setup("stable");
	store.setDraft(projection, "See https://example.com/a");
	const offered = store.activeDraft(projection).previews[0];
	assert(offered?.state === "offered", "the Markdown link was not offered");
	const fetching = store.startDraftPreview(projection, room.key, offered.id);
	assert(fetching?.state === "fetching", "the offered intent did not start");
	store.settleDraftPreview(projection, room.key, offered.id, offered.attempt, {
		state: "ready",
		metadata: { requestedUrl: offered.url, url: offered.url, title: "Example", images: [] },
	});
	store.setDraft(projection, "Please see https://example.com/a now");
	const ready = store.activeDraft(projection).previews[0];
	assert(ready?.id === offered.id && ready.state === "ready", "unrelated typing replaced the completed effect");

	store.removeDraftPreview(projection, room.key, offered.id);
	store.setDraft(projection, "Please see https://example.com/a soon");
	const removed = store.activeDraft(projection).previews[0];
	assert(removed?.id === offered.id && removed.state === "removed", "typing resurrected a removed preview");
});

Deno.test("removing and re-adding a target creates fresh intent", () => {
	const { projection } = setup("readd");
	store.setDraft(projection, "https://example.com/a");
	const first = store.activeDraft(projection).previews[0]!;
	store.setDraft(projection, "no link");
	assert(store.activeDraft(projection).previews.length === 0, "a removed target stayed in the draft");
	store.setDraft(projection, "https://example.com/a");
	const second = store.activeDraft(projection).previews[0]!;
	assert(second.id !== first.id && second.state === "offered", "re-added URL reused stale suppression or outcome");
});

Deno.test("only the current attempt can settle or be cancelled", () => {
	const { projection, room } = setup("attempt");
	store.setDraft(projection, "https://example.com/a");
	const offered = store.activeDraft(projection).previews[0]!;
	store.startDraftPreview(projection, room.key, offered.id);
	store.settleDraftPreview(projection, room.key, offered.id, offered.attempt, {
		state: "failed",
		failure: { code: "temporary", summary: "Temporary", retry: "soon" },
	});
	store.retryDraftPreview(projection, room.key, offered.id);
	const retried = store.activeDraft(projection).previews[0]!;
	assert(retried.state === "offered" && retried.attempt === offered.attempt + 1, "retry did not mint an attempt");
	store.startDraftPreview(projection, room.key, retried.id);
	store.settleDraftPreview(projection, room.key, retried.id, offered.attempt, {
		state: "ready",
		metadata: { requestedUrl: retried.url, url: retried.url, title: "stale", images: [] },
	});
	assert(store.activeDraft(projection).previews[0]?.state === "fetching", "an old completion settled a new attempt");
	store.cancelDraftPreview(projection, room.key, retried.id, offered.attempt);
	assert(
		store.activeDraft(projection).previews[0]?.state === "fetching",
		"an old cancellation stopped a new attempt",
	);
	store.cancelDraftPreview(projection, room.key, retried.id, retried.attempt);
	assert(
		store.activeDraft(projection).previews[0]?.state === "offered",
		"current cancellation left a fetching state",
	);
});

Deno.test("targets stay ordered, bounded, and individually removable", () => {
	const { projection, room } = setup("many");
	store.setDraft(projection, "https://a.example https://b.example https://c.example");
	const previews = store.activeDraft(projection).previews;
	assert(previews.length === 3, "distinct Markdown links did not remain distinct");
	store.removeDraftPreview(projection, room.key, previews[1].id);
	const after = store.activeDraft(projection).previews;
	assert(
		after[0].state === "offered" && after[1].state === "removed" && after[2].state === "offered",
		"one removal changed sibling intents",
	);
});

Deno.test("line edits do not offer preview intents their protocol cannot apply", () => {
	const { projection } = setup("edit");
	store.setDraft(projection, "https://draft.example");
	store.startChange(projection, 7, "https://existing.example");
	assert(store.activeDraft(projection).previews.length === 0, "starting an edit retained an unrelated draft preview");
	store.setDraft(projection, "https://new.example");
	assert(store.activeDraft(projection).previews.length === 0, "typing in an edit offered a preview-only effect");
	store.cancelChange(projection);
	assert(store.activeDraft(projection).previews.length === 0, "cancelling an edit retained hidden preview state");
});

Deno.test("reader effects admit only the selected Markdown subset", () => {
	const text = "visible https://example.com/b then https://example.com/a";
	const selected = previewSelection(text, ["https://example.com/a", "https://example.com/b"]);
	assert(
		selected.join(" ") === "https://example.com/b https://example.com/a",
		"the shared selection authority did not restore authored order",
	);
	assert(
		previewSelection(text, ["https://unrelated.example"]).length === 0,
		"an archive-selected URL outside the visible Markdown could cause a fetch",
	);
	assert(
		previewSelection(text, ["https://example.com/a#fragment"]).length === 0,
		"a non-canonical selected spelling bypassed shared URL identity",
	);
});
