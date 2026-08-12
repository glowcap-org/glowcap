// The driver archive's TypeScript face (ADR-0112): `DriverLoop` parks the
// runtime on the loop's one readiness descriptor, steps with a zero timeout on
// the JavaScript thread when it signals or when a Host verb kicks, and drains
// the one event queue — dial outcomes into promises, accepted sessions into a
// queue, completions into the adopted wrapper Host's vow table.
//
// This tier owns generic dial/listen/event lifecycle. Transport archives
// contribute provider packages explicitly at the product edge that selects them.
//
// Parking: the readiness descriptor is a kernel readiness set (epoll/kqueue),
// which no runtime socket wrapper can read as a stream, so the park is one
// off-thread `poll(2)` on a dup of it through the runtime's nonblocking FFI.
// That is why this tier needs `ffi.offloadsBlockingCalls()` — a runtime whose
// FFI stays on the JavaScript thread (Bun's, the wasm adapter's) cannot park,
// and callers fail closed instead of selecting a second listener or dial path.
// Every step runs synchronously on the JavaScript thread because behavior
// trampolines fire inside it; provider starts are nonblocking, and readiness
// drives connect completion and CapTP handshakes through later steps.

import { loopS } from "./internal/ffi/driver.ts";
import { ffi, NULL, type Ptr, type Symbols } from "./internal/ffi/runtime.ts";
import { ab, outPointer, outU64, readBytes, readErrorSlot } from "./internal/seam.ts";
import { L } from "./internal/layout.ts";
import { decodeHostAction, type HostAction } from "./internal/host_action.ts";
import { PancakeError, VowBroken } from "./errors.ts";
import { Host } from "./host.ts";
import { type DriverLoopHandle, type LoopChannel, Session } from "./session.ts";
import { enterDeliver, exitDeliver, insideTurn } from "./trampoline.ts";
import { type Codec } from "./value.ts";
import { type Locator, OwnedLocator, parseLocator, withOwnedLocator } from "./locator.ts";
import {
	CAPTP_V1_0,
	CLOSED,
	DEFAULT_FRAME_CAP,
	DRIVER_DEFAULT_HANDSHAKE_MS,
	DRIVER_DEFAULT_MAX_PENDING_OPENS,
	DRIVER_DEFAULT_SETTLE_MS,
	DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
	DRIVER_EVENT_ACCEPTED,
	DRIVER_EVENT_COMPLETION,
	DRIVER_EVENT_OPEN_FAILED,
	DRIVER_EVENT_OPENED,
	DRIVER_EVENT_SESSION_CLOSED,
	DRIVER_MAX_WAIT_MS,
	DRIVER_OPTIONS_ABI_VERSION,
	HOST_ACTION_FAIL,
	HOST_ACTION_SETTLE,
	INTERNAL,
	INVALID_ARGUMENT,
	IO,
	OK,
	TIMEOUT,
	WOULD_BLOCK,
} from "@pancake/abi";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** How long one off-thread park waits before stepping anyway. A wake (or any
 * readiness) returns early; the bound exists because an in-flight handshake's
 * budget expiry is a clock fact no kernel readiness reports — the step is
 * where `driver.HostRuntime` notices it — so a silent partner costs at most one
 * park interval past its budget, and a lost wake cannot park the exit path. */
const PARK_MS = 1_000;

export interface DriverLoopOptions {
	wireBufferBytes?: number;
	maxPendingOpens?: number;
	handshakeMs?: number;
	settleMs?: number;
}

