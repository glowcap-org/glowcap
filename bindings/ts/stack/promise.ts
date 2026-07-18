// The `RemotePromise` a Session send returns: lazy observation, promise
// pipelining target, and `index`/`untag`/`get` projection (ADR-0007 /
// ADR-0050 / ADR-0052). Also the shared fetch/enliven mint→await→classify
// path (`awaitMinted` / `asLiveRef`), the far-send mint→`promiseFor` path
// (`sendFar`), and RemotePromise construction. Session owns CapTP verb
// wrappers; trampoline owns near/far send·tell dispatch and local arms;
// this module owns the handle type, far-send/post-mint choreography, and
// the projection FFI (`pancake_host_vow_*`).

import { driverS } from "./internal/ffi/driver.ts";
import type { Ptr } from "./internal/ffi/runtime.ts";
import { ab, outU64 } from "./internal/seam.ts";
import { INVALID_ARGUMENT } from "@pancake/abi";
import { checkHost, FetchFailed, PancakeError } from "./errors.ts";
import { encodeArgs, refStruct } from "./codec.ts";
import { type AppValue, type Argument, isReference, liftArg, lowerArg, Ref } from "./value.ts";

/** Session callbacks the fetch/enliven wait needs without importing Session
 * (avoids a promise ↔ session cycle). */
export interface MintAwaitHandle {
	guardOpen(): void;
	drainGc(): void;
	readonly ptr: Ptr;
	vowMinted(vow: bigint): void;
	serve(): void;
	awaitVow(vow: bigint): Promise<Argument>;
	kickActions(): Promise<void>;
}

/** Session callbacks the far-send `promiseFor` / `sendFar` path needs. */
export interface PromiseFactoryHandle {
	serve(): void;
	awaitVow(vow: bigint): Promise<Argument>;
	kickActions(): Promise<void>;
	vowMinted(vow: bigint): void;
	readonly hostRaw: Ptr;
	readonly ptr: Ptr;
}

const utf8Encoder = new TextEncoder();

