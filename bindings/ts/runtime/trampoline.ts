// The behavior trampoline: the ONE native callback in the whole binding. Every
// hosted object — a `Session.spawn`/`publish` actor, a caretaker or
// attenuator proxy, a host-wide giftable — registers here and shares a single
// process-lifetime `PancakeHostBehavior` whose ctx is the entry's registry id
// packed as a pointer-sized integer (free = NULL: the registry owns the JS
// side, so there is nothing for the library to free). Settlements never cross
// the C boundary as callbacks; they ride the action queue (SETTLE/FAIL).
//
// Reply discipline: the vat copies `out_reply`'s payload the instant the
// trampoline returns, so the encoded reply's buffers are retained in the
// module's one keep slot across the return (overwritten by the next reply —
// the previous one has long been copied). A thrown error crosses the boundary
// through `pancake_host_turn_break`, which settles the answer broken with the
// actor's own words — a bare non-OK return would flatten "Revoked" into a
// generic reason. A `Forward` return maps onto `pancake_host_turn_forward`
// (the caretaker/attenuator primitive): a target hosted by the same Host
// composes in process, a far target defers the answer onto the forwarded
// send's vow.

import { hostS } from "./internal/ffi/host.ts";
import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer, outU64, readBytes } from "./internal/seam.ts";
import { MAX_LOCAL_FORWARD_HOPS, OK } from "@pancake/abi";
import { FORWARD_CYCLE_MESSAGE } from "./internal/constants.ts";
import { checkHost, hostLastError, PancakeError, VowBroken } from "./errors.ts";
import { type Argument, type Behavior, Forward, Ref, refFromId } from "./value.ts";
import { encodeArgs, readArgArray, refStruct } from "./abi_value.ts";
import { type PromiseFactoryHandle, RemotePromise, sendFar } from "./promise.ts";

/** One hosted object's behavior and Host-local reference resolver. The
 * resolver lets a `Forward` chain, such as a caretaker over an attenuator,
 * compose in process. A giftable has no resolver until a session projects it
 * and records that Host identity in the shared hosted index. */
export interface BehaviorEntry {
	run: Behavior;
	/** Resolve a local Host capability id to its entry, or null when the entry
	 * has not joined the Host's local-composition index. */
	resolveLocal: ((refId: bigint) => BehaviorEntry | undefined) | null;
}

// One encoder/decoder pair for every turn: both are stateless here, and the
// trampoline is the binding's hottest path.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

// The process-global callback lookup is weak. Each live Host strongly owns its
// entries, so a behavior that closes over that Host remains a collectable
// Host-local cycle instead of becoming a process-global root. The C callback
// has free = NULL; Host.close removes rows deterministically when teardown
// begins, before native storage waits for admitted workers to stop.
const registry = new Map<bigint, WeakRef<BehaviorEntry>>();
let nextId = 1n;

/** Register a hosted object's behavior, returning the ctx id to pass as the
 * trampoline's ctx pointer. */
export function registerBehavior(entry: BehaviorEntry): bigint {
	const id = nextId++;
	registry.set(id, new WeakRef(entry));
	return id;
}

/** Drop a hosted entry after its Host is released. Binding-internal. */
export function unregisterBehavior(id: bigint): void {
	registry.delete(id);
}

/** The entry behind a ctx id, for in-process `Forward` composition. */
export function entryFor(id: bigint): BehaviorEntry | undefined {
	const entry = registry.get(id)?.deref();
	if (entry === undefined) registry.delete(id);
	return entry;
}

// Chase a behavior's result through the locally hosted `Forward` prefix:
// while it forwards to a near target the current entry's Host
// hosts, run that behavior in the same turn (a caretaker over an attenuator
// composes exactly as it does over the wire). Returns the terminal — a plain
// value (or void), or the first `Forward` whose target is not hosted here
// (far, promise, or an unknown near id). `runHosted` is the public face.
/** A behavior result carried between dispatch and settle: a plain value, a
 * forward, a bare ack, or an async behavior's pending promise. */
type BehaviorResult = Argument | Forward | void | PromiseLike<Argument | void>;

/** Whether a behavior's result is an async behavior's pending promise. */
function isThenable(result: BehaviorResult): result is PromiseLike<Argument | void> {
	return typeof (result as { then?: unknown } | null | undefined)?.then === "function";
}

