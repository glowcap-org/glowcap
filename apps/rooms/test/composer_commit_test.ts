/// <reference lib="dom" />
import "./support/browser_application.ts";
// The Rust-owned attached controller finishes composer submissions through the shared commit path.

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { attachedCommandPowers } = await import("../web/ui/session/attached_command_powers.ts");
const { attachedComposerActions } = await import("../web/ui/session/attached_composer.ts");
function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("attached send empties the conversation that was composed", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const keep = store.ensureRoom(page.projection, directory, "keep", { persistId: "keep-id" });
	store.switchTo(page.projection, keep.key);
	store.setDraft(page.projection, "keep me");
	const leave = store.ensureRoom(page.projection, directory, "leave", { persistId: "leave-id" });
	store.switchTo(page.projection, leave.key);
	const controller = {
		stageDraft: () => {},
		setDraft: () => Promise.resolve(),
		scheduleDraft: () => Promise.resolve(),
		cancelDraftSave: () => {},
		retireDraft: () => {},
		leaveConversation: () => {
			store.forgetConv(page.projection, leave.key);
			store.switchTo(page.projection, keep.key);
			return Promise.resolve();
		},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never);
	const actions = attachedComposerActions(page.projection, controller as never, powers, () => {});
	actions.setDraft("/leave");
	actions.send();
	assert(
		store.draftFor(page.projection, keep.key).text === "keep me",
		"attached /leave emptied the next conversation's draft",
	);
});

for (const newerEdit of [false, true]) {
	Deno.test(`edit acknowledgement preserves ${newerEdit ? "a newer edit" : "another room's draft"}`, async () => {
		const page = new RoomsPage();
		const directory = dirId("edit-dir");
		store.openDir(page.projection, directory, "edit-dir");
		const room = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
		const other = store.ensureRoom(page.projection, directory, "second", { persistId: "second" });
		store.switchTo(page.projection, room.key);
		const item = { ...store.chatItem(page.projection, "me", "original", true), lineId: 1 };
		store.deliver(page.projection, room.key, item);
		store.startChange(page.projection, item.id, "submitted edit");
		const completion = Promise.withResolvers<void>();
		const saved: string[] = [];
		const controller = {
			cancelDraftSave: () => {},
			editLine: () => completion.promise,
			setDraft: (_id: string, text: string) => {
				saved.push(text);
				return Promise.resolve();
			},
		};
		const powers = attachedCommandPowers(page.projection, controller as never, {} as never);
		const actions = attachedComposerActions(page.projection, controller as never, powers, (error) => {
			throw error;
		});
		actions.send();
		if (!newerEdit) store.switchTo(page.projection, other.key);
		store.setDraft(page.projection, "keep this");
		completion.resolve();
		await completion.promise;
		await Promise.resolve();
		assert(store.activeDraft(page.projection).text === "keep this", "late edit erased current intent");
		assert(newerEdit ? saved.length === 0 : saved.length === 1, "late edit cleared a newer durable draft");
		if (!newerEdit) {
			assert(store.draftFor(page.projection, room.key).changing == null, "completed edit stayed open");
		}
	});
}

Deno.test("a refused file send restores its complete draft after switching rooms", async () => {
	const page = new RoomsPage();
	const directory = dirId("file-dir");
	store.openDir(page.projection, directory, "file-dir");
	const room = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
	const other = store.ensureRoom(page.projection, directory, "second", { persistId: "second" });
	store.switchTo(page.projection, room.key);
	store.setDraft(page.projection, "caption");
	const file = new File(["payload"], "example.txt", { type: "text/plain" });
	store.addDraftFiles(page.projection, [file]);
	const started = Promise.withResolvers<void>();
	const completion = Promise.withResolvers<void>();
	const failed = Promise.withResolvers<void>();
	const controller = {
		cancelDraftSave: () => {},
		stageDraft: () => {},
		scheduleDraft: () => Promise.resolve(),
		sendFiles: () => {
			started.resolve();
			return completion.promise;
		},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never);
	const actions = attachedComposerActions(page.projection, controller as never, powers, () => failed.resolve());
	actions.send();
	await started.promise;
	store.switchTo(page.projection, other.key);
	store.setDraft(page.projection, "sibling");
	completion.reject(new Error("refused"));
	await failed.promise;
	const restored = store.draftFor(page.projection, room.key);
	assert(restored.text === "caption" && restored.files[0] === file, "refused submission lost text or file custody");
	assert(store.activeDraft(page.projection).text === "sibling", "refusal changed sibling intent");
});

