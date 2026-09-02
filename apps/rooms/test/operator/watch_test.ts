import { type Ref, type Session } from "@glowcap/runtime";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { OPERATOR_CHANGED, OPERATOR_UNWATCH, OPERATOR_WATCH } from "../../lib/protocol_operator.ts";
import { subscribeOperator } from "../../lib/operator.ts";
import { DurableRoomsOperations } from "../../session/operations.ts";
import { MAX_OPERATOR_WATCHERS, OperatorRevision } from "../../server/operator/revision.ts";
import { assertEquals } from "../assert.ts";

type Observer = (verb: string, args: unknown[]) => unknown;

class FakeSession {
	sessionOpen = true;
	readonly released: Ref[] = [];
	readonly sends: { verb: string; args: unknown[] }[] = [];
	readonly tells: { verb: string; args: unknown[] }[] = [];
	observer: Observer | null = null;
	closeCallback: (() => void) | null = null;
	tellFailure: Error | null = null;
	tellBarrier: Promise<void> | null = null;
	fetchBarrier: Promise<void> | null = null;
	fetches = 0;
	releaseFailure: Error | null = null;
	stopCloseFailure: Error | null = null;

	onClose(callback: () => void): () => void {
		this.closeCallback = callback;
		return () => {
			if (this.closeCallback === callback) this.closeCallback = null;
			if (this.stopCloseFailure != null) throw this.stopCloseFailure;
		};
	}

	spawn(callback: Observer): Ref {
		this.observer = callback;
		return {} as Ref;
	}

	async fetch(_swiss: string): Promise<Ref> {
		this.fetches += 1;
		if (this.fetchBarrier != null) await this.fetchBarrier;
		return {} as Ref;
	}

	send(_target: Ref, verb: string, args: unknown[]): Promise<bigint> {
		this.sends.push({ verb, args });
		return Promise.resolve(0n);
	}

	async tell(_target: Ref, verb: string, args: unknown[]): Promise<null> {
		this.tells.push({ verb, args });
		if (this.tellBarrier != null) await this.tellBarrier;
		if (this.tellFailure != null) throw this.tellFailure;
		return null;
	}

	release(ref: Ref): void {
		this.released.push(ref);
		if (this.releaseFailure != null) throw this.releaseFailure;
	}
}

Deno.test("operator revision watchers notify, replace, and clean up at the bound", async () => {
	const operator = new OperatorRevision();
	const entries = Array.from({ length: MAX_OPERATOR_WATCHERS }, () => new FakeSession());
	try {
		for (const entry of entries) await operator.watch(entry as unknown as Session, {} as Ref);
		const overflow = new FakeSession();
		let refused = "";
		try {
			await operator.watch(overflow as unknown as Session, {} as Ref);
		} catch (error) {
			refused = error instanceof Error ? error.message : String(error);
		}
		assertEquals(refused, `this Rooms operator already has ${MAX_OPERATOR_WATCHERS} watchers`);
		assertEquals(overflow.released.length, 1);
		const replacement = entries[0]!;
		await operator.watch(replacement as unknown as Session, {} as Ref);
		assertEquals(replacement.released.length, 1);
		operator.noteChange();
		assertEquals(replacement.tells.at(-1)?.verb, OPERATOR_CHANGED);
		const closing = entries[1]!;
		closing.closeCallback!();
		assertEquals(closing.released.length, 1);
	} finally {
		for (const entry of entries) operator.dropWatcher(entry as unknown as Session);
		operator.dropWatcher(overflowSession(entries) as unknown as Session);
	}
});

Deno.test("an operator watch is not admitted when its initial callback fails", async () => {
	const operator = new OperatorRevision();
	const session = new FakeSession();
	session.tellFailure = new Error("callback unavailable");
	let reason = "";
	try {
		await operator.watch(session as unknown as Session, {} as Ref);
	} catch (error) {
		reason = error instanceof Error ? error.message : String(error);
	}
	assertEquals(reason, "callback unavailable");
	assertEquals(session.released.length, 1);
	const deliveries = session.tells.length;
	operator.noteChange();
	assertEquals(session.tells.length, deliveries);
});

Deno.test("an operator watch is not admitted if its session closes during the initial callback", async () => {
	const operator = new OperatorRevision();
	const session = new FakeSession();
	const barrier = Promise.withResolvers<void>();
	session.tellBarrier = barrier.promise;
	const watching = operator.watch(session as unknown as Session, {} as Ref);
	await Promise.resolve();
	session.closeCallback?.();
	barrier.resolve();
	let reason = "";
	try {
		await watching;
	} catch (error) {
		reason = error instanceof Error ? error.message : String(error);
	}
	assertEquals(reason, "the Rooms operator watch ended during admission");
	assertEquals(session.released.length, 1);
});