function chaseLocalForwards(
	entry: BehaviorEntry,
	result: BehaviorResult,
): BehaviorResult {
	// The wire path defers each hop onto a fresh turn, so a forward cycle
	// there loops asynchronously; the local chase runs hops synchronously and
	// must bound them, or a caretaker forwarding to itself spins this loop
	// forever. Legitimate proxy chains are a handful deep.
	let hops = 0;
	while (result instanceof Forward) {
		if (++hops > MAX_LOCAL_FORWARD_HOPS) {
			throw new Error(FORWARD_CYCLE_MESSAGE);
		}
		const target = result.target;
		const inner = entry.resolveLocal !== null ? entry.resolveLocal(target.id) : undefined;
		if (inner === undefined) return result;
		entry = inner;
		result = inner.run(result.verb, result.args) as BehaviorResult;
	}
	return result;
}

/** Run the hosted object registered under `id` for `(verb, args)` and chase
 * its result through the locally hosted `Forward` prefix — the shared prefix
 * of every local dispatch (the trampoline, a local `send`, a local `tell`),
 * the Rust binding's `run_hosted`. A non-null `turn` runs the behavior and
 * the chase under that turn's context, so a turn-time `spawn` works and the
 * action drain defers. Undefined when nothing is registered under `id`. Each
 * caller keeps its own terminal for a surviving `Forward` (far, promise, or
 * an unknown near id): the trampoline defers it through the host's
 * turn-forward, a local send onto the forwarded send's reply, a local tell as
 * a far tell. */
export function runHosted(
	id: bigint,
	verb: string,
	args: Argument[],
	turn: Ptr | null = null,
): { result: BehaviorResult } | undefined {
	const entry = entryFor(id);
	if (entry === undefined) return undefined;
	if (turn === null) {
		return { result: chaseLocalForwards(entry, entry.run(verb, args)) };
	}
	// Every actor belongs to the Host Vat, so its turn belongs to whichever Port
	// delivered this call. The turn itself is the authority for that Port; the
	// binding only maps its borrowed session handle to the public wrapper.
	const outSession = new Uint8Array(8);
	checkHost(hostS.pancake_host_turn_session(turn, ab(outSession)));
	const session = activeDeliver?.turnSession(outPointer(outSession)) ?? null;
	activeDeliver?.trackTurnArguments(session, args);
	const prev = currentTurn;
	currentTurn = {
		turn,
		session,
		hostOwner: activeDeliver ?? null,
	};
	try {
		return { result: chaseLocalForwards(entry, entry.run(verb, args)) };
	} finally {
		currentTurn = prev;
	}
}

/** The local arm of `send`: run the hosted behavior on first observation and
 * settle from its result. A `Forward` to another object this side hosts
 * composes in process; a `Forward` to a far target defers via `forwardFar`
 * (Session.send) onto the forwarded send's reply (ADR-0064); a throw settles
 * broken with the behavior's own words. */
export function sendLocal(
	ctx: bigint,
	verb: string,
	args: Argument[],
	forwardFar: (
		target: Ref,
		verb: string,
		args: Argument[],
	) => Promise<Argument> | RemotePromise,
): RemotePromise {
	const begin = async (): Promise<Argument> => {
		try {
			const hosted = runHosted(ctx, verb, args);
			// Reached when the entry's connection tore down: `closeTransport`
			// unregisters every hosted actor and `Host.close` every giftable.
			// It agrees with the wire semantics (a trampoline breaks), so the
			// two dispatch paths cannot drift apart.
			if (hosted === undefined) throw new VowBroken("no such hosted object");
			const result = hosted.result;
			if (result instanceof Forward) {
				return await forwardFar(result.target, result.verb, result.args);
			}
			if (isThenable(result)) {
				// A local send to an async behavior simply awaits it; the
				// resolver machinery is only for wire-served turns.
				const value = await result;
				return value === undefined ? null : value;
			}
			return result === undefined ? null : result;
		} catch (err) {
			if (err instanceof PancakeError) throw err;
			throw new VowBroken(err instanceof Error ? err.message : String(err));
		}
	};
	return RemotePromise.local(begin);
}

/** The local arm of `tell`: run hosted, discard the result; a surviving
 * `Forward` continues as a far tell via `forwardFar`. A behavior failure has
 * no answer to break, so the Host retains it through `recordFailure`. */
export async function tellLocal(
	ctx: bigint,
	verb: string,
	args: Argument[],
	forwardFar: (target: Ref, verb: string, args: Argument[]) => Promise<void>,
	recordFailure: (error: unknown) => void,
): Promise<void> {
	let result: Argument | Forward | PromiseLike<Argument | void> | void;
	try {
		result = runHosted(ctx, verb, args)?.result;
		if (isThenable(result)) {
			// Await so an async behavior's rejection lands in this catch
			// instead of surfacing as an unhandled rejection.
			await result;
		}
	} catch (error) {
		recordFailure(error);
		return;
	}
	if (result instanceof Forward) {
		// The caller of `tell` remains the recipient for forwarding/I/O failure.
		await forwardFar(result.target, result.verb, result.args);
	}
}

