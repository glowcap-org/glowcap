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
// (the caretaker/attenuator primitive): a target hosted by the same session
// composes in process, a far target defers the answer onto the forwarded
// send's vow.

import { driverS } from "./internal/ffi/driver.ts";
import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, readBytes } from "./internal/seam.ts";
import { INVALID_ARGUMENT, MAX_LOCAL_FORWARD_HOPS, OK } from "./internal/abi.ts";
import { FORWARD_CYCLE_MESSAGE } from "./internal/constants.ts";
import { checkHost, hostLastError, PancakeError, VowBroken } from "./errors.ts";
import { type AppValue, type Behavior, Forward, liftArg, lowerArg, near, Ref } from "./value.ts";
import { encodeArgs, readArgArray, refStruct } from "./codec.ts";
import { type PromiseFactoryHandle, RemotePromise, sendFar } from "./promise.ts";

/** One hosted object: its behavior, and — for an actor bound to a connection —
 * how to resolve a near export position on that connection to another hosted
 * entry, so a `Forward` chain (a caretaker over an attenuator) composes in
 * process. A host-wide giftable carries neither: its forwards always go
 * through the host. */
export interface BehaviorEntry {
	run: Behavior;
	/** The connection this entry serves (identity only, for turn-ownership
	 * checks), or null for a host-wide giftable. */
	session: object | null;
	/** Resolve a near export position hosted by this entry's own connection to
	 * its entry, or undefined when this side does not host it. Null for a
	 * giftable. */
	resolveLocal: ((position: bigint) => BehaviorEntry | undefined) | null;
}

// One encoder/decoder pair for every turn: both are stateless here, and the
// trampoline is the binding's hottest path.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

// The registry: ctx id -> entry. Entries live as long as the host may deliver
// to them (a hosted object dies with its connection or host, and free = NULL
// means no teardown callback), the same posture as the Racket keep table.
const registry = new Map<bigint, BehaviorEntry>();
let nextId = 1n;

/** Register a hosted object's behavior, returning the ctx id to pass as the
 * trampoline's ctx pointer. */
export function registerBehavior(entry: BehaviorEntry): bigint {
	const id = nextId++;
	registry.set(id, entry);
	return id;
}

/** Drop a hosted entry the connection no longer answers for. Binding-internal:
 * teardown clears session-local actors so the registry does not pin dead behaviors. */
export function unregisterBehavior(id: bigint): void {
	registry.delete(id);
}

/** The entry behind a ctx id, for in-process `Forward` composition. */
export function entryFor(id: bigint): BehaviorEntry | undefined {
	return registry.get(id);
}