Deno.test("operator watcher release survives close-listener cleanup refusal", async () => {
	const operator = new OperatorRevision();
	const session = new FakeSession();
	await operator.watch(session as unknown as Session, {} as Ref);
	session.stopCloseFailure = new Error("close listener refused");
	const originalError = console.error;
	const errors: string[] = [];
	console.error = (message) => errors.push(String(message));
	try {
		operator.dropWatcher(session as unknown as Session);
	} finally {
		console.error = originalError;
	}
	assertEquals(session.released.length, 1);
	assertEquals(errors.some((message) => message.includes("close listener refused")), true);
});

function overflowSession(entries: readonly FakeSession[]): FakeSession {
	// The overflow watcher was refused and is not in the table. Return a harmless
	// fresh session so cleanup stays explicit without retaining a hidden global.
	return entries[0] ?? new FakeSession();
}

Deno.test("the client operator subscription validates callbacks and sends unwatch", async () => {
	const session = new FakeSession();
	const revisions: bigint[] = [];
	const stop = await subscribeOperator(session as unknown as Session, {} as Ref, (revision) => {
		revisions.push(revision);
	});
	assertEquals(session.sends[0]?.verb, OPERATOR_WATCH);
	await session.observer?.(OPERATOR_CHANGED, [7n]);
	assertEquals(revisions.length, 1);
	assertEquals(revisions[0] === 7n, true);
	stop();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(session.sends.at(-1)?.verb, OPERATOR_UNWATCH);
});

Deno.test("durable session operations subscribe while holding an operator capability", async () => {
	const session = new FakeSession();
	const invalidated: string[] = [];
	const operations = new DurableRoomsOperations(
		() => false,
		(scope) => invalidated.push(scope),
	);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		capabilities: {
			operations: [{ capability: "operator" as const, scope: "directory", swiss: "operator-swiss" }],
			archivePeer: null,
		},
	};
	const directory = { directory: { session: session as unknown as Session } };
	await operations.reconcile(checkpoint, new Map([["directory", directory as never]]));
	invalidated.length = 0;
	await session.observer?.(OPERATOR_CHANGED, [9n]);
	assertEquals(invalidated, ["directory"]);
	await operations.reconcile(emptyRoomsSessionState(), new Map());
	assertEquals(session.sends.some((call) => call.verb === OPERATOR_UNWATCH), true);
});

Deno.test("durable session operations take the bounded capability set concurrently", async () => {
	const session = new FakeSession();
	const barrier = Promise.withResolvers<void>();
	session.fetchBarrier = barrier.promise;
	const operations = new DurableRoomsOperations(() => false, () => {});
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		capabilities: {
			operations: [
				{ capability: "listeners" as const, scope: "directory", swiss: "listeners-swiss" },
				{ capability: "diagnostics" as const, scope: "directory", swiss: "diagnostics-swiss" },
			],
			archivePeer: null,
		},
	};
	const directory = { directory: { session: session as unknown as Session } };
	const reconciling = operations.reconcile(checkpoint, new Map([["directory", directory as never]]));
	await Promise.resolve();
	assertEquals(session.fetches, 2);
	barrier.resolve();
	await reconciling;
	operations.close();
});

Deno.test("a refused capability release cannot strand a held operations row", async () => {
	const session = new FakeSession();
	const operations = new DurableRoomsOperations(() => false, () => {});
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		capabilities: {
			operations: [{ capability: "listeners" as const, scope: "directory", swiss: "listeners-swiss" }],
			archivePeer: null,
		},
	};
	const directory = { directory: { session: session as unknown as Session } };
	await operations.reconcile(checkpoint, new Map([["directory", directory as never]]));
	assertEquals(session.fetches, 1);
	session.releaseFailure = new Error("release refused");
	const originalError = console.error;
	const errors: string[] = [];
	console.error = (message) => errors.push(String(message));
	try {
		await operations.reconcile(emptyRoomsSessionState(), new Map());
	} finally {
		console.error = originalError;
		session.releaseFailure = null;
	}
	assertEquals(errors.some((message) => message.includes("release refused")), true);
	await operations.reconcile(checkpoint, new Map([["directory", directory as never]]));
	assertEquals(session.fetches, 2);
	operations.close();
});

Deno.test("two operator revisions do not share watchers", async () => {
	const left = new OperatorRevision();
	const right = new OperatorRevision();
	const session = new FakeSession();
	await left.watch(session as unknown as Session, {} as Ref);
	right.noteChange();
	assertEquals(session.tells.filter((tell) => tell.verb === OPERATOR_CHANGED).length, 1);
	left.dropWatcher(session as unknown as Session);
});