function driverOptions(opts: DriverLoopOptions): Uint8Array {
	const wireBufferBytes = opts.wireBufferBytes ?? DRIVER_DEFAULT_WIRE_BUFFER_BYTES;
	const maxPendingOpens = opts.maxPendingOpens ?? DRIVER_DEFAULT_MAX_PENDING_OPENS;
	const handshakeMs = opts.handshakeMs ?? DRIVER_DEFAULT_HANDSHAKE_MS;
	const settleMs = opts.settleMs ?? DRIVER_DEFAULT_SETTLE_MS;
	const maxUsize = L.ptrSize === 4 ? 0xffff_ffff : Number.MAX_SAFE_INTEGER;
	for (
		const [name, value, maximum] of [
			["wireBufferBytes", wireBufferBytes, maxUsize],
			["maxPendingOpens", maxPendingOpens, maxUsize],
			["handshakeMs", handshakeMs, DRIVER_MAX_WAIT_MS],
			["settleMs", settleMs, DRIVER_MAX_WAIT_MS],
		] as const
	) {
		if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`${name} must be a positive integer no greater than ${maximum}`,
			);
		}
	}
	const bytes = new Uint8Array(L.DRIVER_OPTIONS_SIZE);
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	view.setUint32(L.DRIVER_OPTIONS_ABI_VERSION_OFF, DRIVER_OPTIONS_ABI_VERSION, true);
	L.setUsize(view, L.DRIVER_OPTIONS_STRUCT_SIZE_OFF, L.DRIVER_OPTIONS_SIZE);
	L.setUsize(view, L.DRIVER_OPTIONS_WIRE_BUFFER_BYTES_OFF, wireBufferBytes);
	L.setUsize(view, L.DRIVER_OPTIONS_MAX_PENDING_OPENS_OFF, maxPendingOpens);
	view.setUint32(L.DRIVER_OPTIONS_HANDSHAKE_MS_OFF, handshakeMs, true);
	view.setUint32(L.DRIVER_OPTIONS_SETTLE_MS_OFF, settleMs, true);
	return bytes;
}

/** Whether this runtime can drive a native loop at all: the park is an
 * off-thread nonblocking FFI `poll(2)`, so a runtime whose FFI executes on the
 * JavaScript thread (Bun, the wasm browser adapter) keeps the byte-fed pump. */
export function loopTierAvailable(): boolean {
	try {
		return ffi.offloadsBlockingCalls();
	} catch {
		return false; // runtime not ready: the caller's own FFI use will say so
	}
}

/** The generic registrar surface transport archives consume. Package
 * construction and configuration remain in the transport module. */
export interface ProviderTarget {
	installProvider(prepare: (register: (packageBytes: Uint8Array) => void) => void): void;
	hasTransport(transport: string): boolean;
}

function driverLastError(): string | null {
	return readErrorSlot(loopS.pancake_driver_last_error);
}

function checkDriver(rc: number): void {
	if (rc !== OK) throw new PancakeError(rc, driverLastError() ?? undefined);
}

function loopClosedError(): PancakeError {
	return new PancakeError(CLOSED, "the loop is closed");
}

/** Classify an OPEN_FAILED event. The loop reports an admitted dial's failure by
 * error name; a handshake or settle budget overrun becomes the typed timeout
 * the public dial contract promises, everything else is I/O. */
function openFailure(message: string): PancakeError {
	if (message === "HandshakeTimedOut" || message === "WaitTimedOut") {
		return new PancakeError(
			TIMEOUT,
			"the partner did not finish the OCapN handshake within the loop's handshake budget",
		);
	}
	return new PancakeError(IO, `dial failed: ${message}`);
}

// `dup(2)` and the parking `poll(2)` from libc, opened lazily. The readiness
// descriptor is owned by the loop; the park polls its own dup and closes it on
// exit, so the loop's descriptor is never closed out from under it. `poll` is
// nonblocking, so the park waits on the runtime's FFI pool thread while the
// JavaScript thread keeps serving.
let libc: Symbols | null = null;
function libcSyms(): Symbols {
	if (libc === null) {
		const name = ffi.libSuffix() === "dylib" ? "libSystem.B.dylib" : "libc.so.6";
		libc = ffi.dlopen(name, {
			dup: { parameters: ["i32"], result: "i32" },
			close: { parameters: ["i32"], result: "i32" },
			poll: { parameters: ["buffer", "usize", "i32"], result: "i32", nonblocking: true },
		});
	}
	return libc;
}

/** One drained loop event, in owned form (the C views die at the next pop, so
 * byte payloads are copied out in the pop loop). */
type LoopEvent =
	| { kind: "opened"; ticket: bigint; session: Ptr }
	| { kind: "openFailed"; ticket: bigint; message: string }
	| { kind: "accepted"; listener: bigint; session: Ptr }
	| { kind: "sessionClosed"; session: Ptr }
	| { kind: "completion"; action: HostAction };

interface DialWaiter {
	resolve: (session: Ptr) => void;
	reject: (error: PancakeError) => void;
}

/** The loop-backed `Channel` a loop-minted `Session` rides: no byte verbs (the
 * native loop owns the wire), one closed event the serve promise and teardown
 * share, and the `driverLoop` back-reference `Session`'s loop arms dispatch
 * on. */
