// A send whose outcome nobody knows yet keeps its own recovery, and a line
// that recovers lands once.
/// <reference lib="dom" />
import { assert, assertEquals } from "../../assert.ts";
import {
	type ManagedOperation,
	ResultAcquisitionError,
	TerminalObservationError,
} from "../../../web/ui/session/managed/operation.ts";
import { LocalRefusal } from "../../../lib/text/failure.ts";
import { fixture, store, tick } from "./fixture.ts";
import { fakeHandle } from "../../support/managed_link.ts";
import { initializeApplication } from "../../support/application.ts";

Deno.test("using the session draft starts fresh preview choices for an immediate send", async () => {
	await initializeApplication();
	const f = fixture();
	try {
		const projection = f.page.projection;
		projection.set({ server: { base: "http://rooms.example/", chosen: false, directory: null } });
		const url = "https://example.com/article";
		store.setDraft(projection, `Local words ${url}`);
		store.removeDraftPreview(projection, f.first.key, store.activeDraft(projection).previews[0]!.id);
		store.addDraftFiles(projection, [new File(["private"], "local.txt")]);
		const accepted = `Session words ${url}`;
		f.session.drafts.useSessionDraft = () => accepted;
		f.actions.useSessionDraft(f.first.key);
		const draft = store.activeDraft(projection);
		assertEquals([draft.text, draft.files.length, draft.previews.map((p) => p.state)], [accepted, 0, ["offered"]]);
		assertEquals(f.drafts, []);
		f.completion.resolve();
		f.actions.send();
		await tick();
		assertEquals(f.commands, [["say", ["first", accepted, JSON.stringify([url])]]]);
	} finally {
		f.close();
	}
});

Deno.test("an uncertain chat keeps its own recovery while a newly typed command executes", async () => {
	let recovered = 0;
	let commands = 0;
	const f = fixture({
		unignore: () => {
			commands++;
			return true;
		},
		say: () => {},
	});
	try {
		f.executing((id) => {
			Object.defineProperty(f.session, "pending", { configurable: true, value: [id] });
			return Promise.reject(new Error("admission acknowledgement lost"));
		});
		f.session.completeOperation = () => {
			recovered++;
			return Promise.resolve(true);
		};
		f.actions.setDraft("uncertain chat");
		f.actions.send();
		await tick();
		f.actions.setDraft("/unignore ada");
		f.actions.send();
		await tick();
		assertEquals(recovered, 0);
		assertEquals(commands, 1);
		assertEquals(store.activeDraft(f.page.projection).text, "");
		const line = store.historyOf(f.page.projection, f.first.key).find((item) => item.kind === "chat");
		assert(line != null, "the post is shown");
		f.actions.retry(f.first.key, line.id);
		await tick();
		assertEquals(recovered, 1);
		assertEquals(commands, 1);
	} finally {
		f.close();
	}
});

Deno.test("each uncertain line recovers its own receipt in one conversation", async () => {
	const f = fixture();
	const operations: string[] = [];
	const recovered: string[] = [];
	try {
		f.executing((id) => {
			operations.push(id);
			Object.defineProperty(f.session, "pending", { configurable: true, value: [...operations] });
			return Promise.reject(new Error("admission acknowledgement lost"));
		});
		f.session.completeOperation = (id) => {
			recovered.push(id);
			return Promise.resolve(true);
		};
		for (const text of ["first uncertain line", "second uncertain line"]) {
			f.actions.setDraft(text);
			f.actions.send();
			await tick();
		}
		const lines = store.historyOf(f.page.projection, f.first.key).filter((item) => item.kind === "chat");
		assertEquals(lines.map((line) => line.text), ["first uncertain line", "second uncertain line"]);
		assertEquals(recovered, []);
		for (const line of lines) {
			f.actions.retry(f.first.key, line.id);
			await tick();
		}
		assertEquals(recovered, operations);
	} finally {
		f.close();
	}
});

Deno.test("a queued line is independent of an earlier uncertain send", async () => {
	const f = fixture();
	try {
		f.session.command = (verb, args = []) => {
			f.commands.push([verb, args]);
			const first = f.commands.length === 1;
			return Promise.resolve(fakeHandle<ManagedOperation>({
				result: () => first ? f.completion.promise : Promise.resolve(),
			}));
		};
		f.executing(async (id, prepare, complete) => {
			if (f.session.pending.length === 0) (f.session.pending as string[]).push(id);
			await complete(await prepare(), f.after);
		});
		f.actions.setDraft("first uncertain line");
		f.actions.send();
		await tick();
		f.actions.setDraft("independent queued line");
		f.actions.send();
		f.completion.reject(new TerminalObservationError("original outcome remains unknown"));
		await tick();
		await tick();
		assertEquals(f.commands.map(([, args]) => args[1]), ["first uncertain line", "independent queued line"]);
		assertEquals(f.acquisitions(), 1);
		const lines = store.historyOf(f.page.projection, f.first.key).filter((item) => item.kind === "chat");
		assertEquals(lines.map((line) => line.state), ["unconfirmed", undefined]);
		assertEquals(lines[0].operation, f.session.pending[0]);
		assertEquals(store.activeDraft(f.page.projection).text, "");
		assertEquals(
			f.linesSettled,
			[["first", false], ["first", true]],
			"a line with an unknown outcome is not told as landed, and typing stops waiting on it",
		);
	} finally {
		f.close();
	}
});

