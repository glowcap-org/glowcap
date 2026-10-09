// Composer gestures keep the originating draft through delayed admission and completion.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import { type ManagedOperation, TerminalObservationError } from "../../web/ui/session/managed/operation.ts";
import type { CommandPowers } from "../../web/ui/commands.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { managedComposer } = await import("../../web/ui/session/managed/composer.ts");
const tick = async () => {
	for (let i = 0; i < 12; i++) await Promise.resolve();
};
function fixture(powers: Partial<CommandPowers> = {}) {
	const page = new RoomsPage();
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "directory");
	const first = store.ensureRoom(page.projection, directory, "first", { persistId: "first" });
	const second = store.ensureRoom(page.projection, directory, "second", { persistId: "second" });
	store.setRoomMembership(page.projection, first.key, "joined", "");
	store.switchTo(page.projection, first.key);
	const completion = Promise.withResolvers<void>();
	const drafts: [string, string][] = [];
	const commands: [string, string[]][] = [];
	let acquisitions = 0;
	const session = {
		pending: [],
		drafts: { stage: (id: string, text: string) => drafts.push([id, text]), flush: () => Promise.resolve() },
		command: (verb: string, args: string[]) => {
			commands.push([verb, args]);
			return Promise.resolve({ result: () => completion.promise } as unknown as ManagedOperation);
		},
		execute: async (
			_id: string,
			prepare: () => Promise<ManagedOperation>,
			complete: (op: ManagedOperation) => Promise<void>,
		) => complete(await prepare()),
		finish() {},
		actions: {
			acquireLine: async (_id: string, op: ManagedOperation) => {
				await op.result();
				acquisitions++;
			},
		},
	} as unknown as ManagedRoomsSession;
	const actions = managedComposer(
		page,
		session,
		{ you: () => "ada", standingHere: () => "", ...powers } as CommandPowers,
	);
	const close = () => {
		for (const row of [...page.projection.get().convs.values()]) store.forgetConv(page.projection, row.key);
	};
	return {
		page,
		directory,
		first,
		second,
		session,
		actions,
		completion,
		drafts,
		commands,
		acquisitions: () => acquisitions,
		close,
	};
}

for (const outcome of ["committed", "refused", "unknown", "terminal"] as const) {
	Deno.test(`managed send remains visible across pending admission and ${outcome} completion`, async () => {
		const f = fixture();
		try {
			if (outcome === "unknown") {
				f.session.execute = async (id, prepare, complete) => {
					(f.session.pending as string[]).push(id);
					await complete(await prepare());
				};
			}
			f.actions.setDraft("pending line");
			f.actions.send();
			await tick();
			const item = store.historyOf(f.page.projection, f.first.key).find((row) => row.kind === "chat");
			assertEquals(item?.kind === "chat" ? [item.text, item.state] : null, ["pending line", "sending"]);
			store.switchTo(f.page.projection, f.second.key);
			f.actions.setDraft("new conversation draft");
			if (outcome === "committed") f.completion.resolve();
			else {
				f.completion.reject(
					outcome === "terminal"
						? new TerminalObservationError("the original observation ended without delivery evidence")
						: new Error("original operation interrupted"),
				);
			}
			await tick();
			const lines = store.historyOf(f.page.projection, f.first.key).filter((row) => row.kind === "chat");
			assertEquals(lines.length, 1);
			assertEquals(
				lines[0].state,
				outcome === "committed" ? undefined : outcome === "refused" ? "failed" : "unconfirmed",
			);
			if (outcome === "terminal") assertEquals([f.session.pending, lines[0].retryable], [[], false]);
			assertEquals(store.activeDraft(f.page.projection).text, "new conversation draft");
			assertEquals(f.commands.length, 1);
		} finally {
			f.close();
		}
	});
}

Deno.test("delayed command refusal stays in the originating conversation and restores its draft", async () => {
	const reply = Promise.withResolvers<string | null>();
	const f = fixture({ joinLink: () => reply.promise });
	try {
		f.actions.setDraft("/join ocapn://127.0.0.1%3A1234.tcp/s/room/garden");
		const original = store.activeDraft(f.page.projection).text;
		f.actions.send();
		await tick();
		store.switchTo(f.page.projection, f.second.key);
		f.actions.setDraft("later typing");
		reply.resolve("That link did not open a room: the peer did not answer");
		await tick();
		assertEquals(
			store.historyOf(f.page.projection, f.first.key).filter((row) => row.kind === "sys").map((row) => row.text),
			["That link did not open a room: the peer did not answer"],
		);
		assertEquals(store.draftFor(f.page.projection, f.first.key).text, original);
		assertEquals(store.activeDraft(f.page.projection).text, "later typing");
		assertEquals(f.page.projection.get().toasts.length, 0);
	} finally {
		f.close();
	}
});