/** Far tell mint: encode args, call `pancake_host_session_tell`, kick the drain. Local
 * targets stay behind `dispatchTell` / `tellLocal`. */
export async function tellFar(
	h: { ptr: Ptr; kickActions(): Promise<void> },
	target: Ref,
	verb: string,
	args: Argument[],
): Promise<void> {
	const verbBytes = utf8Encoder.encode(verb);
	const keep: Uint8Array[] = [];
	const argsBuf = encodeArgs(args, keep);
	checkHost(hostS.pancake_host_session_tell(
		h.ptr,
		ab(refStruct(target)),
		ab(verbBytes),
		BigInt(verbBytes.length),
		args.length ? ab(argsBuf) : new Uint8Array(0),
		BigInt(args.length),
	));
	await h.kickActions();
}

/** Near-hosted vs far send dispatch: a self-hosted near runs `sendLocal`,
 * everything else mints through `sendFar`. Session keeps guard/drain + the
 * CapTP verb; this owns the routing if. */
export function dispatchSend(
	hosted: Map<bigint, bigint>,
	factory: PromiseFactoryHandle,
	target: Ref | RemotePromise,
	verb: string,
	args: Argument[],
	recurse: (
		target: Ref | RemotePromise,
		verb: string,
		args: Argument[],
	) => RemotePromise,
): RemotePromise {
	if (target instanceof Ref) {
		const ctx = hosted.get(target.id);
		if (ctx !== undefined) {
			return sendLocal(ctx, verb, args, recurse);
		}
	}
	return sendFar(factory, target, verb, args);
}

/** Near-hosted vs far tell dispatch: a self-hosted near runs `tellLocal`,
 * everything else mints through `tellFar`. */
export async function dispatchTell(
	hosted: Map<bigint, bigint>,
	h: { ptr: Ptr; kickActions(): Promise<void> },
	target: Ref,
	verb: string,
	args: Argument[],
	recurse: (target: Ref, verb: string, args: Argument[]) => Promise<void>,
	recordFailure: (error: unknown) => void,
): Promise<void> {
	{
		const ctx = hosted.get(target.id);
		if (ctx !== undefined) {
			await tellLocal(ctx, verb, args, recurse, recordFailure);
			return;
		}
	}
	await tellFar(h, target, verb, args);
}

// The turn context while a hosted object's trampoline runs: the opaque
// `PancakeHostTurn*` and the Session whose Port delivered it, or null outside
// any turn. `Session.spawn` reads it to pick the turn-time spawn over the
// top-level one (which the host refuses inside a callback); `Host.kickActions`
// reads it to defer action drains to the enclosing verb's unwind.
let currentTurn: { turn: Ptr; session: object | null; hostOwner: object | null } | null = null;

// The Host whose drive is running, bracketed around either a byte-fed feed or a
// multi-session driver step. The callback turn supplies the ingress session;
// the Host maps that borrowed handle onto the binding's public wrapper.
export interface TurnHostOwner {
	turnSession(ptr: Ptr): object | null;
	trackTurnArguments(session: object | null, args: Argument[]): void;
	deferTurnToPromise(turn: Ptr, pending: PromiseLike<Argument | void>): boolean;
}

let activeDeliver: TurnHostOwner | null = null;

/** Enter a Host drive that may invoke behavior callbacks. The callback turn
 * identifies its own ingress session. Returns the prior owner to restore. */
export function enterDeliver(hostOwner: TurnHostOwner): TurnHostOwner | null {
	const prev = activeDeliver;
	activeDeliver = hostOwner;
	return prev;
}

/** Leave the current feed, restoring the enclosing one (or null). Binding-internal. */
export function exitDeliver(prev: TurnHostOwner | null): void {
	activeDeliver = prev;
}

/** The connection the currently running hosted turn arrived on, or null outside
 * any turn. `Session.currentSession()` casts it to the public `Session` type.
 * Binding-internal. */
export function currentTurnSession(): object | null {
	return currentTurn !== null ? currentTurn.session : null;
}

/** The current turn pointer when it belongs to `hostOwner`, else null. */
export function currentTurnFor(hostOwner: object): Ptr | null {
	return currentTurn !== null && currentTurn.hostOwner === hostOwner ? currentTurn.turn : null;
}

/** Whether ANY hosted turn is running — the drain defers while one is (the
 * host refuses the driving verbs inside a callback; everything enqueued pumps
 * when the enclosing call unwinds). */
