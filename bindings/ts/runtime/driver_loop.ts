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

import { DEFAULT_FRAME_CAP } from "@glowcap/abi";
import { type DriverLoopOptions, encodeDriverOptions } from "./driver_loop/options.ts";
import { Host } from "./host.ts";
import { checkDriver } from "./internal/driver_failure.ts";
import { loopS } from "./internal/ffi/driver.ts";
import { ffi, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer } from "./internal/seam.ts";
import { type Codec, DEFAULT_CODEC } from "./value.ts";

export { DriverListener } from "./driver_loop/listener.ts";
export type { DriverLoopOptions } from "./driver_loop/options.ts";

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

import { DriverLoopConnections } from "./driver_loop/connections.ts";

/** One stepping native loop over one multi-session host (ADR-0112).
 *
 * Construct with `open` on the thread that will drive it, `start()` to park on
 * the readiness descriptor, and `close()` before dropping it. One thread
 * drives one loop; `glowcap_driver_wake` is the one cross-thread call, and the
 * park task is the only place it is needed here. */
export class DriverLoop extends DriverLoopConnections {
	private constructor(handle: Ptr, wrapper: Host) {
		super(handle, wrapper);
	}

	static open(
		opts: DriverLoopOptions & {
			seed?: Uint8Array;
			codec?: Codec;
			frameCap?: number;
		} = {},
	): DriverLoop {
		const codec = opts.codec ?? DEFAULT_CODEC;
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
		const options = encodeDriverOptions(opts);
		const out = new Uint8Array(8);
		checkDriver(loopS.glowcap_driver_take_host(
			host.raw,
			ffi.pointerOf(options),
			ab(out),
		));
		const loop = new DriverLoop(outPointer(out), host);
		try {
			loop._armFinalizer(host.attachDriverLoop(loop));
			return loop;
		} catch (error) {
			void loop.close().catch((cleanup) => {
				host.recordCallerlessBindingFailure("driver-loop.take-host.rollback", cleanup);
			});
			throw error;
		}
	}
}