for (const outcome of ["accepted", "refused", "newer"] as const) {
	Deno.test(`managed submitted command clears immediately and preserves ${outcome} draft ownership`, async () => {
		const command = Promise.withResolvers<boolean>();
		const f = fixture({ unignore: () => command.promise, say: () => {} });
		try {
			f.actions.setDraft("/unignore ada");
			const original = store.activeDraft(f.page.projection);
			f.actions.send();
			assertEquals(store.activeDraft(f.page.projection).text, "");
			assertEquals(f.drafts.at(-1), ["first", ""]);
			if (outcome === "newer") f.actions.setDraft("@bo");
			if (outcome === "accepted") command.resolve(true);
			else command.reject(new Error("refused"));
			await tick();
			assertEquals(
				store.activeDraft(f.page.projection).text,
				outcome === "accepted" ? "" : outcome === "newer" ? "@bo" : original.text,
			);
			if (outcome === "refused") assertEquals(store.activeDraft(f.page.projection) === original, true);
		} finally {
			f.close();
		}
	});
}

Deno.test("queued command clears at submission, executes in order and preserves later typing", async () => {
	const command = Promise.withResolvers<boolean>();
	let calls = 0;
	const f = fixture({
		unignore: () => {
			calls++;
			return command.promise;
		},
		say: () => {},
	});
	try {
		f.actions.setDraft("earlier chat");
		f.actions.send();
		await tick();
		f.actions.setDraft("/unignore ada");
		f.actions.send();
		assertEquals(store.activeDraft(f.page.projection).text, "");
		assertEquals(calls, 0);
		f.actions.setDraft("@bo");
		f.completion.resolve();
		await tick();
		assertEquals(calls, 1);
		assertEquals(store.activeDraft(f.page.projection).text, "@bo");
		command.resolve(true);
		await tick();
		assertEquals(store.activeDraft(f.page.projection).text, "@bo");
	} finally {
		f.close();
	}
});

