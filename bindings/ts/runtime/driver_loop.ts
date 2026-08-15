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
import { PancakeError, retainSecondaryFailure, vowFailure } from "./errors.ts";
import { recordCallerlessFailure } from "./context.ts";
import { Host, type HostFinalizerState, retireHostFinalizerState } from "./host.ts";
import { type DriverLoopHandle, type LoopChannel, Session } from "./session.ts";
import { enterDeliver, exitDeliver, insideTurn } from "./trampoline.ts";
import type { Codec } from "./value.ts";
import { type Locator, OwnedLocator, parseLocator, withOwnedLocator } from "./locator.ts";
import { type CloseOptions, encodeCloseOptions } from "./lifecycle.ts";
import { traceDetachHost, traceDrainHost } from "./trace.ts";
import {
	BUFFER_TOO_SMALL,
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
	DRIVER_OPTIONS_ABI_VERSION,
	HOST_ACTION_FAIL,
	HOST_ACTION_SETTLE,
	INTERNAL,
	INVALID_ARGUMENT,
	IO,
	LIFECYCLE_CLOSED,
	OK,
	TIMEOUT,
	WOULD_BLOCK,
} from "@pancake/abi";
import {
	DRIVER_DEFAULT_LISTENER_SETUP_MS,
	DRIVER_EVENT_LISTENER_FAILED,
	DRIVER_EVENT_LISTENER_READY,
} from "./internal/constants.ts";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** How long one off-thread park waits before stepping anyway. A wake (or any
 * readiness) returns early; the bound exists because an in-flight handshake's
 * budget expiry is a clock fact no kernel readiness reports — the step is
 * where `driver.HostRuntime` notices it — so a silent partner costs at most one
 * park interval past its budget, and a lost wake cannot park the exit path. */
const PARK_MS = 1_000;

// ── The shared parker ────────────────────────────────────────────────────────
// One `poll(2)` over every live loop's readiness descriptor, instead of one
// blocking poll per loop. The nonblocking-FFI runtime hands blocking calls a
// small slot pool, and a per-loop park held a slot for its whole timeout, so
// a process with N loops served an inbound wake only when some sibling's park
// happened to expire: 2ms at one loop degraded to the park quantum at forty.
// Every parked loop still steps on each cycle — readiness or timeout alike —
// because an expired handshake or close budget is discovered by the step,
// never by the kernel set, and the park keeps running through a close on
// purpose: it is the one readiness pump, and its steps signal the close
// drivers parked on loop activity and the pending-work deadline.

interface ParkedLoop {
	loop: DriverLoop;
	dup: number;
	exited: () => void;
	failed: (error: unknown) => void;
}

const parked_loops: ParkedLoop[] = [];
let parker_running = false;

function parkerJoin(
	loop: DriverLoop,
	dup: number,
	failed: (error: unknown) => void,
): Promise<void> {
	let exited!: () => void;
	const gone = new Promise<void>((resolve) => (exited = resolve));
	parked_loops.push({ loop, dup, exited, failed });
	if (!parker_running) {
		parker_running = true;
		void runParker()
			.catch((error: unknown) => {
				for (const row of parked_loops.splice(0)) {
					row.failed(error);
					libcSyms().close(row.dup);
					row.exited();
				}
			})
			.finally(() => {
				parker_running = false;
			});
	} else {
		// The parker is mid-cycle on the previous set; wake any polled member
		// so it rebuilds with this row included rather than a quantum later.
		parked_loops[0]?.loop.parkWake();
	}
	return gone;
}

async function runParker(): Promise<void> {
	while (parked_loops.length > 0) {
		// Retire rows whose loop is closing before building the poll set, so a
		// close waiting on its park exit never waits out a full quantum.
		for (let i = parked_loops.length - 1; i >= 0; i--) {
			const row = parked_loops[i];
			if (row.loop.parkWantsExit()) {
				parked_loops.splice(i, 1);
				libcSyms().close(row.dup);
				row.exited();
			}
		}
		const rows = [...parked_loops];
		if (rows.length === 0) break;
		// pollfd rows: { fd: i32, events: i16, revents: i16 }.
		const set = new Uint8Array(8 * rows.length);
		const dv = new DataView(set.buffer);
		rows.forEach((row, i) => {
			dv.setInt32(8 * i, row.dup, true);
			dv.setInt16(8 * i + 4, 1, /* POLLIN */ true);
			dv.setInt16(8 * i + 6, 0, true);
		});
		const n = Number(await libcSyms().poll(ab(set), BigInt(rows.length), PARK_MS));
		if (n < 0) {
			const error = new PancakeError(IO, "poll of loop readiness descriptors failed");
			for (const row of rows) row.failed(error);
			break;
		}
		for (const row of rows) {
			if (row.loop.parkWantsExit()) continue;
			try {
				row.loop.stepNow();
			} catch (error) {
				row.failed(error);
			}
		}
	}
	// A break above (a poll failure) still owes every row its exit.
	for (const row of parked_loops.splice(0)) {
		libcSyms().close(row.dup);
		row.exited();
	}
}

interface DriverLoopFinalizerState {
	handle: Ptr;
	host: HostFinalizerState;
	releaseFailureReported: boolean;
}

// The held state contains no Host or DriverLoop wrapper, so it does not retain
// the collectable wrapper cycle. Driver release is the implicit cancel path.
const refusedDriverFinalizers = new Set<DriverLoopFinalizerState>();
const driverLoopFinalizer = new FinalizationRegistry<DriverLoopFinalizerState>((state) => {
	if (state.handle === NULL) return;
	const hostRaw = state.host.raw;
	traceDrainHost(hostRaw);
	const rc = loopS.pancake_driver_release(state.handle);
	if (rc !== OK) {
		if (!state.releaseFailureReported) {
			state.releaseFailureReported = true;
			recordCallerlessFailure(state.host.context, {
				layer: "binding",
				scope: "host",
				scopeId: state.host.diagnosticId,
				operation: "driver-loop.finalizer.release",
				primaryName: "DriverLoopReleaseRefused",
				primaryResult: rc,
				primaryMessage: driverLastError() ?? `native driver release failed (code ${rc})`,
			});
		}
		refusedDriverFinalizers.add(state);
		return;
	}
	state.handle = NULL;
	traceDetachHost(hostRaw);
	retireHostFinalizerState(state.host);
});