// Chase a behavior's result through the locally hosted `Forward` prefix:
// while it forwards to a near target the current entry's own connection
// hosts, run that behavior in the same turn (a caretaker over an attenuator
// composes exactly as it does over the wire). Returns the terminal — a plain
// value (or void), or the first `Forward` whose target is not hosted here
// (far, promise, or an unknown near id). `runHosted` is the public face.
function chaseLocalForwards(
	entry: BehaviorEntry,
	result: AppValue | Forward | void,
): AppValue | Forward | void {
	// The wire path defers each hop onto a fresh turn, so a forward cycle
	// there loops asynchronously; the local chase runs hops synchronously and
	// must bound them, or a caretaker forwarding to itself spins this loop
	// forever. Legitimate proxy chains are a handful deep.
	let hops = 0;
	while (result instanceof Forward) {
		if (++hops > MAX_LOCAL_FORWARD_HOPS) {
			throw new Error(FORWARD_CYCLE_MESSAGE);
		}
		const target = result.target.reference;
		const inner = target.kind === "near" && entry.resolveLocal !== null
			? entry.resolveLocal(target.id)
			: undefined;
		if (inner === undefined) return result;
		entry = inner;
		result = inner.run(result.verb, result.args) as AppValue | Forward | void;
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
	args: AppValue[],
	turn: Ptr | null = null,
): { result: AppValue | Forward | void } | undefined {
	const entry = registry.get(id);
	if (entry === undefined) return undefined;
	if (turn === null) {
		return { result: chaseLocalForwards(entry, entry.run(verb, args)) };
	}
	const prev = currentTurn;
	currentTurn = { turn, session: entry.session };
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
	args: AppValue[],
	forwardFar: (
		target: Ref,
		verb: string,
		args: AppValue[],
	) => Promise<AppValue> | RemotePromise,
): RemotePromise {
	const begin = async (): Promise<AppValue> => {
		try {
			const hosted = runHosted(ctx, verb, args);
			// The registry never removes entries, so this arm is dead today;
			// it agrees with the wire semantics (a trampoline breaks) so the
			// two dispatch paths cannot drift apart.
			if (hosted === undefined) throw new VowBroken("no such hosted object");
			const result = hosted.result;
			if (result instanceof Forward) {
				return await forwardFar(result.target, result.verb, result.args);
			}
			return result === undefined ? null : result;
		} catch (err) {
			if (err instanceof PancakeError) throw err;
			throw new VowBroken(err instanceof Error ? err.message : String(err));
		}
	};
	return new RemotePromise(null, begin, () => {
		throw new PancakeError(
			INVALID_ARGUMENT,
			"cannot project a local-send promise; await it for a value",
		);
	});
}

/** The local arm of `tell`: run hosted, discard the result; a surviving
 * `Forward` continues as a far tell via `forwardFar`. Throws break nothing. */
export async function tellLocal(
	ctx: bigint,
	verb: string,
	args: AppValue[],
	forwardFar: (target: Ref, verb: string, args: AppValue[]) => Promise<void>,
): Promise<void> {
	try {
		const result = runHosted(ctx, verb, args)?.result;
		if (result instanceof Forward) {
			await forwardFar(result.target, result.verb, result.args);
		}
	} catch {
		// no answer to break
	}
}

/** Far tell mint: encode args, enqueue `conn_tell`, kick the drain. Local
 * targets stay behind `dispatchTell` / `tellLocal`. */
export async function tellFar(
	h: { ptr: Ptr; kickActions(): Promise<void> },
	target: Ref,
	verb: string,
	args: AppValue[],
): Promise<void> {
	const verbBytes = utf8Encoder.encode(verb);
	const keep: Uint8Array[] = [];
	const argsBuf = encodeArgs(args.map(lowerArg), keep);
	checkHost(driverS.pancake_host_session_tell(
		h.ptr,
		ab(refStruct(target.reference)),
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
	args: AppValue[],
	recurse: (
		target: Ref | RemotePromise,
		verb: string,
		args: AppValue[],
	) => RemotePromise,
): RemotePromise {
	if (target instanceof Ref && target.reference.kind === "near") {
		const ctx = hosted.get(target.reference.id);
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
	args: AppValue[],
	recurse: (target: Ref, verb: string, args: AppValue[]) => Promise<void>,
): Promise<void> {
	if (target.reference.kind === "near") {
		const ctx = hosted.get(target.reference.id);
		if (ctx !== undefined) {
			await tellLocal(ctx, verb, args, recurse);
			return;
		}
	}
	await tellFar(h, target, verb, args);
}

// The turn context while a hosted object's trampoline runs: the opaque
// `PancakeHostTurn*` and the connection the turn arrived on (null for a
// giftable), or null outside any turn. `Session.spawn` reads it to pick the
// turn-time spawn over the top-level one (which the host refuses inside a
// callback); `Host.kickActions` reads it to defer action drains to the
// enclosing verb's unwind.
let currentTurn: { turn: Ptr; session: object | null } | null = null;

/** The current turn pointer when it belongs to connection `session`, else null. */
export function currentTurnFor(session: object): Ptr | null {
	return currentTurn !== null && currentTurn.session === session ? currentTurn.turn : null;
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
	const rc = driverS.pancake_host_turn_break(turn, ab(msg), BigInt(msg.length));
	return rc === OK ? OK : rc;
}

// Resolve a behavior's chased terminal into the turn's answer: a plain value
// (or a bare void ack) encodes into the reply slot; a surviving `Forward` (its
// local prefix already composed by `runHosted`) defers through the host's
// turn-forward.
function settleReply(
	turn: Ptr,
	result: AppValue | Forward | void,
	outReply: Ptr,
): number {
	if (result instanceof Forward) {
		// The host forwards: the real answer rides the forwarded send's vow and
		// out_reply gets a void placeholder. Buffers stay pinned until it returns.
		const keep: Uint8Array[] = [];
		const verbBytes = utf8Encoder.encode(result.verb);
		const argsBuf = encodeArgs(result.args.map(lowerArg), keep);
		const rc = driverS.pancake_host_turn_forward(
			turn,
			ab(refStruct(result.target.reference)),
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
	const buf = encodeArgs([result === undefined ? null : lowerArg(result)], keep);
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
		const verb = BigInt(verbLen) === 0n
			? ""
			: utf8Decoder.decode(readBytes(verbPtr, BigInt(verbLen)));
		const args = readArgArray(argsPtr, BigInt(argsLen)).map(liftArg);
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
	/** Session identity for turn-ownership and BehaviorEntry.session. */
	readonly turnOwner: object;
}

/** Register `behavior` in the trampoline registry as an actor of this
 * connection, so a Forward whose target this side hosts composes in
 * process and a turn it runs can spawn turn-time. */
function registerActor(h: HostingHandle, behavior: Behavior): bigint {
	const entry: BehaviorEntry = {
		run: behavior,
		session: h.turnOwner,
		resolveLocal: (position: bigint): BehaviorEntry | undefined => {
			const id = h.hosted.get(position);
			return id === undefined ? undefined : entryFor(id);
		},
	};
	return registerBehavior(entry);
}

/** Register + mint a top-level or turn-time spawn; records the export in
 * `hosted` so local Forward composition finds it. */
export function spawnHosted(h: HostingHandle, behavior: Behavior): Ref {
	h.guardOpen();
	const ctx = registerActor(h, behavior);
	const turn = currentTurnFor(h.turnOwner);
	let position: bigint;
	if (turn !== null) {
		position = turnSpawn(turn, ctx);
	} else {
		const out = new Uint8Array(8);
		checkHost(driverS.pancake_host_session_spawn(
			h.ptr,
			trampolinePointer(),
			ctx,
			NULL,
			ab(out),
		));
		position = new DataView(out.buffer).getBigUint64(0, true);
	}
	h.hosted.set(position, ctx);
	return new Ref(near(position));
}

/** Register + publish by swiss name; records the export in `hosted`. */
export function publishHosted(
	h: HostingHandle,
	name: string,
	behavior: Behavior,
): Ref {
	h.guardOpen();
	const ctx = registerActor(h, behavior);
	const swiss = utf8Encoder.encode(name);
	const out = new Uint8Array(8);
	checkHost(driverS.pancake_host_session_publish(
		h.ptr,
		ab(swiss),
		BigInt(swiss.length),
		trampolinePointer(),
		ctx,
		NULL,
		ab(out),
	));
	const position = new DataView(out.buffer).getBigUint64(0, true);
	h.hosted.set(position, ctx);
	return new Ref(near(position));
}

/** Spawn a hosted object at a fresh export position from INSIDE a turn — the
 * turn-time form the host allows where the top-level spawn is refused.
 * Returns the export position. */
export function turnSpawn(turn: Ptr, ctxId: bigint): bigint {
	const out = new Uint8Array(8);
	checkHost(driverS.pancake_host_turn_spawn(turn, trampolinePointer(), ctxId, NULL, ab(out)));
	return new DataView(out.buffer).getBigUint64(0, true);
}