for (const succeeds of [false, true]) {
	Deno.test(`an asynchronous command ${succeeds ? "commits" : "refuses"} before clearing its draft`, async () => {
		const page = new RoomsPage();
		const directory = dirId("command-dir");
		store.openDir(page.projection, directory, "command-dir");
		const room = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
		store.switchTo(page.projection, room.key);
		store.setDraft(page.projection, "/msg alice");
		const completion = Promise.withResolvers<never>();
		const failed: unknown[] = [];
		const saved: string[] = [];
		const controller = {
			chooseDirect: () => completion.promise,
			cancelDraftSave: () => {},
			stageDraft: () => {},
			setDraft: (_id: string, text: string) => {
				saved.push(text);
				return Promise.resolve();
			},
		};
		const powers = attachedCommandPowers(page.projection, controller as never, {} as never);
		const actions = attachedComposerActions(
			page.projection,
			controller as never,
			powers,
			(error) => failed.push(error),
		);
		actions.send();
		assert(
			store.activeDraft(page.projection).text === "/msg alice",
			"command admission was mistaken for completion",
		);
		if (succeeds) completion.resolve(undefined as never);
		else completion.reject(new Error("registration refused"));
		await new Promise((resolve) => setTimeout(resolve, 0));
		assert(
			store.activeDraft(page.projection).text === (succeeds ? "" : "/msg alice"),
			"command outcome did not preserve draft ownership",
		);
		assert(failed.length === 0, "command refusal was duplicated as a toast");
		assert(
			store.historyOf(page.projection, room.key).some((item) =>
				item.kind === "sys" && item.text.includes("registration refused")
			) === !succeeds,
			"command refusal did not reach its conversation",
		);
		assert(saved.length === (succeeds ? 1 : 0), "refusal cleared durable intent");
	});
}

Deno.test("a synchronous command adapter failure stays in the generic failure path and preserves intent", () => {
	const page = new RoomsPage();
	const directory = dirId("sync-failure-dir");
	store.openDir(page.projection, directory, "sync-failure-dir");
	const room = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
	store.switchTo(page.projection, room.key);
	store.setDraft(page.projection, "/msg alice");
	const failures: unknown[] = [];
	const controller = {
		chooseDirect: () => {
			throw new Error("adapter failed before returning completion");
		},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never);
	const actions = attachedComposerActions(page.projection, controller as never, powers, (error) => {
		failures.push(error);
	});
	actions.send();
	assert(
		failures.length === 1 && failures[0] instanceof Error &&
			failures[0].message === "adapter failed before returning completion",
		"generic failure did not retain the adapter cause",
	);
	assert(store.activeDraft(page.projection).text === "/msg alice", "generic failure consumed the command intent");
});

Deno.test("failed draft persistence does not offer an acknowledged message for resend", async () => {
	const page = new RoomsPage();
	const directory = dirId("sent-dir");
	store.openDir(page.projection, directory, "sent-dir");
	const room = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
	store.switchTo(page.projection, room.key);
	store.setDraft(page.projection, "already delivered");
	const failed = Promise.withResolvers<void>();
	let writes = 0;
	const controller = {
		cancelDraftSave: () => {},
		stageDraft: () => {},
		say: () => {
			writes++;
			return Promise.resolve();
		},
		clearSentDraft: () => Promise.reject(new Error("storage unavailable")),
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never);
	attachedComposerActions(page.projection, controller as never, powers, () => failed.resolve()).send();
	await failed.promise;
	assert(
		writes === 1 && store.activeDraft(page.projection).text === "",
		"a post-send storage error restored an already delivered message",
	);
});

for (const retired of [false, true]) {
	Deno.test(`draft storage refusal ${retired ? "cannot revive a retired controller" : "preserves unsaved text"}`, async () => {
		const page = new RoomsPage();
		const directory = dirId("draft-dir");
		store.openDir(page.projection, directory, "draft-dir");
		const room = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
		store.switchTo(page.projection, room.key);
		const completion = Promise.withResolvers<void>();
		const staged: string[] = [];
		const failures: unknown[] = [];
		const controller = {
			closed: false,
			stageDraft: (_id: string, text: string) => {
				staged.push(text);
			},
			scheduleDraft: () => completion.promise,
		};
		const actions = attachedComposerActions(
			page.projection,
			controller as never,
			{} as never,
			(error) => failures.push(error),
		);
		actions.setDraft("unsaved text");
		controller.closed = retired;
		completion.reject(new Error("storage unavailable"));
		await new Promise((resolve) => setTimeout(resolve, 0));
		assert(store.activeDraft(page.projection).text === "unsaved text", "storage refusal erased intent");
		assert(staged.length === (retired ? 1 : 2), "draft staging crossed controller lifetime");
		assert(failures.length === (retired ? 0 : 1), "failure reporting crossed controller lifetime");
	});
}
