// The `RemotePromise` a Session send returns: immediate progress, lazy observation, promise
// pipelining target, and `index`/`untag`/`get` projection (ADR-0003 /
// ADR-0004). Also the shared fetch/enliven mint→await→classify
// path (`awaitMinted` / `asLiveRef`), the far-send mint→`promiseFor` path
// (`sendFar`), and RemotePromise construction. Session owns CapTP verb
// wrappers; trampoline owns Host-reference send·tell dispatch and local arms;
// this module owns the handle type, remote-send/post-mint choreography, and
// the projection FFI (`glowcap_host_vow_*`).

import { hostS } from "./internal/ffi/host.ts";
import type { Ptr } from "./internal/ffi/runtime.ts";
import { ab, outU64 } from "./internal/seam.ts";
import { INVALID_ARGUMENT, UNSUPPORTED_VALUE } from "@glowcap/abi";
import { checkHost, FetchFailed, GlowcapError, retainSecondaryFailure } from "./errors.ts";
import { encodeArgs, refStruct } from "./abi_value.ts";
import { releaseRef } from "./gc.ts";
import { type Argument, isReference, promiseArgument, Ref, refFromId } from "./value.ts";

/** The Session callbacks every vow wait needs, named here so this module stays
 * off the Session type itself (a direct dependency would form a promise ↔
 * session import cycle): register the minted vow, drive the inbound loop the
 * settle's bytes arrive on, kick the action drain, and await the drain-routed
 * outcome. */
export interface VowWaitHandle {
	readonly ptr: Ptr;
	vowMinted(vow: bigint, trackGc?: boolean): void;
	attend(): void;
	awaitVow(vow: bigint): Promise<Argument>;
	kickActions(): Promise<void>;
	parkVowRelease(vow: bigint): void;
}

/** The fetch/enliven wait adds an open-guard and a GC drain before the mint. */
export interface MintAwaitHandle extends VowWaitHandle {
	guardOpen(): void;
	drainGc(): void;
}

/** The far-send `promiseFor` / `sendFar` path adds the raw host handle its
 * `index` / `untag` / `get` projections mint sibling vows through. */
export interface PromiseFactoryHandle extends VowWaitHandle {
	readonly hostRaw: Ptr;
	readonly hostOwner: object;
	trackVow(handle: object, vow: bigint): void;
	scheduleProgress(): void;
	recordBackgroundFailure(failure: unknown): void;
}

const utf8Encoder = new TextEncoder();

/** Mint a sibling vow at `source` via `op:index` / `op:untag` / `op:get` (ADR-0004/0052). */
function projectVow(
	hostRaw: Ptr,
	source: bigint,
	op: "index" | "untag" | "get",
	key: string | bigint,
): bigint {
	const out = new Uint8Array(8);
	if (op === "index") {
		checkHost(hostS.glowcap_host_vow_index(
			hostRaw,
			source,
			key as bigint,
			ab(out),
		));
	} else {
		const bytes = utf8Encoder.encode(key as string);
		const fn = op === "get" ? hostS.glowcap_host_vow_get : hostS.glowcap_host_vow_untag;
		checkHost(fn(
			hostRaw,
			source,
			ab(bytes),
			BigInt(bytes.length),
			ab(out),
		));
	}
	return outU64(out);
}

/** Shared fetch/enliven wait: register the vow, keep the inbound loop running
 * (the completion's bytes arrive on it), kick the drain so the deliver leaves
 * now, and await the drain-routed outcome. */
export async function awaitMinted(
	h: VowWaitHandle,
	vow: bigint,
	trackGc: boolean,
): Promise<Argument> {
	try {
		h.vowMinted(vow, trackGc);
		h.attend();
		const settled = h.awaitVow(vow);
		await h.kickActions();
		const result = await settled;
		h.parkVowRelease(vow);
		return result;
	} catch (failure) {
		try {
			h.parkVowRelease(vow);
		} catch (cleanup) {
			retainSecondaryFailure(failure, cleanup);
		}
		throw failure;
	}
}