/** Mint a sibling vow at `source` via `op:index` / `op:untag` / `op:get` (ADR-0050/0052). */
function projectVow(
	hostRaw: Ptr,
	source: bigint,
	op: "index" | "untag" | "get",
	key: string | bigint,
): bigint {
	const out = new Uint8Array(8);
	if (op === "index") {
		checkHost(driverS.pancake_host_vow_index(
			hostRaw,
			source,
			key as bigint,
			ab(out),
		));
	} else {
		const bytes = utf8Encoder.encode(key as string);
		const fn = op === "get" ? driverS.pancake_host_vow_get : driverS.pancake_host_vow_untag;
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
	h: MintAwaitHandle,
	vow: bigint,
): Promise<Argument> {
	h.vowMinted(vow);
	h.serve();
	const settled = h.awaitVow(vow);
	void h.kickActions();
	return await settled;
}

/** Classify a settled mint: only a live near/far reference is a capability
 * this surface can hand out. */
export function asLiveRef(result: Argument, label: string): Ref {
	if (
		!isReference(result) ||
		(result.kind !== "near" && result.kind !== "far")
	) {
		throw new FetchFailed(label);
	}
	return new Ref(result);
}

/** The one mint/await/classify body under `fetch` and `enliven`: mint the
 * host vow with `mint`, drive the inbound loop for its completion, and
 * classify the settled value — anything but a live capability rejects with
 * `FetchFailed(label)`. */
export async function fetchLike(
	h: MintAwaitHandle,
	swiss: Uint8Array,
	label: string,
	mint: (
		conn: Ptr,
		swiss: BufferSource,
		len: bigint,
		out: BufferSource,
	) => number,
): Promise<Ref> {
	h.guardOpen();
	h.drainGc();
	const out = new Uint8Array(8);
	checkHost(mint(h.ptr, ab(swiss), BigInt(swiss.length), ab(out)));
	const vow = outU64(out);
	const result = await awaitMinted(h, vow);
	return asLiveRef(result, label);
}

/** The `RemotePromise` over a freshly minted host vow: observation kicks the
 * drain (the flush that puts the queued batch on the wire) and awaits the
 * drain-routed completion; projections mint sibling vows at the answer. */
export function promiseFor(
	h: PromiseFactoryHandle,
	vow: bigint,
): RemotePromise {
	const begin = async (): Promise<AppValue> => {
		h.serve(); // the settle's bytes arrive on the inbound loop
		const settled = h.awaitVow(vow);
		void h.kickActions();
		return liftArg(await settled);
	};
	const project = (
		op: "index" | "untag" | "get",
		key: string | bigint,
	): RemotePromise => {
		const projected = projectVow(h.hostRaw, vow, op, key);
		h.vowMinted(projected);
		return promiseFor(h, projected);
	};
	return RemotePromise.far(vow, begin, project);
}

/** Far-send mint→`RemotePromise`: encode args, mint the host vow
 * (`conn_send` / `vow_send`), register it, and hand back `promiseFor`.
 * Local-hosted targets stay in Session (trampoline `sendLocal`). */
export function sendFar(
	h: PromiseFactoryHandle,
	target: Ref | RemotePromise,
	verb: string,
	args: AppValue[],
): RemotePromise {
	const verbBytes = utf8Encoder.encode(verb);
	const keep: Uint8Array[] = [];
	const argsBuf = encodeArgs(args.map(lowerArg), keep);
	const argsArg = args.length ? ab(argsBuf) : new Uint8Array(0);
	const out = new Uint8Array(8);
	if (target instanceof RemotePromise) {
		// Promise pipelining: eventual-send to the unresolved answer. A local
		// send's promise has no wire answer to pipeline against.
		const sourceVow = target.farVow();
		checkHost(driverS.pancake_host_vow_send(
			h.hostRaw,
			sourceVow,
			ab(verbBytes),
			BigInt(verbBytes.length),
			argsArg,
			BigInt(args.length),
			ab(out),
		));
	} else {
		checkHost(driverS.pancake_host_session_send(
			h.ptr,
			ab(refStruct(target.reference)),
			ab(verbBytes),
			BigInt(verbBytes.length),
			argsArg,
			BigInt(args.length),
			ab(out),
		));
	}
	const vow = outU64(out);
	h.vowMinted(vow);
	return promiseFor(h, vow);
}

/** The handle `Session.send` returns: the eventual result of one eventual-send,
 * and — the point of promise pipelining (ADR-0007) — a target you can `send` to
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
 * The send is queued when this is created, but its bytes leave the wire only
 * when this — or any send pipelined behind it — is first observed (`then` /
 * `await` / `catch` / `finally`), so a pipelined batch travels together. A
 * handle that is never observed is a fire-and-forget send; prefer
 * `Session.tell` for that. Because the settle is drain-routed and no rejection
 * is materialized until the handle is observed, an unawaited anchor whose far
 * answer *breaks* never raises an unhandled rejection. State is a sum
 * (`far` | `local`), not a nullable vow flag.
 *
 * The projection verbs `index`/`untag`/`get` (ADR-0050/ADR-0052) pipeline an
 * element, untag, or Struct-field access *at the answer*, before it resolves:
 * each returns a new `RemotePromise` for the projected value, addressed at this
 * answer, so `task.untag("cell").index(0)` or `task.get("name")` costs no
 * extra round trip. */
export type PromiseState =
	| { readonly tag: "far"; readonly vow: bigint }
	| { readonly tag: "local" };

export class RemotePromise extends Promise<AppValue> {
	readonly #state: PromiseState;
	readonly #begin: () => Promise<AppValue>;
	#started = false;
	readonly #resolve: (value: AppValue | PromiseLike<AppValue>) => void;
	readonly #reject: (reason?: unknown) => void;
	// Issues a projection op (index/untag/get) at this vow; set only for far.
	readonly #project:
		| ((op: "index" | "untag" | "get", key: string | bigint) => RemotePromise)
		| undefined;

	private constructor(
		state: PromiseState,
		begin: () => Promise<AppValue>,
		project?: (op: "index" | "untag" | "get", key: string | bigint) => RemotePromise,
	) {
		// The executor only captures the settlement functions; it runs no flush,
		// so construction is side-effect-free and the send stays lazy.
		let resolve!: (value: AppValue | PromiseLike<AppValue>) => void;
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
		begin: () => Promise<AppValue>,
		project: (op: "index" | "untag" | "get", key: string | bigint) => RemotePromise,
	): RemotePromise {
		return new RemotePromise({ tag: "far", vow }, begin, project);
	}

	/** A local-send handle (not pipelinable). */
	static local(begin: () => Promise<AppValue>): RemotePromise {
		return new RemotePromise({ tag: "local" }, begin);
	}

	/** Host vow when far; `null` when local (convenience, not the discriminant). */
	get vow(): bigint | null {
		return this.#state.tag === "far" ? this.#state.vow : null;
	}

	/** The host vow for pipelining, or a typed refusal when this is local. */
	farVow(): bigint {
		if (this.#state.tag !== "far") {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"cannot pipeline against a local-send promise; await it for a Ref",
			);
		}
		return this.#state.vow;
	}

	#projectOp(op: "index" | "untag" | "get", key: string | bigint): RemotePromise {
		if (this.#state.tag !== "far" || this.#project === undefined) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"cannot project a local-send promise; await it for a value",
			);
		}
		return this.#project(op, key);
	}

	/** Pipeline an `op:index` for `i` at this answer (ADR-0050): a new
	 * `RemotePromise` for the List element of whatever this resolves to. */
	index(i: number | bigint): RemotePromise {
		return this.#projectOp("index", BigInt(i));
	}

	/** Pipeline an `op:untag` for `tag` at this answer (ADR-0052): a new
	 * `RemotePromise` for the payload of whatever this resolves to, which must
	 * be a Tagged record whose tag equals `tag`. */
	untag(tag: string): RemotePromise {
		return this.#projectOp("untag", tag);
	}

	/** Pipeline an `op:get` for `field` at this answer (ADR-0050): a new
	 * `RemotePromise` for the Struct field of whatever this resolves to. */
	get(field: string): RemotePromise {
		return this.#projectOp("get", field);
	}

	// First observation issues the send's flush + reply wait, exactly once; the
	// native promise caches the settlement so repeated awaits share it. `catch`
	// and `finally` are inherited from `Promise` and delegate to this `then`, so
	// observing through any of them triggers the send.
	override then<R1 = AppValue, R2 = never>(
		onFulfilled?: ((value: AppValue) => R1 | PromiseLike<R1>) | null,
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
