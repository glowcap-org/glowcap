// Link preview gestures and asynchronous outcomes belong to one draft intent.
// These tests pin identity, removal, retry and stale completion independently
// from HTTP and React so a renderer cannot quietly redefine the state machine.

/// <reference lib="dom" />

import "../support/match_media.ts";
import { assert } from "../assert.ts";
import { initializeApplication } from "../support/application.ts";

await initializeApplication();
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/directory.ts");
const { previewFailure, previewSelection, previewTargets } = await import("../../web/ui/link_preview.ts");
const { ROOMS_FAILURES } = await import("../../lib/failure_data.ts");

function setup(name: string, service: string | null = "http://rooms.example/") {
	const projection = new store.PageProjection();
	projection.set({ server: service == null ? null : { base: service, chosen: false, directory: null } });
	const room = store.ensureRoom(projection, dirId(`preview-${name}`), name);
	store.switchTo(projection, room.key);
	return { projection, room };
}

Deno.test("a page with no Rooms server offers no previews", () => {
	const { projection } = setup("unserved", null);
	store.setDraft(projection, "See https://example.com/a");
	assert(store.activeDraft(projection).previews.length === 0, "a preview was offered with nothing to fetch it");
});

Deno.test("unchanged targets preserve outcome and removal intent", () => {
	const { projection, room } = setup("stable");
	store.setDraft(projection, "See https://example.com/a");
	const offered = store.activeDraft(projection).previews[0];
	assert(offered?.state === "offered", "the Markdown link was not offered");
	const fetching = store.startDraftPreview(projection, room.key, offered.id);
	assert(fetching?.state === "fetching", "the offered intent did not start");
	store.settleDraftPreview(projection, room.key, offered.id, offered.attempt, {
		state: "ready",
		metadata: { requestedUrl: offered.url, title: "Example", images: [] },
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
		metadata: { requestedUrl: retried.url, title: "stale", images: [] },
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

Deno.test("malformed drafts and selections admit nothing they do not show", () => {
	assert(previewTargets("").length === 0, "an empty draft offered a preview");
	assert(
		previewTargets("no links at all, just ocapn://x and http:/broken").length === 0,
		"a non-link offered a preview",
	);
	assert(
		previewTargets("`https://example.com/code` and <https://example.com/a>").every((target) =>
			target.url !== "https://example.com/code"
		),
		"a link inside inline code offered a preview",
	);
	const text = "see https://example.com/a";
	assert(previewSelection(text, []).length === 0, "an empty selection admitted a link");
	assert(previewSelection(text, ["not a url"]).length === 0, "a non-URL selection admitted a fetch");
	assert(
		previewSelection(text, ["https://example.com/a", "https://example.com/a"]).length <= 1,
		"a repeated selection admitted the same fetch twice",
	);
});

Deno.test("a preview card names the host it opens, whatever its page says", async () => {
	const { renderToStaticMarkup } = await import("react-dom/server");
	const { createElement } = await import("react");
	const { PreviewLink } = await import("../../web/ui/panes/LinkPreviews.tsx");
	const drawn = (url: string, said: { title?: string; description?: string }) =>
		renderToStaticMarkup(
			createElement(PreviewLink, {
				service: "https://rooms.example",
				url,
				metadata: { requestedUrl: url, images: [], ...said },
			}),
		);
	const card = (url: string, host: string, copy: string) =>
		`<a href="${url}" target="_blank" rel="noopener noreferrer"><span class="link-preview-copy"><small><bdi dir="ltr">${host}</bdi></small>${copy}</span></a>`;
	for (
		const [url, said, host, copy] of [
			["https://example.org/x", { title: "bank.example" }, "example.org", "<strong>bank.example</strong>"],
			["https://example.org:8443/x", { title: "Sign in" }, "example.org:8443", "<strong>Sign in</strong>"],
			["http://[::1]:8080/", { description: "Local" }, "[::1]:8080", "<span>Local</span>"],
			["https://xn--bnk-6cd.example/", { title: "Bank" }, "xn--bnk-6cd.example", "<strong>Bank</strong>"],
		] as const
	) assert(drawn(url, said) === card(url, host, copy), `${url} drew ${drawn(url, said)}`);
	const lookalike = drawn("https://b\u0430nk.example/", { title: "Bank" });
	assert(
		/<small><bdi dir="ltr">xn--[a-z0-9-]+\.example<\/bdi><\/small>/.test(lookalike),
		`a name with a look-alike letter drew ${lookalike}`,
	);
});

Deno.test("a preview failure keeps the shared retry vocabulary", () => {
	const known = previewFailure({ code: "link-preview-failed", summary: "s", retry: "whenever" });
	assert(
		known.retry === ROOMS_FAILURES["link-preview-failed"].retry,
		"an unrecognized retry on a Rooms code did not fall back to that code's definition",
	);
	const unknown = previewFailure({ code: "from-somewhere-else", summary: "s", retry: 7 });
	assert(unknown.retry === "never", "an unknown code with an unrecognized retry was offered a retry");
	const kept = previewFailure({ code: "from-somewhere-else", summary: "s", retry: "after-state-change" });
	assert(kept.retry === "after-state-change", "a valid retry was not kept");
	const shapeless = previewFailure(new Error("boom"));
	assert(shapeless.code === "link-preview-failed", "a failure with no code and summary was not the fallback");
	const array = Object.assign([], { code: "array-code", summary: "not a failure object", retry: "soon" });
	assert(previewFailure(array).code === "link-preview-failed", "an array was admitted as a failure object");
});

Deno.test("malformed preview replies give a catalog refusal without granting retry advice", async () => {
	const { fetchPreview } = await import("../../web/ui/link_preview.ts");
	const { failureView } = await import("../../lib/text/failure.ts");
	const original = globalThis.fetch;
	try {
		for (const reply of [null, [], { ok: true, metadata: {} }, { ok: false }]) {
			globalThis.fetch = () => Promise.resolve(Response.json(reply));
			let failure: unknown;
			try {
				await fetchPreview("https://rooms.example/", "https://example.com/", new AbortController().signal);
			} catch (error) {
				failure = error;
			}
			assert(failureView(failure).code === "local-preview-unreadable", "malformed response escaped its catalog");
			assert(failureView(failure).retry === "never", "malformed response gained automatic retry advice");
			assert(
				previewFailure(failure).code === "local-preview-unreadable",
				"preview card lost the catalog refusal",
			);
			assert(
				previewFailure(failure).summary.includes("without a preview"),
				"preview card lost its recovery instruction",
			);
		}
	} finally {
		globalThis.fetch = original;
	}
});

Deno.test("a proxy HTTP failure keeps preview retry even when its body is HTML", async () => {
	const { fetchPreview } = await import("../../web/ui/link_preview.ts");
	const saved = globalThis.fetch;
	globalThis.fetch = () => Promise.resolve(new Response("<html>Bad gateway</html>", { status: 502 }));
	try {
		const [result] = await Promise.allSettled([
			fetchPreview("https://rooms.example/", "https://example.com/", new AbortController().signal),
		]);
		assert(result.status === "rejected", "HTTP failure must refuse the preview");
		const failure = previewFailure(result.reason);
		assert(failure.code === "link-preview-failed" && failure.retry === "soon", "the server failure needs Retry");
	} finally {
		globalThis.fetch = saved;
	}
});

Deno.test("a non-2xx typed preview refusal keeps the service's retry policy", async () => {
	const { fetchPreview } = await import("../../web/ui/link_preview.ts");
	const saved = globalThis.fetch;
	globalThis.fetch = () =>
		Promise.resolve(
			Response.json({
				ok: false,
				failure: { code: "link-preview-forbidden", summary: "Refused address", retry: "never" },
			}, { status: 403 }),
		);
	try {
		const [result] = await Promise.allSettled([
			fetchPreview("https://rooms.example/", "https://example.com/", new AbortController().signal),
		]);
		assert(result.status === "rejected", "service refusal must stay a refusal");
		assert(previewFailure(result.reason).retry === "never", "HTTP fallback must not replace structured advice");
		assert(previewFailure(result.reason).code === "link-preview-forbidden", "the service owns the code");
	} finally {
		globalThis.fetch = saved;
	}
});