class LoopTransport implements LoopChannel {
	readonly driverLoop: DriverLoop;
	readonly #closed: Promise<void>;
	#markClosed!: () => void;

	constructor(driverLoop: DriverLoop) {
		this.driverLoop = driverLoop;
		this.#closed = new Promise<void>((resolve) => {
			this.#markClosed = resolve;
		});
	}

	/** Never read by the loop arms; resolves the clean EOF at close so a
	 * stray pump read cannot park forever. */
	read(): Promise<Uint8Array | null> {
		return this.#closed.then(() => null);
	}

	write(_data: Uint8Array): Promise<void> {
		return Promise.reject(
			new PancakeError(INVALID_ARGUMENT, "the native loop owns this session's wire"),
		);
	}

	close(): void {
		this.#markClosed();
	}

	waitClosed(): Promise<void> {
		return this.#closed;
	}
}

/** One stepping native loop over one multi-session host (ADR-0112).
 *
 * Construct with `open` on the thread that will drive it, `start()` to park on
 * the readiness descriptor, and `close()` before dropping it. One thread
 * drives one loop; `pancake_driver_wake` is the one cross-thread call, and the
 * park task is the only place it is needed here. */
export class DriverLoop implements DriverLoopHandle {
	#h: Ptr;
	readonly #wrapper: Host;
	#released = false;
	#stepping = false;
	#stepScheduled = false;
	#parkExited: Promise<void> | null = null;
	#closing: Promise<void> | null = null;
	// A short stepping cadence while dials are in flight: a dial's handshake
	// budget expires on the clock, and the 250ms-scale budgets the tests use
	// deserve better than the park bound's resolution.
	#dialTicker: ReturnType<typeof setTimeout> | null = null;
	// Deferred-close state (the server contract): a close request with open
	// sessions parks here, and the last session's release runs the close.
	#closeRequested = false;
	#deferredClose: { promise: Promise<void>; resolve: () => void } | null = null;
	// Every live loop-minted session this binding wrapped, so a deferred close
	// knows when the last application-owned session is gone.
	readonly #openSessions = new Set<Ptr>();
	// OPENED/ACCEPTED handles cross one event-to-wrapper ownership window. A
	// true value records SESSION_CLOSED arriving before adoption; the pointer
	// remains valid until the wrapper claims or the binding releases it.
	readonly #unclaimedSessions = new Map<Ptr, boolean>();
	readonly #pendingDials = new Map<bigint, DialWaiter>();
	readonly #accepts = new Map<bigint, Ptr[]>();
	readonly #acceptWaiters = new Map<bigint, Array<(session: Ptr | null) => void>>();
	readonly #listeners = new Set<bigint>();
	// What a loop step's behavior callbacks read as the arriving connection:
	// a step delivers for any of the loop's sessions, so no single `Session`
	// can stand in and `currentSession()` is null inside a loop-fed turn. The
	// bracket's host half still latches turn-time spawn and async-behavior
	// deferral to the wrapper Host.
	readonly #stepCarrier = {};

	private constructor(handle: Ptr, wrapper: Host) {
		this.#h = handle;
		this.#wrapper = wrapper;
	}

	// ── Lifecycle ──────────────────────────────────────────────────────────────

	/** Create a Host and transfer it into a transport-empty loop. `seed` is the
	 * Host's 32-byte durable identity seed; its session-key root is drawn by Host.
	 * The budgets must be positive: the loop refuses an unbounded wait by
	 * construction, which is why the unbounded handshake opt-in stays on the
	 * byte-fed dial. */
	static open(
		opts: DriverLoopOptions & {
			seed?: Uint8Array;
			codec?: Codec;
			frameCap?: number;
		} = {},
	): DriverLoop {
		const codec = opts.codec ?? "syrup";
		const host = new Host(opts.seed, { codec, frameCap: opts.frameCap ?? DEFAULT_FRAME_CAP });
		try {
			return DriverLoop.takeHost(host, opts);
		} catch (error) {
			host.release();
			throw error;
		}
	}