/** Classify a settled mint as an opaque Host capability. */
export function asLiveRef(result: Argument, label: string): Ref {
	if (!isReference(result)) {
		throw new FetchFailed(label);
	}
	return result;
}

/** The one mint/await/classify body under `fetch` and `enliven`: mint the
 * host vow with `mint`, drive the inbound loop for its completion, and
 * classify the settled value: anything but a live capability rejects with
 * `FetchFailed(label)`. */
export async function fetchLike(
	h: MintAwaitHandle,
	swiss: Uint8Array,
	label: string,
	mint: (
		session: Ptr,
		swiss: BufferSource,
		len: bigint,
		out: BufferSource,
	) => number,
	trackGc: boolean,
): Promise<Ref> {
	h.guardOpen();
	h.drainGc();
	const out = new Uint8Array(8);
	checkHost(mint(h.ptr, ab(swiss), BigInt(swiss.length), ab(out)));
	const vow = outU64(out);
	const result = await awaitMinted(h, vow, trackGc);
	return asLiveRef(result, label);
}

/** Adopt a freshly minted Host vow into one public wrapper. Registration,
 * wrapper construction, inbound attendance, and progress scheduling either
 * all acquire owners or park FFI release before the failure escapes. */
export function promiseFor(
	h: PromiseFactoryHandle,
	vow: bigint,
	pipelineable = true,
): RemotePromise {
	const begin = async (): Promise<Argument> => {
		h.attend(); // the settle's bytes arrive on the inbound loop
		const settled = h.awaitVow(vow);
		await h.kickActions();
		return await settled;
	};
	const project = (
		op: "index" | "untag" | "get",
		key: string | bigint,
	): RemotePromise => {
		const projected = projectVow(h.hostRaw, vow, op, key);
		return promiseFor(h, projected);
	};
	try {
		h.vowMinted(vow, true);
		const promise = pipelineable
			? RemotePromise.far(vow, h.hostOwner, begin, project)
			: RemotePromise.observer(vow, begin);
		h.attend();
		h.scheduleProgress();
		// Last fallible adoption step: after registration succeeds, returning
		// the wrapper transfers the FFI vow to its finalizer.
		h.trackVow(promise, vow);
		return promise;
	} catch (failure) {
		try {
			h.parkVowRelease(vow);
		} catch (cleanup) {
			retainSecondaryFailure(failure, cleanup);
		}
		throw failure;
	}
}

/** `Session.listen`'s wire half: mint the listen vow over a held far reference
 * (CapTP `op:listen`, ADR-0003) and hand back the settle handle. The Session API
 * owns profile-specific target legality. The vow is plain: a listen may settle
 * to any value, not only a capability. */
export function listenFar(h: PromiseFactoryHandle, target: Ref): RemotePromise {
	const out = new Uint8Array(8);
	checkHost(hostS.glowcap_host_session_listen(h.ptr, ab(refStruct(target)), ab(out)));
	const vow = outU64(out);
	return promiseFor(h, vow, false);
}

/** What a far promise passes as (ADR-0068): the capability its Host mints
 * for the vow, in whatever state the vow is in while this handle lives, one
 * application retain pushed on `minted` for the caller to give back.
 * `glowcap_host_vow_capability` says what the partner receives. */
function lowerPromise(h: PromiseFactoryHandle, promise: RemotePromise, minted: Ref[]): Ref {
	const vow = promise.farVow(h.hostOwner);
	const out = new Uint8Array(8);
	checkHost(hostS.glowcap_host_vow_capability(h.hostRaw, vow, ab(out)));
	const ref = refFromId(outU64(out));
	minted.push(ref);
	return ref;
}