Deno.test("a line that recovers tells typing it landed, and only once", async () => {
	const f = fixture();
	let recover: (() => Promise<void>) | null = null;
	try {
		f.executing(async (id, prepare, complete) => {
			Object.defineProperty(f.session, "pending", { configurable: true, value: [id] });
			const command = await prepare();
			recover = async () => {
				await complete(command, f.after);
			};
			throw new Error("admission acknowledgement lost");
		});
		f.session.completeOperation = async () => {
			await recover?.();
			return true;
		};
		f.actions.setDraft("uncertain line");
		f.actions.send();
		await tick();
		assertEquals([f.linesSettled, f.linesLanded], [[["first", false]], []], "typing waits on no unknown answer");
		const line = store.historyOf(f.page.projection, f.first.key).find((item) => item.kind === "chat");
		if (line == null) throw new Error("the uncertain line is shown");
		f.completion.resolve();
		f.actions.retry(f.first.key, line.id);
		await tick();
		assertEquals(f.linesLanded, ["first"], "the line ended what the member typed while it was uncertain");
		await f.session.completeOperation("the same result");
		assertEquals(f.linesLanded, ["first"], "a result that confirms again landed once");
	} finally {
		f.close();
	}
});

for (const retainedReceipt of [false, true]) {
	Deno.test(`uncertain ${retainedReceipt ? "retained" : "terminal"} delivery does not restore a fresh sendable draft`, async () => {
		const f = fixture();
		if (retainedReceipt) {
			f.executing(async (id, prepare, complete) => {
				(f.session.pending as string[]).push(id);
				await complete(await prepare(), f.after);
			});
		}
		try {
			f.actions.setDraft("uncertain message");
			f.actions.send();
			await tick();
			f.completion.reject(
				retainedReceipt ? new Error("interrupted") : new TerminalObservationError("no delivery evidence"),
			);
			await tick();
			assertEquals(store.activeDraft(f.page.projection).text, "");
			f.actions.send();
			await tick();
			assertEquals(f.commands.length, 1);
			const line = store.historyOf(f.page.projection, f.first.key).find((item) => item.kind === "chat");
			assertEquals(line?.kind === "chat" ? [line.state, line.retryable] : null, ["unconfirmed", retainedReceipt]);
		} finally {
			f.close();
		}
	});
}

for (const stage of ["admission observation", "acquisition"] as const) {
	Deno.test(`confirmed delivery survives ${stage} failure and receipt release`, async () => {
		const history = { source: "archive", generation: "original", id: "7" };
		const f = fixture({}, { id: 7, line: "original-result", history });
		let operation = "";
		f.executing(async (id, prepare, complete) => {
			operation = id;
			(f.session.pending as string[]).push(id);
			await complete(await prepare(), f.after);
		});
		f.session.actions.acquireLine = async (_id, command) => {
			throw new ResultAcquisitionError(
				await command.result(),
				new Error("original membership was replaced"),
				"acquire-result-workspace",
			);
		};
		if (stage === "admission observation") {
			const command = f.session.command.bind(f.session);
			f.session.command = async (...args) => {
				const operation = await command(...args);
				await operation.result();
				throw new ResultAcquisitionError(
					undefined,
					new Error("snapshot unavailable after commit"),
					"addressed-snapshot",
				);
			};
		}
		try {
			f.actions.setDraft("already delivered");
			f.actions.send();
			await tick();
			f.actions.setDraft("later draft");
			f.completion.resolve();
			await tick();
			const lines = () => store.historyOf(f.page.projection, f.first.key).filter((row) => row.kind === "chat");
			assertEquals(lines().map((row) => [row.text, row.state, row.lineId, row.history, row.held]), [
				["already delivered", undefined, undefined, stage === "acquisition" ? history : undefined, false],
			]);
			assertEquals(f.session.pending, [operation], "the original acquisition stays recoverable");
			store.releaseSentLine(f.page.projection, operation);
			assertEquals(lines()[0].state, undefined, "releasing editing authority cannot erase known delivery");
			assertEquals(store.activeDraft(f.page.projection).text, "later draft");
			assertEquals(f.commands.length, 1);
		} finally {
			f.close();
		}
	});
}

Deno.test("a send the session holds no trace of after the break shows as unconfirmed and gives its text back", async () => {
	const f = fixture();
	const operations: string[] = [];
	try {
		// The receipt is gone from the session, so the operation is finished and
		// no longer pending when the gesture hears of it.
		f.executing((id) => {
			operations.push(id);
			return Promise.reject(new LocalRefusal("receipt-lost"));
		});
		f.actions.setDraft("sent as the connection broke");
		f.actions.send();
		await tick();
		const line = store.historyOf(f.page.projection, f.first.key).find((item) => item.kind === "chat");
		assertEquals(line?.kind === "chat" ? [line.state, line.retryable] : null, ["unconfirmed", false]);
		assertEquals(store.activeDraft(f.page.projection).text, "sent as the connection broke");
		assertEquals(operations.length, 1, "it is not sent again");
	} finally {
		f.close();
	}
});