	/** Transfer an existing quiescent Host to a native loop. The native claim is
	 * transactional: a refused claim leaves the Host byte-fed and usable. Once
	 * it succeeds, the original wrapper remains attached to the loop and the
	 * loop owns the only native release path. */
	static takeHost(
		host: Host,
		opts: DriverLoopOptions = {},
	): DriverLoop {
		const options = driverOptions(opts);
		const out = new Uint8Array(8);
		checkDriver(loopS.pancake_driver_take_host(
			host.raw,
			ffi.pointerOf(options),
			ab(out),
		));
		const loop = new DriverLoop(outPointer(out), host);
		try {
			host.attachDriverLoop(loop);
			return loop;
		} catch (error) {
			void loop.close();
			throw error;
		}
	}

	#guardOpen(): void {
		if (this.#released) throw loopClosedError();
	}

	/** The exact Host wrapper transferred into this loop. */
	wrapperHost(): Host {
		return this.#wrapper;
	}

	/** Stop stepping and release the loop, its sessions, and its host.
	 * Idempotent; safe to start from inside a behavior turn (the native
	 * release runs after the enclosing step unwinds). */
	close(): Promise<void> {
		if (this.#closing == null) {
			this.#closing = this.#doClose();
			void this.#closing.catch(() => {});
			const deferred = this.#deferredClose;
			if (deferred != null) {
				void this.#closing.then(() => deferred.resolve(), () => deferred.resolve());
			}
		}
		return this.#closing;
	}