export function insideTurn(): boolean {
	return currentTurn !== null;
}

// The most recent reply's encoded argument and its pinned child buffers,
// retained across the trampoline's return so the host's immediate copy reads
// live memory (a JIT may collect locals after their last use). One slot
// suffices: the host copies before any other JS code can run, so by the time
// this is overwritten the previous reply is long copied.
let lastReplyKeep: { buf: Uint8Array; keep: Uint8Array[] } | null = null;
void lastReplyKeep; // held for its liveness, never read

// Break this turn's answer with the actor's own diagnostic and return the code
// the trampoline hands back (OK: the break already settled the answer).
function turnBreak(turn: Ptr, message: string): number {
	const msg = utf8Encoder.encode(message);
	const rc = hostS.pancake_host_turn_break(turn, ab(msg), BigInt(msg.length));
	return rc === OK ? OK : rc;
}

// Resolve a behavior's chased terminal into the turn's answer: a plain value
// (or a bare void ack) encodes into the reply slot; a surviving `Forward` (its
// local prefix already composed by `runHosted`) defers through the host's
// turn-forward.
function settleReply(
	turn: Ptr,
	result: BehaviorResult,
	outReply: Ptr,
): number {
	if (isThenable(result)) {
		// An async behavior: defer this turn's answer onto a resolver vow and
		// settle it when the promise does (ADR-0102). The deferral needs the
		// owning Host, which the enclosing feed bracket carries.
		const owner = activeDeliver ?? undefined;
		if (owner === undefined || typeof owner.deferTurnToPromise !== "function") {
			return turnBreak(turn, "async behavior outside a session feed");
		}
		if (!owner.deferTurnToPromise(turn, result)) {
			return turnBreak(turn, hostLastError() ?? "deferral refused");
		}
		// The behavior's own reply is a void placeholder; the real answer
		// rides the resolver vow.
		const keep: Uint8Array[] = [];
		const buf = encodeArgs([null], keep);
		ffi.writeMemory(outReply, buf);
		lastReplyKeep = { buf, keep };
		return OK;
	}
	if (result instanceof Forward) {
		// The host forwards: the real answer rides the forwarded send's vow and
		// out_reply gets a void placeholder. Buffers stay pinned until it returns.
		const keep: Uint8Array[] = [];
		const verbBytes = utf8Encoder.encode(result.verb);
		const argsBuf = encodeArgs(result.args, keep);
		const rc = hostS.pancake_host_turn_forward(
			turn,
			ab(refStruct(result.target)),
			ab(verbBytes),
			BigInt(verbBytes.length),
			result.args.length ? ab(argsBuf) : new Uint8Array(0),
			BigInt(result.args.length),
			outReply,
		);
		if (rc !== OK) return turnBreak(turn, hostLastError() ?? "forward refused");
		return OK;
	}
	// A plain value (void normalizes to a bare null ack). The keep slot pins
	// the encoded struct and every child buffer it points at across the return.
	const keep: Uint8Array[] = [];
	const buf = encodeArgs([result === undefined ? null : result], keep);
	ffi.writeMemory(outReply, buf);
	lastReplyKeep = { buf, keep };
	return OK;
}

// The shared trampoline body: decode the deliver, run the entry under the turn
// context, and settle the reply. Every throw (an attenuator's "Attenuated", a
// revoked caretaker's "Revoked", an unknown-method error) crosses the boundary
// as a break carrying the message; nothing ever throws across the C frame.
function trampoline(
	ctx: Ptr,
	turn: Ptr,
	verbPtr: Ptr,
	verbLen: number | bigint,
	argsPtr: Ptr,
	argsLen: number | bigint,
	outReply: Ptr,
): number {
	try {
		const verb = BigInt(verbLen) === 0n ? "" : utf8Decoder.decode(readBytes(verbPtr, BigInt(verbLen)));
		const args = readArgArray(argsPtr, BigInt(argsLen));
		const hosted = runHosted(BigInt(ctx), verb, args, turn);
		if (hosted === undefined) return turnBreak(turn, "no such hosted object");
		return settleReply(turn, hosted.result, outReply);
	} catch (err) {
		return turnBreak(turn, err instanceof Error ? err.message : String(err));
	}
}

// The one native callback, created on first use and never closed (closing a
// trampoline from inside its own invocation frees it mid-call, and the host
// may deliver for as long as the process hosts objects). Deno and Bun register
// callbacks globally, so the runtime FFI mints it once for every archive.
let trampolineCb: { pointer: Ptr } | null = null;