export interface DriverLoopOptions {
	wireBufferBytes?: number;
	maxPendingOpens?: number;
	handshakeMs?: number;
	listenerSetupMs?: number;
	settleMs?: number;
}

function driverOptions(opts: DriverLoopOptions): Uint8Array {
	const wireBufferBytes = opts.wireBufferBytes ?? DRIVER_DEFAULT_WIRE_BUFFER_BYTES;
	const maxPendingOpens = opts.maxPendingOpens ?? DRIVER_DEFAULT_MAX_PENDING_OPENS;
	const handshakeMs = opts.handshakeMs ?? DRIVER_DEFAULT_HANDSHAKE_MS;
	const listenerSetupMs = opts.listenerSetupMs ?? DRIVER_DEFAULT_LISTENER_SETUP_MS;
	const settleMs = opts.settleMs ?? DRIVER_DEFAULT_SETTLE_MS;
	const maxUsize = L.ptrSize === 4 ? 0xffff_ffff : Number.MAX_SAFE_INTEGER;
	const maxU32 = 0xffff_ffff;
	for (
		const [name, value, maximum] of [
			["wireBufferBytes", wireBufferBytes, maxUsize],
			["maxPendingOpens", maxPendingOpens, maxUsize],
			["handshakeMs", handshakeMs, maxU32],
			["listenerSetupMs", listenerSetupMs, maxU32],
			["settleMs", settleMs, maxU32],
		] as const
	) {
		if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`${name} must be an unsigned integer representable by the C field`,
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
	view.setUint32(L.DRIVER_OPTIONS_LISTENER_SETUP_MS_OFF, listenerSetupMs, true);
	view.setUint32(L.DRIVER_OPTIONS_SETTLE_MS_OFF, settleMs, true);
	return bytes;
}

function transportOperationOptions(data?: Uint8Array): Uint8Array | null {
	if (data == null) return null;
	const raw = new Uint8Array(L.TRANSPORT_OPERATION_OPTIONS_SIZE);
	const view = new DataView(raw.buffer);
	L.setPtr(view, L.TRANSPORT_OPERATION_OPTIONS_DATA_OFF, ffi.pointerOf(data));
	L.setUsize(view, L.TRANSPORT_OPERATION_OPTIONS_SIZE_OFF, data.length);
	return raw;
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

interface DriverFailure {
	primaryResult: number;
	primaryName: string;
	secondaryResult: number;
	secondaryCount: number;
	secondaryName: string;
}

function driverEventFailure(failure: DriverFailure, operation: string): PancakeError {
	const detail = failure.primaryName.length > 0
		? `${operation} failed: ${failure.primaryName}`
		: `${operation} failed`;
	const error = new PancakeError(failure.primaryResult, detail);
	if (failure.secondaryCount > 0) {
		retainSecondaryFailure(
			error,
			new PancakeError(failure.secondaryResult, failure.secondaryName),
			failure.secondaryCount,
		);
	}
	return error;
}

function asPancakeError(error: unknown, operation: string): PancakeError {
	if (error instanceof PancakeError) return error;
	return new PancakeError(INTERNAL, `${operation}: ${String(error)}`);
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
	| { kind: "opened"; operationId: bigint; session: Ptr }
	| ({ kind: "openFailed"; operationId: bigint } & DriverFailure)
	| { kind: "listenerReady"; listener: bigint }
	| ({ kind: "listenerFailed"; listener: bigint } & DriverFailure)
	| { kind: "accepted"; listener: bigint; session: Ptr }
	| ({ kind: "sessionClosed"; session: Ptr } & DriverFailure)
	| { kind: "completion"; action: HostAction };

interface DialWaiter {
	resolve: (session: Ptr) => void;
	reject: (error: PancakeError) => void;
}

interface ListenerWaiter {
	resolve: (listener: bigint) => void;
	reject: (error: PancakeError) => void;
	onAbort?: () => void;
}

/** The loop-backed `Channel` a loop-minted `Session` rides: no byte verbs (the
 * native loop owns the wire), one closed event the serve promise and teardown
 * share, and the `driverLoop` back-reference `Session`'s loop arms dispatch
 * on. */
class LoopTransport implements LoopChannel {
	readonly driverLoop: DriverLoop;
	readonly #closed: Promise<void>;
	#markClosed!: () => void;
	#markFailed!: (error: PancakeError) => void;
	#settled = false;

	constructor(driverLoop: DriverLoop) {
		this.driverLoop = driverLoop;
		this.#closed = new Promise<void>((resolve, reject) => {
			this.#markClosed = resolve;
			this.#markFailed = reject;
		});
		// A session may close after its event is committed but before the
		// application adopts and serves it. Keep the rejection observable later
		// without making that ownership window an unhandled rejection.
		void this.#closed.catch(() => {});
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
		this.finishClosed(null);
	}

	finishClosed(error: PancakeError | null): void {
		if (this.#settled) return;
		this.#settled = true;
		if (error == null) this.#markClosed();
		else this.#markFailed(error);
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
	#finalizerState: DriverLoopFinalizerState | null = null;
	readonly #wrapper: Host;
	#released = false;
	#terminalFailure: PancakeError | null = null;
	#stepping = false;
	#stepScheduled = false;
	#parkExited: Promise<void> | null = null;
	#closing: Promise<void> | null = null;
	// One scheduler-native clock for every native deadline. HostRuntime owns
	// which pending operation is nearest; this binding only turns that duration
	// into a JavaScript wake that calls step.
	#progressTimer: ReturnType<typeof setTimeout> | null = null;
	#closeRequested = false;
	// Set only by `#doClose` once the lifecycle is terminal: the park task keeps
	// stepping on readiness through the whole close (it is the close driver's
	// readiness pump) and exits at this flag, before the native release.
	#parkStop = false;
	// OPENED/ACCEPTED handles cross one event-to-wrapper ownership window. A
	// true value records SESSION_CLOSED arriving before adoption; the pointer
	// remains valid until the wrapper claims or the binding releases it.
	readonly #unclaimedSessions = new Map<
		Ptr,
		| { readonly kind: "open" }
		| { readonly kind: "closed"; readonly error: PancakeError | null }
	>();
	readonly #sessionCloses = new Map<Ptr, {
		readonly promise: Promise<void>;
		readonly resolve: () => void;
		readonly reject: (error: PancakeError) => void;
	}>();
	readonly #pendingDials = new Map<bigint, DialWaiter>();
	readonly #pendingListeners = new Map<bigint, ListenerWaiter>();
	readonly #accepts = new Map<bigint, Ptr[]>();
	readonly #acceptWaiters = new Map<
		bigint,
		Array<{
			readonly resolve: (session: Ptr | null) => void;
			readonly reject: (error: PancakeError) => void;
		}>
	>();
	readonly #listeners = new Set<bigint>();
	readonly #closingListeners = new Set<bigint>();
	// A loop step may deliver for any session. The step carrier supplies the
	// wrapper Host; each callback turn supplies its actual ingress session.
	private constructor(handle: Ptr, wrapper: Host) {
		this.#h = handle;
		this.#wrapper = wrapper;
	}

	#armFinalizer(host: HostFinalizerState): void {
		const state = { handle: this.#h, host, releaseFailureReported: false };
		this.#finalizerState = state;
		driverLoopFinalizer.register(this, state, this);
	}

	// ── Lifecycle ──────────────────────────────────────────────────────────────

	/** Create a Host and transfer it into a transport-empty loop. `seed` is the
	 * Host's 32-byte durable identity seed; its session-key root is drawn by Host.
	 * Zero is the explicit unbounded form for each wait budget. */
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
			void host.close().catch((cleanup) => {
				host.recordCallerlessBindingFailure("driver-loop.open.rollback", cleanup);
			});
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
			loop.#armFinalizer(host.attachDriverLoop(loop));
			return loop;
		} catch (error) {
			void loop.close().catch((cleanup) => {
				host.recordCallerlessBindingFailure("driver-loop.take-host.rollback", cleanup);
			});
			throw error;
		}
	}

	#guardHandle(): void {
		if (this.#terminalFailure != null) throw this.#terminalFailure;
		if (this.#released) throw loopClosedError();
	}

	/** Make one background drive failure terminal and observable to every
	 * binding waiter before releasing the loop-owned graph. */
	#failBackground(error: unknown): void {
		if (this.#terminalFailure != null) return;
		const failure = asPancakeError(error, "driver loop failed");
		this.#terminalFailure = failure;
		this.#parkStop = true;
		if (this.#progressTimer != null) {
			clearTimeout(this.#progressTimer);
			this.#progressTimer = null;
		}
		for (const waiter of this.#pendingDials.values()) waiter.reject(failure);
		this.#pendingDials.clear();
		for (const waiter of this.#pendingListeners.values()) {
			waiter.onAbort?.();
			waiter.reject(failure);
		}
		this.#pendingListeners.clear();
		for (const waiter of this.#sessionCloses.values()) waiter.reject(failure);
		this.#sessionCloses.clear();
		for (const waiters of this.#acceptWaiters.values()) {
			for (const waiter of waiters) waiter.reject(failure);
		}
		this.#acceptWaiters.clear();
		this.#accepts.clear();
		this.#listeners.clear();
		this.#closingListeners.clear();
		this.#unclaimedSessions.clear();
		this.#wrapper.failPendingVows(failure);
		this.#wrapper.signalCloseActivity();

		if (this.#released) return;
		const wrapper = this.#wrapper;
		wrapper.prepareLoopTeardown();
		const rc = loopS.pancake_driver_release(this.#h);
		if (rc !== INVALID_ARGUMENT) {
			if (this.#finalizerState != null) this.#finalizerState.handle = NULL;
			driverLoopFinalizer.unregister(this);
			this.#h = NULL;
			this.#released = true;
			wrapper.finishLoopTeardown();
		}
		try {
			checkDriver(rc);
		} catch (releaseError) {
			// INVALID_ARGUMENT refused before consumption; every other failure is
			// the outcome of a completed consuming teardown.
			failure.cause = releaseError;
		}
	}

	/** The exact Host wrapper transferred into this loop. */
	wrapperHost(): Host {
		return this.#wrapper;
	}

	/** Stop stepping and release the loop, its sessions, and its host.
	 * Idempotent; safe to start from inside a behavior turn (the native
	 * release runs after the enclosing step unwinds). */
	close(options: CloseOptions = {}): Promise<void> {
		if (this.#terminalFailure != null) return Promise.reject(this.#terminalFailure);
		const encoded = encodeCloseOptions(options);
		if (this.#closing == null) {
			this.#beginClose(encoded);
			const begin = () => this.#doClose();
			this.#closing = insideTurn() ? Promise.resolve().then(begin) : begin();
			void this.#closing.catch(() => {});
		} else if (!this.#released) {
			this.#beginClose(encoded);
			return this.#closing;
		}
		return this.#closing;
	}

	/** The server-shaped close (ADR-0112): stop accepting now, release the
	 * unclaimed queue, and close the loop once the last application-owned
	 * session is gone — sessions already yielded (or dialed on this loop's
	 * Host) remain open until their owners close them, exactly the byte-fed
	 * server's contract. Resolves at the eventual native release barrier. */
	requestClose(): Promise<void> {
		if (this.#terminalFailure != null) return Promise.reject(this.#terminalFailure);
		if (this.#closing != null) return this.#closing;
		this.#closeRequested = true;
		checkDriver(loopS.pancake_driver_retire(this.#h));
		// Retire changes what a step can conclude while a close driver may
		// already be parked; wake it so it re-reads progress.
		this.#wrapper.signalCloseActivity();
		const begin = () => this.#doClose();
		this.#closing = insideTurn() ? Promise.resolve().then(begin) : begin();
		void this.#closing.catch(() => {});
		return this.#closing;
	}

	#beginClose(encoded: Uint8Array): void {
		checkDriver(loopS.pancake_driver_close(this.#h, encoded));
		// The close call escalates pending-work policy and may install a new
		// finite deadline while a close driver is already parked without a
		// timer; wake it so it re-reads the wait budget.
		this.#wrapper.signalCloseActivity();
	}

	#closeState(): { readonly closed: boolean; readonly timedOut: boolean } {
		const out = new Uint8Array(4);
		const rc = loopS.pancake_driver_lifecycle_state(this.#h, ab(out));
		if (rc !== OK && rc !== TIMEOUT) checkDriver(rc);
		return {
			closed: new DataView(out.buffer).getUint32(0, true) === LIFECYCLE_CLOSED,
			timedOut: rc === TIMEOUT,
		};
	}

	/** The longest a close driver may park before stepping again: milliseconds
	 * to the nearest pending-work deadline (the close grace, a session's close
	 * grace, a dial or listener setup budget), clamped at zero, or -1 when no
	 * finite deadline is pending and only loop activity can advance terminal
	 * progress. */
	#stepWaitMs(): number {
		if (this.#released) return 0;
		const out = new Uint8Array(4);
		checkDriver(loopS.pancake_driver_step_wait_ms(this.#h, ab(out)));
		return new DataView(out.buffer).getInt32(0, true);
	}

	/** Re-arm the loop's one clock from pancake's complete pending-work
	 * deadline. No operation kind is interpreted here: deadline policy and
	 * arbitration stay native, while JavaScript owns only `setTimeout`. */
	#rearmProgressClock(): void {
		if (this.#progressTimer != null) {
			clearTimeout(this.#progressTimer);
			this.#progressTimer = null;
		}
		if (this.#released || this.#terminalFailure != null) return;
		const waitMs = this.#stepWaitMs();
		if (waitMs < 0) return;
		this.#progressTimer = setTimeout(() => {
			this.#progressTimer = null;
			try {
				this.stepNow();
			} catch (error) {
				this.#failBackground(error);
			}
		}, waitMs);
	}

	/** Park a close driver until loop activity or the nearest pending-work
	 * deadline; with no finite deadline pending it parks on `activity` alone,
	 * because readiness wakes the park task, whose step signals activity. A
	 * grace expiry takes effect only inside a step, so the deadline half of
	 * this wait is what turns an expired grace into the escalating step. */
	async #waitStepWake(activity: Promise<void>): Promise<void> {
		const waitMs = this.#stepWaitMs();
		if (waitMs < 0) {
			await activity;
			return;
		}
		let timer: ReturnType<typeof setTimeout> | undefined;
		const deadline = new Promise<void>((resolve) => {
			timer = setTimeout(resolve, waitMs);
		});
		try {
			await Promise.race([activity, deadline]);
		} finally {
			clearTimeout(timer);
		}
	}

	async #doClose(): Promise<void> {
		try {
			this.#closeRequested = true;
			this.#dispatchCommittedEvents();
			let timedOut = false;
			while (true) {
				// Arm before stepping (the lost-wakeup discipline): progress landing
				// after this line resolves the wait below, and progress landing
				// before it is visible to the lifecycle read that follows. A step
				// that ran work signals the armed waiter, so the wait returns at
				// once and the loop re-checks instead of parking over undrained
				// work.
				const activity = this.#wrapper.armCloseActivity();
				this.stepNow();
				const state = this.#closeState();
				timedOut ||= state.timedOut;
				if (state.closed) break;
				await this.#waitStepWake(activity);
			}
			if (this.#progressTimer != null) {
				clearTimeout(this.#progressTimer);
				this.#progressTimer = null;
			}
			const wrapper = this.#wrapper;
			this.#parkStop = true;
			let wakeFailure: unknown | null = null;
			try {
				await loopS.pancake_driver_wake(this.#h);
			} catch (error) {
				// The bounded park still exits and must be joined before release;
				// retain the wake refusal and report it after that ownership barrier.
				wakeFailure = error;
			}
			if (this.#parkExited != null) await this.#parkExited;
			// The wrapper half first: its trace drain still reads the live handle.
			// Driver release below then frees loop, sessions, and host together.
			wrapper.prepareLoopTeardown();
			const handle = this.#h;
			const releaseResult = loopS.pancake_driver_release(handle);
			if (releaseResult !== INVALID_ARGUMENT) {
				if (this.#finalizerState != null) this.#finalizerState.handle = NULL;
				driverLoopFinalizer.unregister(this);
				this.#h = NULL;
				this.#released = true;
				for (const listener of [...this.#listeners]) {
					this.#closingListeners.add(listener);
					this.#finishListenerClose(listener, loopClosedError());
				}
				wrapper.finishLoopTeardown();
			}
			checkDriver(releaseResult);
			if (wakeFailure !== null) throw wakeFailure;
			if (timedOut) {
				throw new PancakeError(TIMEOUT, "finish close exhausted its grace period");
			}
		} catch (error) {
			this.#failBackground(error);
			throw this.#terminalFailure ?? error;
		}
	}

	/** Announce the embedder is serving `ptr`: post-open setup is done, so the
	 * loop may deliver inbound application frames (bytes that arrived early
	 * replay in order). Idempotent; the loop tier's spelling of the byte-fed
	 * rule that `serve()` resumes frames held behind the handshake. */
	serveSession(ptr: Ptr): void {
		if (this.#terminalFailure != null) throw this.#terminalFailure;
		if (this.#released || ptr === NULL) return;
		checkDriver(loopS.pancake_driver_session_serve(this.#h, ptr));
		this.scheduleStep();
	}

	/** Release one loop-owned session through the loop's own verb, which also
	 * drops queued events naming it. A no-op once the loop is released: the
	 * loop's release freed its sessions itself. */
	nativeSessionRelease(ptr: Ptr): void {
		if (this.#released || ptr === NULL) {
			this.#unclaimedSessions.delete(ptr);
			return;
		}
		checkDriver(loopS.pancake_driver_session_release(this.#h, ptr));
		this.#unclaimedSessions.delete(ptr);
		// The release just recorded the session's terminal trace facts, and an
		// idle loop runs no next step to flush them; drain here so a close is
		// heard when it happens.
		traceDrainHost(this.#wrapper.raw);
		// The final application-owned release is what lets a retiring loop reach
		// CLOSED; wake any parked close driver to re-read progress.
		this.#wrapper.signalCloseActivity();
	}

	/** Resolve and claim the exporter session named by one Host capability. */
	claimReferenceExporter(reference: Uint8Array): Ptr | null {
		const out = new Uint8Array(8);
		checkDriver(loopS.pancake_driver_claim_reference_exporter(this.#h, ab(reference), ab(out)));
		const ptr = outPointer(out);
		return ptr === NULL ? null : ptr;
	}

	/** Close one loop-owned session under the shared native barrier, observing
	 * timeout before the public Session releases its opaque handle. */
	closeSession(ptr: Ptr, options: CloseOptions = {}): Promise<void> {
		if (this.#terminalFailure != null) return Promise.reject(this.#terminalFailure);
		if (this.#released) return Promise.reject(loopClosedError());
		const encoded = encodeCloseOptions(options);
		let waiter = this.#sessionCloses.get(ptr);
		const created = waiter == null;
		if (waiter == null) {
			let resolve!: () => void;
			let reject!: (error: PancakeError) => void;
			const promise = new Promise<void>((ok, fail) => {
				resolve = ok;
				reject = fail;
			});
			waiter = { promise, resolve, reject };
			this.#sessionCloses.set(ptr, waiter);
		}
		try {
			checkDriver(loopS.pancake_driver_session_close(this.#h, ptr, encoded));
		} catch (error) {
			if (!created) return Promise.reject(error);
			this.#sessionCloses.delete(ptr);
			waiter.reject(error as PancakeError);
			return waiter.promise;
		}
		// The close call escalates pending-work policy and may install a new
		// finite deadline while a close driver (this session's or the loop's)
		// is already parked; wake it so it re-reads the wait budget.
		this.#wrapper.signalCloseActivity();
		this.#finishSessionCloseIfClosed(ptr);
		if (created && this.#sessionCloses.get(ptr) === waiter) {
			void this.#driveSessionClose(ptr, waiter);
		}
		return waiter.promise;
	}

	/** The deadline-stepper behind one session's native close barrier: a grace
	 * expiry takes effect only inside a step, so this driver steps on every
	 * loop-activity or deadline wake until the session's lifecycle turns
	 * terminal. Escalating repeats of `closeSession` share it. */
	async #driveSessionClose(
		ptr: Ptr,
		waiter: {
			readonly promise: Promise<void>;
			readonly resolve: () => void;
			readonly reject: (error: PancakeError) => void;
		},
	): Promise<void> {
		try {
			while (!this.#released && this.#sessionCloses.get(ptr) === waiter) {
				// Arm before stepping (the lost-wakeup discipline); loop-wide
				// activity or another owner's deadline waking this driver early
				// is harmless because it re-checks.
				const activity = this.#wrapper.armCloseActivity();
				this.stepNow();
				this.#finishSessionCloseIfClosed(ptr);
				if (this.#sessionCloses.get(ptr) !== waiter) break;
				await this.#waitStepWake(activity);
			}
		} catch (error) {
			if (this.#sessionCloses.get(ptr) === waiter) {
				this.#sessionCloses.delete(ptr);
				waiter.reject(error as PancakeError);
			}
		}
	}

	#finishSessionCloseIfClosed(ptr: Ptr): void {
		const waiter = this.#sessionCloses.get(ptr);
		if (waiter == null) return;
		const out = new Uint8Array(4);
		const rc = loopS.pancake_driver_session_lifecycle_state(this.#h, ptr, ab(out));
		if (rc !== OK && rc !== TIMEOUT) {
			this.#sessionCloses.delete(ptr);
			waiter.reject(new PancakeError(rc, driverLastError() ?? undefined));
			return;
		}
		if (new DataView(out.buffer).getUint32(0, true) !== LIFECYCLE_CLOSED) return;
		this.#sessionCloses.delete(ptr);
		if (rc === TIMEOUT) waiter.reject(new PancakeError(TIMEOUT, "finish close exhausted its grace period"));
		else waiter.resolve();
	}

	// ── Extension transports ──────────────────────────────────────────────────

	/** Install one archive-owned provider inside the dynamic extent in which
	 * its construction owner is live. The registrar rejects capture and reuse. */
	installProvider(
		prepare: (register: (packageBytes: Uint8Array) => void) => void,
	): void {
		this.#guardHandle();
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
		this.#guardHandle();
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
		this.#guardHandle();
		if (this.#parkExited != null) return;
		const out = new Uint8Array(4);
		checkDriver(loopS.pancake_driver_readiness_fd(this.#h, ab(out)));
		const fd = new DataView(out.buffer).getInt32(0, true);
		const dup = Number(libcSyms().dup(fd));
		if (dup < 0) {
			throw new PancakeError(IO, "dup of the loop readiness descriptor failed");
		}
		this.#parkExited = parkerJoin(this, dup, (error) => this.#failBackground(error));
		// Drain anything already pending before the first signal.
		try {
			this.stepNow();
		} catch (error) {
			this.#failBackground(error);
			throw this.#terminalFailure ?? error;
		}
	}

	/** Whether the shared parker should retire this loop's row. */
	parkWantsExit(): boolean {
		return this.#parkStop || this.#released;
	}

	/** Make this loop's readiness descriptor fire, so the shared parker's
	 * current poll returns and its set rebuilds. Binding-internal. */
	parkWake(): void {
		if (this.#released) return;
		void loopS.pancake_driver_wake(this.#h).catch((error: unknown) => {
			this.#failBackground(error);
		});
	}

	/** Schedule one loop step soon — how a wrapper verb's kick reaches the
	 * drain. Deferred through a microtask, so a kick from inside a behavior
	 * turn steps only after the enclosing step (or feed) unwinds. */
	scheduleStep(): void {
		if (this.#released || this.#terminalFailure != null || this.#stepScheduled) return;
		this.#stepScheduled = true;
		queueMicrotask(() => {
			this.#stepScheduled = false;
			try {
				this.stepNow();
			} catch (error) {
				this.#failBackground(error);
			}
		});
	}

	/** Drain zero-timeout steps and events through quiescence on the driving
	 * thread. Reaching WOULD_BLOCK permits the readiness edge to be cleared. */
	stepNow(): void {
		if (this.#terminalFailure != null) throw this.#terminalFailure;
		if (this.#released || this.#stepping || insideTurn()) return;
		this.#stepping = true;
		// Whether any step observed work. This is the loop tier's one step/drain
		// funnel — the park task, `scheduleStep`, the progress clock, and the close
		// drivers all step through here — so signaling on progress here is what
		// wakes a close driver parked on loop activity. Signaling only when work
		// ran keeps a close driver's own quiescent steps from waking the waiter
		// it just armed.
		let progressed = false;
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
				const prev = host != null ? enterDeliver(host) : null;
				let rc: number;
				try {
					rc = loopS.pancake_driver_step(this.#h, 0);
				} finally {
					if (host != null) exitDeliver(prev);
				}
				if (rc === WOULD_BLOCK) break;
				checkDriver(rc);
				progressed = true;
				const events = this.#popEvents();
				host?.drainParkedReleases();
				if (events.length > 0) this.#dispatch(events);
			}
		} finally {
			this.#stepping = false;
			if (progressed) {
				// The ring drains on the same unwind as the steps that filled
				// it, the loop tier's mirror of the byte-fed kick: a captured
				// fact must not wait on the next verb (or on an annotation
				// happening by) to reach the sink.
				traceDrainHost(this.#wrapper.raw);
				this.#wrapper.signalCloseActivity();
			}
		}
		this.#rearmProgressClock();
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
			const failure: DriverFailure = {
				primaryResult: dv.getInt32(L.DRIVER_EVENT_PRIMARY_RESULT_OFF, true),
				primaryName: utf8Decoder.decode(readBytes(
					L.getPtr(dv, L.DRIVER_EVENT_PRIMARY_NAME_OFF),
					L.getUsize(dv, L.DRIVER_EVENT_PRIMARY_NAME_LEN_OFF),
				)),
				secondaryResult: dv.getInt32(L.DRIVER_EVENT_SECONDARY_RESULT_OFF, true),
				secondaryCount: dv.getUint32(L.DRIVER_EVENT_SECONDARY_COUNT_OFF, true),
				secondaryName: utf8Decoder.decode(readBytes(
					L.getPtr(dv, L.DRIVER_EVENT_SECONDARY_NAME_OFF),
					L.getUsize(dv, L.DRIVER_EVENT_SECONDARY_NAME_LEN_OFF),
				)),
			};
			const operationId = dv.getBigUint64(L.DRIVER_EVENT_OPERATION_ID_OFF, true);
			const listenerId = dv.getBigUint64(L.DRIVER_EVENT_LISTENER_ID_OFF, true);
			const session = L.getPtr(dv, L.DRIVER_EVENT_SESSION_OFF);
			switch (kind) {
				case DRIVER_EVENT_OPENED:
					out.push({ kind: "opened", operationId, session });
					break;
				case DRIVER_EVENT_OPEN_FAILED:
					out.push({
						kind: "openFailed",
						operationId,
						...failure,
					});
					break;
				case DRIVER_EVENT_LISTENER_READY:
					out.push({ kind: "listenerReady", listener: listenerId });
					break;
				case DRIVER_EVENT_LISTENER_FAILED:
					out.push({
						kind: "listenerFailed",
						listener: listenerId,
						...failure,
					});
					break;
				case DRIVER_EVENT_ACCEPTED:
					out.push({ kind: "accepted", listener: listenerId, session });
					break;
				case DRIVER_EVENT_SESSION_CLOSED:
					out.push({
						kind: "sessionClosed",
						session,
						...failure,
					});
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
					const waiter = this.#pendingDials.get(event.operationId);
					this.#pendingDials.delete(event.operationId);
					if (waiter == null) {
						this.#unclaimedSessions.set(event.session, { kind: "open" });
						this.nativeSessionRelease(event.session);
					} else {
						this.#unclaimedSessions.set(event.session, { kind: "open" });
						waiter.resolve(event.session);
					}
					break;
				}
				case "openFailed": {
					const waiter = this.#pendingDials.get(event.operationId);
					this.#pendingDials.delete(event.operationId);
					waiter?.reject(driverEventFailure(event, "dial"));
					break;
				}
				case "listenerReady": {
					if (this.#closingListeners.has(event.listener)) break;
					const waiter = this.#pendingListeners.get(event.listener);
					if (waiter == null) break;
					this.#settleListener(event.listener, waiter, { ready: true });
					break;
				}
				case "listenerFailed": {
					const failure = driverEventFailure(event, "listener");
					if (this.#closingListeners.has(event.listener)) {
						this.#finishListenerClose(event.listener, failure, true);
						break;
					}
					const waiter = this.#pendingListeners.get(event.listener);
					if (waiter != null) {
						this.#settleListener(event.listener, waiter, {
							error: failure,
						});
					}
					this.#finishListenerClose(event.listener, failure, true);
					break;
				}
				case "accepted": {
					const waiters = this.#acceptWaiters.get(event.listener);
					const queue = this.#accepts.get(event.listener);
					if (waiters == null || queue == null) {
						this.#unclaimedSessions.set(event.session, { kind: "open" });
						this.nativeSessionRelease(event.session);
						throw new PancakeError(
							INTERNAL,
							`accepted session names unknown listener ${event.listener}`,
						);
					}
					this.#unclaimedSessions.set(event.session, { kind: "open" });
					const waiter = waiters?.shift();
					if (waiter != null) waiter.resolve(event.session);
					else queue.push(event.session);
					break;
				}
				case "sessionClosed": {
					this.#finishSessionCloseIfClosed(event.session);
					const failure = event.primaryResult === OK ? null : driverEventFailure(event, "session");
					// The pump's EOF choreography, one tier up: `closeTransport`
					// records local teardown and retires the shell so a later verb
					// refuses CLOSED. The native side already broke the far vows and
					// classified their FAIL completions. A session this
					// binding never wrapped (a loop-internal redeem dial) has no
					// shell to retire, so its handle is released here directly.
					const shell = host?.getSession(event.session);
					if (shell != null) void shell.nativeTransportDidClose(failure);
					else if (this.#unclaimedSessions.has(event.session)) {
						this.#unclaimedSessions.set(event.session, { kind: "closed", error: failure });
					} else {
						this.#unclaimedSessions.set(event.session, { kind: "closed", error: failure });
						this.nativeSessionRelease(event.session);
					}
					break;
				}
				case "completion": {
					if (host == null) break;
					const action = event.action;
					if (action.kind === HOST_ACTION_SETTLE) {
						host.settleVow(action.ticket, { ok: action.value });
					} else if (action.kind === HOST_ACTION_FAIL) {
						host.settleVow(action.ticket, {
							err: vowFailure(action.result, action.message),
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

	#settleListener(
		listener: bigint,
		waiter: ListenerWaiter,
		result: { ready: true } | { error: PancakeError },
	): void {
		if (this.#pendingListeners.get(listener) !== waiter) return;
		this.#pendingListeners.delete(listener);
		waiter.onAbort?.();
		if ("ready" in result) waiter.resolve(listener);
		else waiter.reject(result.error);
	}

	// ── Dial, accept, listen ───────────────────────────────────────────────────

	/** Begin a nonblocking dial and await its session handle. The handshake advances
	 * across steps (`driver.HostRuntime.startDial`), so loops on one
	 * thread can dial each other and a stalled partner costs its budget,
	 * never the loop. */
	dial(locator: Locator | string, transportOptions?: Uint8Array): Promise<Ptr> {
		this.#guardHandle();
		const parsed = typeof locator === "string" ? parseLocator(locator) : locator;
		const out = new Uint8Array(8);
		const options = transportOperationOptions(transportOptions);
		withOwnedLocator(
			parsed,
			(owned) =>
				checkDriver(
					loopS.pancake_driver_dial(this.#h, owned.borrowView(), options, ab(out)),
				),
		);
		const operationId = outU64(out);
		const pending = new Promise<Ptr>((resolve, reject) => {
			this.#pendingDials.set(operationId, { resolve, reject });
		});
		this.scheduleStep();
		return pending;
	}

	/** Await the next accepted session handle (bind a listener first), or null
	 * once the loop closes, so a server iteration ends rather than parking
	 * forever. */
	accept(listener: bigint): Promise<Ptr | null> {
		if (this.#terminalFailure != null) return Promise.reject(this.#terminalFailure);
		const queued = this.#accepts.get(listener)?.shift();
		if (queued != null) return Promise.resolve(queued);
		if (this.#released || this.#closeRequested || !this.#listeners.has(listener)) {
			return Promise.resolve(null);
		}
		return new Promise<Ptr | null>((resolve, reject) => {
			this.#acceptWaiters.get(listener)?.push({ resolve, reject });
		});
	}

	/** Bind one listener on a statically composed transport; accepted sessions
	 * arrive through `accept`. One listener per transport. */
	listen(
		transport: string,
		designator: string,
		signal?: AbortSignal,
	): Promise<bigint> {
		this.#guardHandle();
		if (signal?.aborted) {
			return Promise.reject(new PancakeError(CLOSED, "listener setup was cancelled"));
		}
		const t = utf8Encoder.encode(transport);
		const d = utf8Encoder.encode(designator);
		const out = new Uint8Array(8);
		checkDriver(loopS.pancake_driver_listen(
			this.#h,
			ab(t),
			BigInt(t.length),
			ab(d),
			BigInt(d.length),
			null,
			ab(out),
		));
		const listener = outU64(out);
		this.#listeners.add(listener);
		this.#accepts.set(listener, []);
		this.#acceptWaiters.set(listener, []);
		const pending = new Promise<bigint>((resolve, reject) => {
			const waiter: ListenerWaiter = { resolve, reject };
			this.#pendingListeners.set(listener, waiter);
			if (signal != null) {
				const onAbort = (): void =>
					this.closeListener(
						listener,
						new PancakeError(
							CLOSED,
							"listener setup was cancelled",
						),
					);
				waiter.onAbort = () => signal.removeEventListener("abort", onAbort);
				signal.addEventListener("abort", onAbort, { once: true });
				if (signal.aborted) onAbort();
			}
			this.scheduleStep();
		});
		try {
			// Arm after admission: the readiness set must include an active listener
			// when a provider completes setup synchronously.
			this.start();
			this.scheduleStep();
		} catch (error) {
			this.closeListener(
				listener,
				error instanceof PancakeError ? error : new PancakeError(IO, String(error)),
			);
		}
		return pending;
	}

	/** The listener's complete canonical OCapN locator. */
	listenerLocator(listener: bigint): Locator {
		this.#guardHandle();
		const out = new Uint8Array(L.LOCATOR_VIEW_SIZE);
		checkDriver(loopS.pancake_driver_listener_locator(this.#h, listener, ab(out)));
		const owned = OwnedLocator.cloneView(out);
		try {
			return owned.value();
		} finally {
			owned.release();
		}
	}

	/** Copy opaque provider state that restores this listener's local address. */
	listenerRestorationState(listener: bigint): Uint8Array {
		this.#guardHandle();
		let capacity = 0;
		while (true) {
			const out = new Uint8Array(capacity);
			const count = new Uint8Array(L.ptrSize);
			const code = loopS.pancake_driver_listener_restoration_state(
				this.#h,
				listener,
				ab(out),
				BigInt(out.length),
				ab(count),
			);
			const needed = Number(L.getUsize(new DataView(count.buffer), 0));
			if (code === BUFFER_TOO_SMALL) {
				capacity = needed;
				continue;
			}
			checkDriver(code);
			return out.subarray(0, needed);
		}
	}

	/** Replace this listener's advertised locator through its native owner. */
	advertiseListener(listener: bigint, locator: Locator | string): void {
		this.#guardHandle();
		const parsed = typeof locator === "string" ? parseLocator(locator) : locator;
		withOwnedLocator(parsed, (owned) =>
			checkDriver(
				loopS.pancake_driver_listener_advertise(this.#h, listener, owned.borrowView()),
			));
	}

	/** Select this listener's locator as the Host's acceptable location. */
	selectListener(listener: bigint): void {
		this.#guardHandle();
		checkDriver(loopS.pancake_driver_listener_select(this.#h, listener));
	}

	/** Stop one listener. Events committed before close remain queued; no later
	 * accepted event can name it after this returns. */
	closeListener(listener: bigint, reason: PancakeError = loopClosedError()): void {
		if (!this.#listeners.has(listener) || this.#closingListeners.has(listener)) return;
		this.#closingListeners.add(listener);
		if (this.#released) {
			this.#finishListenerClose(listener, reason);
			return;
		}
		this.#closeListener(listener, reason);
	}

	#closeListener(listener: bigint, reason: PancakeError): void {
		try {
			this.#closeListenerNative(listener);
		} catch (error) {
			this.#closingListeners.delete(listener);
			throw error;
		}
		let failure: unknown = null;
		try {
			this.#dispatchCommittedEvents();
		} catch (error) {
			failure = error;
		}
		try {
			this.#finishListenerClose(
				listener,
				failure instanceof PancakeError ? failure : reason,
			);
		} catch (error) {
			failure ??= error;
		}
		if (failure != null) throw failure;
	}

	/** Dispatch only events committed by earlier steps. Listener close uses
	 * this after native admission is sealed, so it cannot create a new accept
	 * while preserving an old one. */
	#dispatchCommittedEvents(): void {
		const events = this.#popEvents();
		if (events.length > 0) {
			this.#dispatch(events);
			// A drain outside `stepNow` still advances close-relevant state
			// (session closes, releases); wake any parked close driver.
			this.#wrapper.signalCloseActivity();
		}
	}

	#closeListenerNative(listener: bigint): void {
		checkDriver(loopS.pancake_driver_listener_close(this.#h, listener));
	}

	#finishListenerClose(listener: bigint, reason?: PancakeError, rejectAccepts = false): void {
		let failure: unknown = null;
		const waiter = this.#pendingListeners.get(listener);
		if (waiter != null) {
			this.#settleListener(listener, waiter, { error: reason ?? loopClosedError() });
		}
		this.#listeners.delete(listener);
		this.#closingListeners.delete(listener);
		for (const waiter of this.#acceptWaiters.get(listener)?.splice(0) ?? []) {
			if (rejectAccepts && reason != null) waiter.reject(reason);
			else waiter.resolve(null);
		}
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
		const state = this.#unclaimedSessions.get(ptr) ?? { kind: "open" as const };
		const session = Session.adoptLoopSession(ptr, host, new LoopTransport(this));
		this.#unclaimedSessions.delete(ptr);
		if (state.kind === "closed") void session.nativeTransportDidClose(state.error);
		return session;
	}

	/** Dial through the loop and wrap the opened session as the public
	 * `Session`. */
	async connectSession(
		locator: Locator | string,
		transportOptions?: Uint8Array,
	): Promise<Session> {
		return this.adoptSession(await this.dial(locator, transportOptions));
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

	static async open(
		loop: DriverLoop,
		transport: string,
		designator: string,
		signal?: AbortSignal,
	): Promise<DriverListener> {
		const listener = await loop.listen(transport, designator, signal);
		return new DriverListener(loop, listener);
	}

	get host(): Host {
		return this.#host;
	}

	locator(): Locator {
		if (this.#closed) throw loopClosedError();
		return this.#loop.listenerLocator(this.#listener);
	}

	restorationState(): Uint8Array {
		if (this.#closed) throw loopClosedError();
		return this.#loop.listenerRestorationState(this.#listener);
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
	}
}