/** Far send or tell arguments encoded for the FFI, with each promise among
 * them lowered to the capability its Host mints (ADR-0068). The Host's queue holds its own retain once the call is
 * admitted, so `release` gives every minted retain back right after the FFI
 * call, admitted or refused. A promise another Host returned, an await-only
 * one, and a plain Promise are refused before any frame moves. */
function encodeFarArgs(
	h: PromiseFactoryHandle,
	args: Argument[],
	keep: Uint8Array[],
): { readonly buf: Uint8Array; release(): void } {
	const minted: Ref[] = [];
	const release = () => {
		let failure: unknown;
		for (const ref of minted.splice(0)) {
			try {
				releaseRef(h.hostRaw, ref);
			} catch (error) {
				failure = failure === undefined ? error : retainSecondaryFailure(failure, error);
			}
		}
		if (failure !== undefined) throw failure;
	};
	try {
		const buf = encodeArgs(args, keep, (promise) => {
			if (!(promise instanceof RemotePromise)) {
				throw new GlowcapError(
					UNSUPPORTED_VALUE,
					"only the promise a send returned is passable as a capability",
				);
			}
			return lowerPromise(h, promise, minted);
		});
		return { buf, release };
	} catch (failure) {
		try {
			release();
		} catch (cleanup) {
			retainSecondaryFailure(failure, cleanup);
		}
		throw failure;
	}
}

/** Run one FFI call over far arguments and give their minted retains back on
 * every exit. Beside a refusal, a release failure rides it as a secondary.
 * After an admitted call, whose effect stands, a release failure is the
 * Host's to report. */
export function withFarArgs<T>(
	h: PromiseFactoryHandle,
	args: Argument[],
	call: (argsBuf: Uint8Array) => T,
): T {
	const keep: Uint8Array[] = [];
	const encoded = encodeFarArgs(h, args, keep);
	let result: T;
	try {
		result = call(encoded.buf);
	} catch (failure) {
		try {
			encoded.release();
		} catch (cleanup) {
			retainSecondaryFailure(failure, cleanup);
		}
		throw failure;
	}
	try {
		encoded.release();
	} catch (cleanup) {
		h.recordBackgroundFailure(cleanup);
	}
	return result;
}

/** Far-send mint→`RemotePromise`: encode args, mint the host vow
 * (`glowcap_host_session_send` / `glowcap_host_vow_send`), register it, and
 * hand back `promiseFor`.
 * Local-hosted targets stay in Session (trampoline `sendLocal`). */
export function sendFar(
	h: PromiseFactoryHandle,
	target: Ref | RemotePromise,
	verb: string,
	args: Argument[],
): RemotePromise {
	const verbBytes = utf8Encoder.encode(verb);
	const out = new Uint8Array(8);
	withFarArgs(h, args, (argsBuf) => {
		if (target instanceof RemotePromise) {
			// Promise pipelining: eventual-send to the unresolved answer. A local
			// send's promise has no wire answer to pipeline against.
			const sourceVow = target.farVow(h.hostOwner);
			checkHost(hostS.glowcap_host_vow_send(
				h.hostRaw,
				sourceVow,
				ab(verbBytes),
				BigInt(verbBytes.length),
				ab(argsBuf),
				BigInt(args.length),
				ab(out),
			));
		} else {
			checkHost(hostS.glowcap_host_session_send(
				h.ptr,
				ab(refStruct(target)),
				ab(verbBytes),
				BigInt(verbBytes.length),
				ab(argsBuf),
				BigInt(args.length),
				ab(out),
			));
		}
	});
	const vow = outU64(out);
	return promiseFor(h, vow);
}