Deno.test("command waits for its draft clear admission before mutating the workspace", async () => {
	const saved = Promise.withResolvers<void>();
	let calls = 0;
	const f = fixture({
		unignore: () => {
			calls++;
			return true;
		},
		say: () => {},
	});
	try {
		f.session.drafts.flush = () => saved.promise;
		f.actions.setDraft("/unignore ada");
		f.actions.send();
		assertEquals(store.activeDraft(f.page.projection).text, "");
		await tick();
		assertEquals(calls, 0);
		saved.resolve();
		await tick();
		assertEquals(calls, 1);
		assertEquals(store.activeDraft(f.page.projection).text, "");
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
		f.session.execute = (id) => {
			Object.defineProperty(f.session, "pending", { configurable: true, value: [id] });
			return Promise.reject(new Error("admission acknowledgement lost"));
		};
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
		const line = store.historyOf(f.page.projection, f.first.key).find((item) => item.kind === "chat")!;
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
		f.session.execute = (id) => {
			operations.push(id);
			Object.defineProperty(f.session, "pending", { configurable: true, value: [...operations] });
			return Promise.reject(new Error("admission acknowledgement lost"));
		};
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

for (const newer of [false, true]) {
	Deno.test(`managed send commitment preserves ${newer ? "a newer draft" : "another conversation's draft"}`, async () => {
		const f = fixture();
		try {
			f.actions.setDraft("submitted");
			f.actions.send();
			await tick();
			assertEquals(f.commands[0].slice(0, 1), ["say"]);
			assertEquals(store.draftFor(f.page.projection, f.first.key).text, "");
			if (!newer) store.switchTo(f.page.projection, f.second.key);
			f.actions.setDraft("keep this");
			f.completion.resolve();
			await tick();
			assertEquals(f.acquisitions(), 1);
			assertEquals(store.activeDraft(f.page.projection).text, "keep this");
			assertEquals(store.draftFor(f.page.projection, f.first.key).text, newer ? "keep this" : "");
		} finally {
			f.close();
		}
	});
}

Deno.test("managed composer retains the next submitted draft while the previous effect is settling", async () => {
	const f = fixture();
	try {
		f.actions.setDraft("first");
		f.actions.send();
		await tick();
		f.actions.setDraft("second");
		f.actions.send();
		f.actions.send();
		assertEquals(f.commands.length, 1);
		assertEquals(store.activeDraft(f.page.projection).text, "");
		f.completion.resolve();
		await tick();
		await tick();
		assertEquals(f.commands.map(([, args]) => args[1]), ["first", "second"]);
		assertEquals(f.acquisitions(), 2);
		assertEquals(store.activeDraft(f.page.projection).text, "");
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
			return Promise.resolve({
				result: () => first ? f.completion.promise : Promise.resolve(),
			} as unknown as ManagedOperation);
		};
		f.session.execute = async (id, prepare, complete) => {
			if (f.session.pending.length === 0) (f.session.pending as string[]).push(id);
			await complete(await prepare());
		};
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
	} finally {
		f.close();
	}
});
Deno.test("managed refused send preserves the complete original draft", async () => {
	const f = fixture();
	try {
		f.actions.setDraft("retained caption");
		f.actions.send();
		await tick();
		store.switchTo(f.page.projection, f.second.key);
		f.actions.setDraft("other draft");
		f.completion.reject(new Error("refused by the exact source"));
		await tick();
		assertEquals(store.draftFor(f.page.projection, f.first.key).text, "retained caption");
		assertEquals(store.activeDraft(f.page.projection).text, "other draft");
		assertEquals(f.acquisitions(), 0);
	} finally {
		f.close();
	}
});

Deno.test("typing after a queued submission preserves both the send and the newer draft", async () => {
	const f = fixture();
	try {
		f.actions.setDraft("first");
		f.actions.send();
		await tick();
		f.actions.setDraft("queued");
		f.actions.send();
		f.actions.setDraft("keep this");
		f.completion.resolve();
		await tick();
		await tick();
		assertEquals(f.commands.map(([, args]) => args[1]), ["first", "queued"]);
		assertEquals(store.activeDraft(f.page.projection).text, "keep this");
	} finally {
		f.close();
	}
});

Deno.test("managed acknowledgement followed by draft-save refusal cannot resend the message", async () => {
	const f = fixture();
	try {
		f.actions.setDraft("one delivery");
		f.actions.send();
		await tick();
		f.session.drafts.flush = () => Promise.reject(new Error("storage unavailable"));
		f.completion.resolve();
		await tick();
		assertEquals(store.activeDraft(f.page.projection).text, "");
		f.actions.send();
		await tick();
		assertEquals(f.commands.length, 1);
		assertEquals(f.acquisitions(), 1);
	} finally {
		f.close();
	}
});

Deno.test("managed mention and recall stage exact text; directory drafts stay in this tab", async () => {
	const f = fixture();
	try {
		f.actions.setDraft("hello");
		f.actions.mention("bo");
		assertEquals(f.drafts.at(-1), ["first", "hello @bo "]);
		store.rememberLastSent(f.page.projection, f.first.key, "remembered");
		f.actions.setDraft("");
		assertEquals(f.actions.recallLastSent(), "remembered");
		assertEquals(f.drafts.at(-1), ["first", "remembered"]);
		const view = store.ensureDirectory(f.page.projection, f.directory);
		store.switchTo(f.page.projection, view.key);
		const writes = f.drafts.length;
		f.actions.setDraft("/help");
		assertEquals(store.activeDraft(f.page.projection).text, "/help");
		assertEquals(f.drafts.length, writes);
		await tick();
	} finally {
		f.close();
	}
});

Deno.test("managed composer preserves committed archive identity without claiming line authority", async () => {
	const f = fixture();
	const history = { source: "direct-archive", generation: "first", id: "7" };
	f.session.command = () =>
		Promise.resolve(
			{ result: () => Promise.resolve({ id: 7, line: null, history }) } as unknown as ManagedOperation,
		);
	try {
		f.actions.setDraft("direct message");
		f.actions.send();
		await tick();
		const item = store.historyOf(f.page.projection, f.first.key).find((row) => row.kind === "chat");
		assertEquals(item?.kind === "chat" ? [item.history, item.lineId, item.held, item.state] : null, [
			history,
			7,
			false,
			undefined,
		]);
	} finally {
		f.close();
	}
});

Deno.test("a file submitted behind pending text owns its sources and leaves later typing intact", async () => {
	const f = fixture();
	const file = new File(["queued bytes"], "queued.txt", { type: "text/plain" });
	let upload: unknown;
	f.session.refresh = () => Promise.resolve({ revision: "1" } as Awaited<ReturnType<typeof f.session.refresh>>);
	f.session.perform = async (_id, prepare) => await prepare() as unknown as ManagedOperation;
	const workspace: Pick<ManagedRoomsSession["workspace"], "prepareUpload"> = {
		prepareUpload: (_id, _revision, conversation, caption, _previews, sources) => {
			upload = { conversation, caption, sources: sources.length };
			// The real Wasm conversion consumes these wrappers. The fixture owns
			// that conversion boundary and releases the sources it observes.
			for (const source of sources) source.free();
			return Promise.resolve({ result: () => Promise.resolve() } as never);
		},
	};
	Object.defineProperty(f.session, "workspace", { value: workspace });
	try {
		const room = store.getConv(f.page.projection, f.first.key);
		if (room?.type !== "room") throw new Error("room fixture");
		store.put(f.page.projection, { ...room, grants: new Set(["files"]) });
		f.actions.setDraft("first text");
		f.actions.send();
		await tick();
		assertEquals(store.activeDraft(f.page.projection).text, "");
		store.addDraftFiles(f.page.projection, [file]);
		f.actions.send();
		assertEquals(store.activeDraft(f.page.projection).files, []);
		f.actions.setDraft("later typing");
		f.completion.resolve();
		for (let i = 0; i < 5; i++) await tick();
		assertEquals(upload, { conversation: "first", caption: "", sources: 1 });
		assertEquals(f.commands.map(([, args]) => args[1]), ["first text"]);
		assertEquals(store.activeDraft(f.page.projection).text, "later typing");
	} finally {
		f.close();
	}
});

for (const retainedReceipt of [false, true]) {
	Deno.test(`uncertain ${retainedReceipt ? "retained" : "terminal"} delivery does not restore a fresh sendable draft`, async () => {
		const f = fixture();
		if (retainedReceipt) {
			f.session.execute = async (id, prepare, complete) => {
				(f.session.pending as string[]).push(id);
				await complete(await prepare());
			};
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
