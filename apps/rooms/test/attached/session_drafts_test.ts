// Draft and send persistence through an attached durable session: staged
// text reaches the session, a stale failure cannot roll back newer local
// text, and a failed send restores its clear only while that clear is still
// the current act.

/// <reference lib="dom" />

import { assertEquals } from "../assert.ts";
import {
	addActiveDm,
	FakeController,
	resetStore,
	RoomsPage,
	sessionFor,
	store,
	waitForDraftSave,
} from "./semantics_support.ts";

Deno.test("attached mention edits pass through shared draft persistence", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	store.setDraft(page.projection, "hello");
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	session.mention("bo");
	const conversation = store.activeConv(page.projection);
	if (conversation == null || conversation.type === "directory") throw new Error("the fake DM was not active");
	assertEquals(store.activeDraft(page.projection).text, "hello @bo ");
	assertEquals(controller.stagedDrafts.get(conversation.persistId), "hello @bo ");
	await waitForDraftSave();
	assertEquals(controller.draftWrites.length, 1);
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("attached recall edits pass through shared draft persistence", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	const conversation = store.activeConv(page.projection);
	if (conversation == null || conversation.type === "directory") throw new Error("the fake DM was not active");
	store.rememberLastSent(page.projection, conversation.key, "say it again");
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	assertEquals(session.recallLastSent(), "say it again");
	assertEquals(store.activeDraft(page.projection).text, "say it again");
	assertEquals(controller.stagedDrafts.get(conversation.persistId), "say it again");
	await waitForDraftSave();
	assertEquals(controller.draftWrites.length, 1);
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("a failed draft write cannot roll back a newer same-text draft", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	session.setDraft("one");
	await waitForDraftSave();
	session.setDraft("two");
	session.setDraft("one");
	controller.draftWrites[0].reject(new Error("first write failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.activeDraft(page.projection).text, "one");
	await waitForDraftSave();
	assertEquals(controller.draftWrites.length, 2);
	controller.draftWrites[1].resolve(controller.current);
});

Deno.test("a failed send does not restore text after a newer local clear", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	store.setDraft(page.projection, "sent text");
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	session.send();
	session.setDraft("");
	controller.sends[0].reject(new Error("send failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.activeDraft(page.projection).text, "");
	await waitForDraftSave();
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("a failed send restores text when its clear is still current", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	store.setDraft(page.projection, "sent text");
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	session.send();
	controller.sends[0].reject(new Error("send failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.activeDraft(page.projection).text, "sent text");
	await waitForDraftSave();
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("a locally recoverable send is drawn before dispatch and retries the same intent", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	store.setDraft(page.projection, "visible intent");
	const controller = new FakeController();
	const session = sessionFor(page, controller, true);
	const conversation = store.activeConv(page.projection);
	if (conversation == null) throw new Error("the send fixture has no conversation");

	session.send();
	const pending = store.historyOf(page.projection, conversation.key).at(-1);
	assertEquals(pending?.kind === "chat" ? [pending.text, pending.state] : null, ["visible intent", "sending"]);
	assertEquals(store.activeDraft(page.projection).text, "");

	controller.sends[0].reject(new Error("send failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	const failed = store.historyOf(page.projection, conversation.key).at(-1);
	assertEquals(failed?.kind === "chat" ? failed.state : null, "failed");
	assertEquals(store.activeDraft(page.projection).text, "");

	session.retry(conversation.key, failed!.id);
	assertEquals(controller.sends.length, 2);
	const retried = store.historyOf(page.projection, conversation.key).at(-1);
	assertEquals(retried?.kind === "chat" ? [retried.id, retried.state] : null, [failed!.id, "sending"]);
});

// A send the runtime cannot confirm may already have reached the other side.
// The line it drew stays, marked unconfirmed rather than failed, and the draft
// is not put back, because sending it again could land it twice.
Deno.test("an unconfirmed send keeps its line and puts no draft back", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	store.setDraft(page.projection, "did this land");
	const controller = new FakeController();
	const session = sessionFor(page, controller, true);
	const conversation = store.activeConv(page.projection);
	if (conversation == null) throw new Error("the send fixture has no conversation");

	session.send();
	controller.sends[0].reject(new Error("delivery-uncertain: the peer went quiet mid-send"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	const drawn = store.historyOf(page.projection, conversation.key).at(-1);
	assertEquals(drawn?.kind === "chat" ? [drawn.text, drawn.state] : null, ["did this land", "unconfirmed"]);
	assertEquals(store.activeDraft(page.projection).text, "");
});

// The same holds where sends are not locally recoverable: a definite failure
// would put the text back here, an unconfirmed one must not.
Deno.test("an unconfirmed send keeps its line even where sends are not recoverable", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	store.setDraft(page.projection, "did this land");
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	const conversation = store.activeConv(page.projection);
	if (conversation == null) throw new Error("the send fixture has no conversation");
	session.send();
	controller.sends[0].reject(new Error("delivery-uncertain: the peer went quiet mid-send"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	const drawn = store.historyOf(page.projection, conversation.key).at(-1);
	assertEquals(drawn?.kind === "chat" ? drawn.state : null, "unconfirmed");
	assertEquals(store.activeDraft(page.projection).text, "");
});