/** The handle `Session.send` returns: the eventual result of one eventual-send,
 * and (the point of promise pipelining, ADR-0003) a target you can `send` to
 * before it resolves.
 *
 * It is a real `Promise`, so `await session.send(...)`, `Promise.all(...)`, and
 * `instanceof Promise` all work natively. Pass it *unawaited* as the `target`
 * of a later `send` to address the object the answer will resolve to: the
 * dependent call rides a `desc:answer` deliver and the partner queues it until
 * the answer settles, so a `create -> use` chain costs one round trip::
 *
 *     const task = session.send(root, "create", ["x"]);       // not awaited
 *     session.send(task, "assign", ["alice"]);                // pipelined
 *     const status = await session.send(task, "status", []);  // settles the chain
 *
 * The send schedules Host progress when this is created, so an unobserved
 * eventual-send still leaves the process. Synchronous chains enqueue before
 * that scheduled drain runs and therefore retain batching. Prefer
 * `Session.tell` when no answer is needed. Because the settle is drain-routed and no rejection
 * is materialized until the handle is observed, an unawaited anchor whose far
 * answer *breaks* never raises an unhandled rejection. State is a sum
 * (`far` | `observer` | `local` | `failed`), not a nullable vow flag.
 * A pipeline target belongs to the Host that minted it; another Host refuses
 * it before interpreting the Host-local vow number.
 *
 * The projection verbs `index`/`untag`/`get` (ADR-0004) pipeline an
 * element, untag, or Struct-field access *at the answer*, before it resolves:
 * each returns a new `RemotePromise` for the projected value, addressed at this
 * answer, so `task.untag("cell").index(0)` or `task.get("name")` costs no
 * extra round trip. */
export type PromiseState =
	| { readonly tag: "far"; readonly vow: bigint; readonly hostOwner: object }
	| { readonly tag: "observer"; readonly vow: bigint }
	| { readonly tag: "local" }
	// A send that could not be issued at all (a closed session, an argument
	// that would not lower). It is a state rather than a thrown error because
	// `send` must return its handle *synchronously*, so pipelining can project
	// at the answer before it settles (ADR-0004). Throwing instead would put a
	// synchronous failure channel on a promise-returning method, and a caller's
	// `.catch` could not see it.
	| { readonly tag: "failed"; readonly error: unknown };

export class RemotePromise extends Promise<Argument> {
	/** A promise is a passable send argument in any state (ADR-0068). */
	readonly [promiseArgument]: true = true;
	readonly #state: PromiseState;
	readonly #begin: () => Promise<Argument>;
	#started = false;
	readonly #resolve: (value: Argument | PromiseLike<Argument>) => void;
	readonly #reject: (reason?: unknown) => void;
	// Issues a projection op (index/untag/get) at this vow; set only for far.
	readonly #project:
		| ((op: "index" | "untag" | "get", key: string | bigint) => RemotePromise)
		| undefined;

	private constructor(
		state: PromiseState,
		begin: () => Promise<Argument>,
		project?: (op: "index" | "untag" | "get", key: string | bigint) => RemotePromise,
	) {
		// The executor only captures settlement functions. The factory schedules
		// progress after construction; observation controls only result delivery.
		let resolve!: (value: Argument | PromiseLike<Argument>) => void;
		let reject!: (reason?: unknown) => void;
		super((res, rej) => {
			resolve = res;
			reject = rej;
		});
		this.#state = state;
		this.#begin = begin;
		this.#resolve = resolve;
		this.#reject = reject;
		this.#project = project;
	}

	/** A far answer that settles a host vow (pipelinable). */
	static far(
		vow: bigint,
		hostOwner: object,
		begin: () => Promise<Argument>,
		project: (op: "index" | "untag" | "get", key: string | bigint) => RemotePromise,
	): RemotePromise {
		return new RemotePromise({ tag: "far", vow, hostOwner }, begin, project);
	}

	/** A local-send handle (not pipelinable). */
	static local(begin: () => Promise<Argument>): RemotePromise {
		return new RemotePromise({ tag: "local" }, begin);
	}

	/** An await-only FFI vow whose answer is local observation state. */
	static observer(vow: bigint, begin: () => Promise<Argument>): RemotePromise {
		return new RemotePromise({ tag: "observer", vow }, begin);
	}