/** The shared trampoline's native pointer, for publish/spawn calls. */
export function trampolinePointer(): Ptr {
	if (trampolineCb === null) {
		trampolineCb = ffi.makeCallback(
			{
				parameters: [
					"pointer",
					"pointer",
					"pointer",
					"usize",
					"pointer",
					"usize",
					"pointer",
				],
				result: "i32",
			},
			trampoline,
		);
	}
	return trampolineCb.pointer;
}

/** ADR-0064 caretaker: spawn a proxy that forwards to `target` until
 * `revoke()`, then breaks every call `Revoked`. */
export function caretakerProxy(
	spawn: (behavior: Behavior) => Ref,
	target: Ref,
): { proxy: Ref; revoke: () => void } {
	let live = true;
	const proxy = spawn((verb, args) => {
		if (!live) throw new Error("Revoked");
		return new Forward(target, verb, args);
	});
	return {
		proxy,
		revoke: () => {
			live = false;
		},
	};
}

/** ADR-0064 attenuator: spawn a proxy that forwards only allow-listed
 * verbs and breaks every other call `Attenuated`. */
export function attenuateProxy(
	spawn: (behavior: Behavior) => Ref,
	target: Ref,
	verbs: string[],
): Ref {
	const allowed = new Set(verbs);
	return spawn((verb, args) => {
		if (!allowed.has(verb)) throw new Error("Attenuated");
		return new Forward(target, verb, args);
	});
}

/** Session callbacks spawn/publish need without importing Session. */
export interface HostingHandle {
	guardOpen(): void;
	readonly ptr: Ptr;
	readonly hosted: Map<bigint, bigint>;
	registerBehavior(entry: BehaviorEntry): bigint;
	unregisterBehavior(id: bigint): void;
	/** Host identity used to select turn-time spawn on whichever Port arrived. */
	readonly hostOwner: object;
}

/** Register `behavior` in the trampoline registry as an actor of this
 * connection, so a Forward whose target this side hosts composes in
 * process and a turn it runs can spawn turn-time. */
function registerActor(h: HostingHandle, behavior: Behavior): bigint {
	const hosted = h.hosted;
	const entry: BehaviorEntry = {
		run: behavior,
		resolveLocal: (refId: bigint): BehaviorEntry | undefined => {
			const id = hosted.get(refId);
			return id === undefined ? undefined : entryFor(id);
		},
	};
	return h.registerBehavior(entry);
}

/** Register + mint a top-level or turn-time spawn; records the Host identity in
 * `hosted` so local Forward composition finds it. */
export function spawnHosted(h: HostingHandle, behavior: Behavior): Ref {
	const turn = currentTurnFor(h.hostOwner);
	if (turn === null) h.guardOpen();
	const ctx = registerActor(h, behavior);
	// free = NULL: the host never owns the row, so a refused mint must
	// unregister it here or it pins the behavior for the process's life.
	let refId: bigint;
	try {
		if (turn !== null) {
			refId = turnSpawn(turn, ctx);
		} else {
			const out = new Uint8Array(8);
			checkHost(hostS.pancake_host_session_spawn(
				h.ptr,
				trampolinePointer(),
				ctx,
				NULL,
				ab(out),
			));
			refId = outU64(out);
		}
	} catch (err) {
		h.unregisterBehavior(ctx);
		throw err;
	}
	h.hosted.set(refId, ctx);
	return refFromId(refId);
}

/** Register + publish by swiss name; records the Host identity in `hosted`. */
export function publishHosted(
	h: HostingHandle,
	name: string,
	behavior: Behavior,
): Ref {
	h.guardOpen();
	const ctx = registerActor(h, behavior);
	const swiss = utf8Encoder.encode(name);
	const out = new Uint8Array(8);
	// free = NULL: the host never owns the row, so a refused publish must
	// unregister it here or it pins the behavior for the process's life.
	try {
		checkHost(hostS.pancake_host_session_publish(
			h.ptr,
			ab(swiss),
			BigInt(swiss.length),
			trampolinePointer(),
			ctx,
			NULL,
			ab(out),
		));
	} catch (err) {
		h.unregisterBehavior(ctx);
		throw err;
	}
	const refId = outU64(out);
	h.hosted.set(refId, ctx);
	return refFromId(refId);
}

/** Spawn a hosted object from INSIDE a turn — the turn-time form the host
 * allows where the top-level spawn is refused. Returns its opaque Host id. */
export function turnSpawn(turn: Ptr, ctxId: bigint): bigint {
	const out = new Uint8Array(8);
	checkHost(hostS.pancake_host_turn_spawn(turn, trampolinePointer(), ctxId, NULL, ab(out)));
	return outU64(out);
}