	/** The server-shaped close (ADR-0112): stop accepting now, release the
	 * unclaimed queue, and close the loop once the last application-owned
	 * session is gone — sessions already yielded (or dialed on this loop's
	 * Host) remain open until their owners close them, exactly the byte-fed
	 * server's contract. Resolves at the eventual native release barrier. */
	requestClose(): Promise<void> {
		if (this.#closing != null) return this.#closing;
		this.#closeRequested = true;
		const listeners = [...this.#listeners];
		for (const listener of listeners) this.#closeListenerNative(listener);
		this.#dispatchCommittedEvents();
		for (const listener of listeners) this.#finishListenerClose(listener);
		for (const queue of this.#accepts.values()) {
			for (const ptr of queue.splice(0)) this.nativeSessionRelease(ptr);
		}
		for (const waiters of this.#acceptWaiters.values()) {
			for (const waiter of waiters.splice(0)) waiter(null);
		}
		if (this.#openSessions.size === 0) return this.close();
		if (this.#deferredClose == null) {
			let resolve!: () => void;
			const promise = new Promise<void>((r) => {
				resolve = r;
			});
			this.#deferredClose = { promise, resolve };
		}
		return this.#deferredClose.promise;
	}

	async #doClose(): Promise<void> {
		this.#released = true;
		if (this.#dialTicker != null) {
			clearTimeout(this.#dialTicker);
			this.#dialTicker = null;
		}
		for (const waiter of this.#pendingDials.values()) waiter.reject(loopClosedError());
		this.#pendingDials.clear();
		for (const waiters of this.#acceptWaiters.values()) {
			for (const waiter of waiters.splice(0)) waiter(null);
		}
		const wrapper = this.#wrapper;
		// The released flag above makes `nativeSessionRelease` a no-op: the
		// native release below frees every loop-minted session itself, so the
		// wrapper sweep only retires the JS shells and settles their vows.
		await Promise.allSettled(wrapper.closeSessions());
		try {
			await loopS.pancake_driver_wake(this.#h);
		} catch {
			// best-effort: the park's bounded poll exits on its own budget
		}
		if (this.#parkExited != null) await this.#parkExited;
		// The wrapper half first: its trace drain still reads the live handle.
		// The native release below then frees loop, sessions, and host together.
		wrapper.prepareLoopTeardown();
		const handle = this.#h;
		checkDriver(loopS.pancake_driver_release(handle));
		this.#h = NULL;
		wrapper.finishLoopTeardown();
	}

	/** Release one loop-owned session through the loop's own verb, which also
	 * drops queued events naming it. A no-op once the loop is released: the
	 * loop's release freed its sessions itself. */
	nativeSessionRelease(ptr: Ptr): void {
		this.#openSessions.delete(ptr);
		this.#unclaimedSessions.delete(ptr);
		if (!this.#released && ptr !== NULL) {
			checkDriver(loopS.pancake_driver_session_release(this.#h, ptr));
		}
		// A parked close request runs once the last open session is gone.
		if (this.#closeRequested && this.#openSessions.size === 0 && this.#closing == null) {
			void this.close();
		}
	}

	// ── Extension transports ──────────────────────────────────────────────────

	/** Install one archive-owned provider inside the dynamic extent in which
	 * its construction owner is live. The registrar rejects capture and reuse. */
	installProvider(
		prepare: (register: (packageBytes: Uint8Array) => void) => void,
	): void {
		this.#guardOpen();
		let active = true;
		let registered = false;
		const register = (packageBytes: Uint8Array): void => {
			if (!active || registered) {
				throw new PancakeError(INVALID_ARGUMENT, "provider registrar is no longer active");
			}
			checkDriver(loopS.pancake_driver_add_provider(this.#h, ffi.pointerOf(packageBytes)));
			registered = true;
		};
		try {
			prepare(register);
			if (!registered) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"provider installer registered no package",
				);
			}
		} finally {
			active = false;
		}
	}

	/** Ask the native provider registry whether `transport` is owned. */
	hasTransport(transport: string): boolean {
		this.#guardOpen();
		const name = utf8Encoder.encode(transport);
		const present = new Uint8Array(1);
		checkDriver(loopS.pancake_driver_has_transport(
			this.#h,
			ab(name),
			BigInt(name.length),
			ab(present),
		));
		return present[0] !== 0;
	}

	// ── Parking and stepping ───────────────────────────────────────────────────

	/** Arm the readiness descriptor and park on it: from here the loop steps
	 * whenever native work is ready. Idempotent. */
	start(): void {
		this.#guardOpen();
		if (this.#parkExited != null) return;
		const out = new Uint8Array(4);
		checkDriver(loopS.pancake_driver_readiness_fd(this.#h, ab(out)));
		const fd = new DataView(out.buffer).getInt32(0, true);
		const dup = Number(libcSyms().dup(fd));
		if (dup < 0) {
			throw new PancakeError(IO, "dup of the loop readiness descriptor failed");
		}
		this.#parkExited = this.#park(dup).catch(() => {});
		// Drain anything already pending before the first signal.
		this.stepNow();
	}

	async #park(dup: number): Promise<void> {
		// One pollfd row: { fd: i32, events: i16, revents: i16 }.
		const pollfd = new Uint8Array(8);
		const dv = new DataView(pollfd.buffer);
		dv.setInt32(0, dup, true);
		dv.setInt16(4, 1, /* POLLIN */ true);
		try {
			while (!this.#released) {
				dv.setInt16(6, 0, true);
				const n = Number(await libcSyms().poll(ab(pollfd), 1n, PARK_MS));
				if (this.#released || n < 0) break;
				// Step on readiness AND on the park bound: an expired handshake
				// budget is discovered by the step, never by the kernel set.
				this.stepNow();
			}
		} finally {
			libcSyms().close(dup);
		}
	}

	/** Schedule one loop step soon — how a wrapper verb's kick reaches the
	 * drain. Deferred through a microtask, so a kick from inside a behavior
	 * turn steps only after the enclosing step (or feed) unwinds. */
	scheduleStep(): void {
		if (this.#released || this.#stepScheduled) return;
		this.#stepScheduled = true;
		queueMicrotask(() => {
			this.#stepScheduled = false;
			this.stepNow();
		});
	}

	/** Drain zero-timeout steps and events through quiescence on the driving
	 * thread. Reaching WOULD_BLOCK permits the readiness edge to be cleared. */
	stepNow(): void {
		if (this.#released || this.#stepping || insideTurn()) return;
		this.#stepping = true;
		try {
			const host = this.#wrapper;
			while (true) {
				// The head of the byte-fed kick, one tier up: run parked releases and
				// reclaimed-import releases before every step, so a dropped `Ref`'s
				// op:gc-exports flushes before another wire turn can run.
				host?.drainParkedReleases();
				host?.drainGc();
				// The step is the deliver: behaviors fire inside it, and the bracket
				// latches their turns to this loop's wrapper Host.
				const prev = host != null ? enterDeliver(this.#stepCarrier, host) : null;
				let rc: number;
				try {
					rc = loopS.pancake_driver_step(this.#h, 0);
				} finally {
					if (host != null) exitDeliver(prev);
				}
				if (rc === WOULD_BLOCK) break;
				checkDriver(rc);
				const events = this.#popEvents();
				host?.drainParkedReleases();
				if (events.length > 0) this.#dispatch(events);
			}
		} finally {
			this.#stepping = false;
		}
		this.#wrapper?.drainParkedReleases();
	}

	#popEvents(): LoopEvent[] {
		const out: LoopEvent[] = [];
		const buf = new Uint8Array(L.DRIVER_EVENT_SIZE);
		while (true) {
			const rc = loopS.pancake_driver_next_event(this.#h, ab(buf));
			if (rc === WOULD_BLOCK) return out;
			checkDriver(rc);
			const dv = new DataView(buf.buffer);
			const kind = dv.getUint32(L.DRIVER_EVENT_KIND_OFF, true);
			const ticket = dv.getBigUint64(L.DRIVER_EVENT_TICKET_OFF, true);
			const session = L.getPtr(dv, L.DRIVER_EVENT_SESSION_OFF);
			switch (kind) {
				case DRIVER_EVENT_OPENED:
					out.push({ kind: "opened", ticket, session });
					break;
				case DRIVER_EVENT_OPEN_FAILED:
					out.push({
						kind: "openFailed",
						ticket,
						message: utf8Decoder.decode(readBytes(
							L.getPtr(dv, L.DRIVER_EVENT_MESSAGE_OFF),
							L.getUsize(dv, L.DRIVER_EVENT_MESSAGE_LEN_OFF),
						)),
					});
					break;
				case DRIVER_EVENT_ACCEPTED:
					out.push({ kind: "accepted", listener: ticket, session });
					break;
				case DRIVER_EVENT_SESSION_CLOSED:
					out.push({ kind: "sessionClosed", session });
					break;
				case DRIVER_EVENT_COMPLETION:
					// Decode into owned values while the C views are live (they die
					// at the next pop): the same generated decoder the byte-fed
					// drain uses, so a loop-routed settle carries the same shapes.
					out.push({
						kind: "completion",
						action: decodeHostAction(
							new DataView(buf.buffer, L.DRIVER_EVENT_ACTION_OFF),
						),
					});
					break;
				default:
					throw new PancakeError(INVALID_ARGUMENT, `unknown loop event kind ${kind}`);
			}
		}
	}

	#dispatch(events: LoopEvent[]): void {
		const host = this.#wrapper;
		for (const event of events) {
			switch (event.kind) {
				case "opened": {
					const waiter = this.#pendingDials.get(event.ticket);
					this.#pendingDials.delete(event.ticket);
					if (waiter == null) {
						this.nativeSessionRelease(event.session);
					} else {
						this.#unclaimedSessions.set(event.session, false);
						waiter.resolve(event.session);
					}
					break;
				}
				case "openFailed": {
					const waiter = this.#pendingDials.get(event.ticket);
					this.#pendingDials.delete(event.ticket);
					waiter?.reject(openFailure(event.message));
					break;
				}
				case "accepted": {
					if (this.#closeRequested) {
						// The admission is closed: a straggler accepted inside the
						// step is released, never handed out.
						this.nativeSessionRelease(event.session);
						break;
					}
					const waiters = this.#acceptWaiters.get(event.listener);
					const queue = this.#accepts.get(event.listener);
					if (waiters == null || queue == null) {
						this.nativeSessionRelease(event.session);
						throw new PancakeError(
							INTERNAL,
							`accepted session names unknown listener ${event.listener}`,
						);
					}
					this.#unclaimedSessions.set(event.session, false);
					const waiter = waiters?.shift();
					if (waiter != null) waiter(event.session);
					else queue.push(event.session);
					break;
				}
				case "sessionClosed": {
					// The pump's EOF choreography, one tier up: `closeTransport`
					// marks teardown first (ordered before this wire's FAIL
					// completions, so they classify as the typed closed error) and
					// retires the shell so a later verb refuses CLOSED. The native
					// side already broke the far vows in its close. A session this
					// binding never wrapped (a loop-internal redeem dial) has no
					// shell to retire, so its handle is released here directly.
					const shell = host?.getSession(event.session);
					if (shell != null) shell.closeTransport();
					else if (this.#unclaimedSessions.has(event.session)) {
						this.#unclaimedSessions.set(event.session, true);
					} else this.nativeSessionRelease(event.session);
					break;
				}
				case "completion": {
					if (host == null) break;
					// The wrapper's vow table is the byte-fed drain's, one tier up:
					// SETTLE fulfills, FAIL classifies a teardown break as the typed
					// closed error and everything else as a partner break.
					const action = event.action;
					if (action.kind === HOST_ACTION_SETTLE) {
						host.settleVow(action.ticket, { ok: action.value });
					} else if (action.kind === HOST_ACTION_FAIL) {
						const closing = host.vowSessionClosing(action.ticket);
						host.settleVow(action.ticket, {
							err: closing
								? new PancakeError(CLOSED, action.message)
								: new VowBroken(action.message),
						});
					}
					// FLUSH/CLOSE/DIAL/NEED_GIFT_ID never surface: the loop
					// executes transport-shaped actions internally.
					break;
				}
			}
		}
		host?.drainParkedReleases();
	}

	// ── Dial, accept, listen ───────────────────────────────────────────────────

	/** Begin a nonblocking dial and await its session handle. The handshake advances
	 * across steps (`driver.HostRuntime.startConnectLocator`), so loops on one
	 * thread can dial each other and a stalled partner costs its budget,
	 * never the loop. */
	dial(locator: Locator | string): Promise<Ptr> {
		this.#guardOpen();
		const parsed = typeof locator === "string" ? parseLocator(locator) : locator;
		const out = new Uint8Array(8);
		withOwnedLocator(
			parsed,
			(owned) => checkDriver(loopS.pancake_driver_dial(this.#h, owned.borrowView(), ab(out))),
		);
		const ticket = outU64(out);
		const pending = new Promise<Ptr>((resolve, reject) => {
			this.#pendingDials.set(ticket, { resolve, reject });
		});
		this.scheduleStep();
		this.#armDialTicker();
		return pending;
	}

	#armDialTicker(): void {
		if (this.#dialTicker != null || this.#released) return;
		this.#dialTicker = setTimeout(() => {
			this.#dialTicker = null;
			if (this.#released || this.#pendingDials.size === 0) return;
			this.stepNow();
			this.#armDialTicker();
		}, 50);
	}

	/** Await the next accepted session handle (bind a listener first), or null
	 * once the loop closes, so a server iteration ends rather than parking
	 * forever. */
	accept(listener: bigint): Promise<Ptr | null> {
		const queued = this.#accepts.get(listener)?.shift();
		if (queued != null) return Promise.resolve(queued);
		if (this.#released || this.#closeRequested || !this.#listeners.has(listener)) {
			return Promise.resolve(null);
		}
		return new Promise<Ptr | null>((resolve) => {
			this.#acceptWaiters.get(listener)?.push(resolve);
		});
	}

	/** Bind one listener on a statically composed transport; accepted sessions
	 * arrive through `accept`. One listener per transport. */
	listen(transport: string, designator: string): bigint {
		this.#guardOpen();
		const t = utf8Encoder.encode(transport);
		const d = utf8Encoder.encode(designator);
		const out = new Uint8Array(8);
		checkDriver(loopS.pancake_driver_listen(
			this.#h,
			ab(t),
			BigInt(t.length),
			ab(d),
			BigInt(d.length),
			ab(out),
		));
		const listener = outU64(out);
		this.#listeners.add(listener);
		this.#accepts.set(listener, []);
		this.#acceptWaiters.set(listener, []);
		return listener;
	}

	/** The listener's complete canonical OCapN locator. */
	listenerLocator(listener: bigint): Locator {
		this.#guardOpen();
		const out = new Uint8Array(L.LOCATOR_VIEW_SIZE);
		checkDriver(loopS.pancake_driver_listener_locator(this.#h, listener, ab(out)));
		const owned = OwnedLocator.cloneView(out);
		try {
			return owned.value();
		} finally {
			owned.release();
		}
	}

	/** Replace this listener's advertised locator through its native owner. */
	advertiseListener(listener: bigint, locator: Locator | string): void {
		this.#guardOpen();
		const parsed = typeof locator === "string" ? parseLocator(locator) : locator;
		withOwnedLocator(parsed, (owned) =>
			checkDriver(
				loopS.pancake_driver_listener_advertise(this.#h, listener, owned.borrowView()),
			));
	}

	/** Select this listener's locator as the Host's acceptable location. */
	selectListener(listener: bigint): void {
		this.#guardOpen();
		checkDriver(loopS.pancake_driver_listener_select(this.#h, listener));
	}

	/** Stop one listener. Events committed before close remain queued; no later
	 * accepted event can name it after this returns. */
	closeListener(listener: bigint): void {
		if (this.#released) {
			this.#finishListenerClose(listener);
			return;
		}
		this.#closeListener(listener);
	}

	#closeListener(listener: bigint): void {
		this.#closeListenerNative(listener);
		this.#dispatchCommittedEvents();
		this.#finishListenerClose(listener);
	}

	/** Dispatch only events committed by earlier steps. Listener close uses
	 * this after native admission is sealed, so it cannot create a new accept
	 * while preserving an old one. */
	#dispatchCommittedEvents(): void {
		const events = this.#popEvents();
		if (events.length > 0) this.#dispatch(events);
	}

	#closeListenerNative(listener: bigint): void {
		checkDriver(loopS.pancake_driver_listener_close(this.#h, listener));
	}

	#finishListenerClose(listener: bigint): void {
		this.#listeners.delete(listener);
		for (const waiter of this.#acceptWaiters.get(listener)?.splice(0) ?? []) waiter(null);
	}

	/** Release accepted sessions this binding has not transferred to an
	 * application. Native listener close preserves already-committed accepts;
	 * a public listener that is itself closing has no future owner for them. */
	discardAccepted(listener: bigint): void {
		let failure: unknown = null;
		for (const ptr of this.#accepts.get(listener)?.splice(0) ?? []) {
			try {
				this.nativeSessionRelease(ptr);
			} catch (error) {
				failure ??= error;
			}
		}
		this.#accepts.delete(listener);
		this.#acceptWaiters.delete(listener);
		if (failure != null) throw failure;
	}

	// ── Session adoption ───────────────────────────────────────────────────────

	/** Wrap a loop-minted session handle as the public `Session`, over the
	 * adopted wrapper Host: every session verb, promise, and trampoline works
	 * on it, with the native loop as the transport and the drain. Idempotent
	 * per handle: a handle already wrapped returns its wrapper. */
	adoptSession(ptr: Ptr): Session {
		const host = this.wrapperHost();
		const existing = host.getSession(ptr);
		if (existing != null) return existing;
		const closed = this.#unclaimedSessions.get(ptr) ?? false;
		this.#unclaimedSessions.delete(ptr);
		this.#openSessions.add(ptr);
		const session = Session.adoptLoopSession(ptr, host, new LoopTransport(this));
		if (closed) void session.closeTransport();
		return session;
	}

	/** Dial through the loop and wrap the opened session as the public
	 * `Session`. */
	async connectSession(
		locator: Locator | string,
	): Promise<Session> {
		return this.adoptSession(await this.dial(locator));
	}

	/** Await the next accepted session, wrapped as the public `Session` — the
	 * accept-side twin of `connectSession`. The handshake already ran inside
	 * the accepting step; the session arrives open. Null once the loop
	 * closes. */
	async acceptSession(listener: bigint): Promise<Session | null> {
		const ptr = await this.accept(listener);
		return ptr == null ? null : this.adoptSession(ptr);
	}
}

/** The binding's one owner for a generic native-driver listener. Transport
 * packages wrap this object only to project their own locator metadata. */
export class DriverListener {
	readonly #loop: DriverLoop;
	readonly #listener: bigint;
	readonly #host: Host;
	#closed = false;

	private constructor(loop: DriverLoop, listener: bigint) {
		this.#loop = loop;
		this.#listener = listener;
		this.#host = loop.wrapperHost();
	}

	static open(loop: DriverLoop, transport: string, designator: string): DriverListener {
		return new DriverListener(loop, loop.listen(transport, designator));
	}

	get host(): Host {
		return this.#host;
	}

	locator(): Locator {
		if (this.#closed) throw loopClosedError();
		return this.#loop.listenerLocator(this.#listener);
	}

	advertise(locator: Locator | string): void {
		if (this.#closed) throw loopClosedError();
		this.#loop.advertiseListener(this.#listener, locator);
	}

	select(): void {
		if (this.#closed) throw loopClosedError();
		this.#loop.selectListener(this.#listener);
	}

	accept(): Promise<Session | null> {
		if (this.#closed) return Promise.resolve(null);
		return this.#loop.acceptSession(this.#listener);
	}

	/** Seal this listener's admission without closing its Host, sibling
	 * listeners, or sessions already transferred to the application. */
	close(): void {
		if (this.#closed) return;
		this.#loop.closeListener(this.#listener);
		this.#closed = true;
		this.#loop.discardAccepted(this.#listener);
	}
}