	/** A handle for a send that never left: awaiting it rejects with `error`,
	 * and projecting at it yields another failed handle carrying the same
	 * reason, so a pipeline built behind a dead anchor fails where it is
	 * awaited rather than where it was written. */
	static failed(error: unknown): RemotePromise {
		// The begin thunk is what rejects, and it runs only on observation, so
		// a handle nobody awaits is not an unhandled rejection. Projection is
		// answered by `#projectOp` from the state, not by a thunk.
		return new RemotePromise({ tag: "failed", error }, () => Promise.reject(error));
	}

	/** Host vow when far; `null` when local (convenience, not the discriminant). */
	get vow(): bigint | null {
		return this.#state.tag === "far" || this.#state.tag === "observer" ? this.#state.vow : null;
	}

	/** The host vow for pipelining, or a typed refusal when this is local. */
	farVow(hostOwner: object): bigint {
		// A failed handle keeps its own reason rather than reporting the
		// generic local-send refusal, so a caller sees why the send never left.
		if (this.#state.tag === "failed") throw this.#state.error;
		if (this.#state.tag !== "far") {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				"this promise is await-only and has no remote pipeline target",
			);
		}
		if (this.#state.hostOwner !== hostOwner) {
			throw new GlowcapError(INVALID_ARGUMENT, "this promise belongs to another Host");
		}
		return this.#state.vow;
	}

	#projectOp(op: "index" | "untag" | "get", key: string | bigint): RemotePromise {
		// A pipeline behind a send that never left is itself a send that never
		// left. Carrying the same reason forward means the whole chain fails
		// where it is awaited rather than throwing at the link that was
		// written, which is the difference between one `.catch` and none.
		if (this.#state.tag === "failed") return RemotePromise.failed(this.#state.error);
		if (this.#state.tag !== "far" || this.#project === undefined) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				"this promise is await-only and cannot be projected",
			);
		}
		return this.#project(op, key);
	}

	/** Pipeline an `op:index` for `i` at this answer (ADR-0004): a new
	 * `RemotePromise` for the List element of whatever this resolves to. */
	index(i: number | bigint): RemotePromise {
		return this.#projectOp("index", BigInt(i));
	}

	/** Pipeline an `op:untag` for `tag` at this answer (ADR-0004): a new
	 * `RemotePromise` for the payload of whatever this resolves to, which must
	 * be a Tagged record whose tag equals `tag`. */
	untag(tag: string): RemotePromise {
		return this.#projectOp("untag", tag);
	}

	/** Pipeline an `op:get` for `field` at this answer (ADR-0004): a new
	 * `RemotePromise` for the Struct field of whatever this resolves to. */
	get(field: string): RemotePromise {
		return this.#projectOp("get", field);
	}

	// First observation issues the send's flush + reply wait, exactly once; the
	// FFI promise caches the settlement so repeated awaits share it. `catch`
	// and `finally` are inherited from `Promise` and delegate to this `then`, so
	// observing through any of them triggers the send.
	override then<R1 = Argument, R2 = never>(
		onFulfilled?: ((value: Argument) => R1 | PromiseLike<R1>) | null,
		onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
	): Promise<R1 | R2> {
		if (!this.#started) {
			this.#started = true;
			this.#begin().then(this.#resolve, this.#reject);
		}
		return super.then(onFulfilled, onRejected);
	}

	// Required, not decorative. `then`/`catch`/`finally` build their result
	// promise via `this.constructor[Symbol.species]`; without this, the platform
	// would call `new RemotePromise(executor)` against the `(vow, begin)`
	// constructor and every chained reaction would break. Returning `Promise`
	// also keeps derived promises plain (no per-hop subclass cost).
	static override get [Symbol.species](): PromiseConstructor {
		return Promise;
	}

	override get [Symbol.toStringTag](): string {
		return "RemotePromise";
	}
}
