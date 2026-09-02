import { IO } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { ffi, type Symbols } from "../internal/ffi/runtime.ts";
import { ab } from "../internal/seam.ts";

/** How long one off-thread park waits before stepping anyway. A wake (or any
 * readiness) returns early; the bound exists because an in-flight handshake's
 * budget expiry is a clock fact no kernel readiness reports. */
const PARK_MS = 1_000;

export interface ParkedDriverLoop {
	parkWake(): void;
	parkWantsExit(): boolean;
	stepNow(): void;
}

interface ParkedRow {
	loop: ParkedDriverLoop;
	dup: number;
	exited: () => void;
	failed: (error: unknown) => void;
}

const parkedLoops: ParkedRow[] = [];
let parkerRunning = false;

export function duplicateReadinessDescriptor(fd: number): number {
	const dup = Number(libcSyms().dup(fd));
	if (dup < 0) {
		throw new GlowcapError(IO, "dup of the loop readiness descriptor failed");
	}
	return dup;
}

export function joinParker(
	loop: ParkedDriverLoop,
	dup: number,
	failed: (error: unknown) => void,
): Promise<void> {
	let exited!: () => void;
	const gone = new Promise<void>((resolve) => (exited = resolve));
	parkedLoops.push({ loop, dup, exited, failed });
	if (!parkerRunning) {
		parkerRunning = true;
		void runParker()
			.catch((error: unknown) => {
				for (const row of parkedLoops.splice(0)) {
					row.failed(error);
					libcSyms().close(row.dup);
					row.exited();
				}
			})
			.finally(() => {
				parkerRunning = false;
			});
	} else {
		// The parker is mid-cycle on the previous set; wake any polled member
		// so it rebuilds with this row included rather than a quantum later.
		parkedLoops[0]?.loop.parkWake();
	}
	return gone;
}

async function runParker(): Promise<void> {
	while (parkedLoops.length > 0) {
		for (let i = parkedLoops.length - 1; i >= 0; i--) {
			const row = parkedLoops[i];
			if (row.loop.parkWantsExit()) {
				parkedLoops.splice(i, 1);
				libcSyms().close(row.dup);
				row.exited();
			}
		}
		const rows = [...parkedLoops];
		if (rows.length === 0) break;
		// pollfd rows: { fd: i32, events: i16, revents: i16 }.
		const set = new Uint8Array(8 * rows.length);
		const view = new DataView(set.buffer);
		rows.forEach((row, i) => {
			view.setInt32(8 * i, row.dup, true);
			view.setInt16(8 * i + 4, 1, true); // POLLIN
			view.setInt16(8 * i + 6, 0, true);
		});
		const n = Number(await libcSyms().poll(ab(set), BigInt(rows.length), PARK_MS));
		if (n < 0) {
			const error = new GlowcapError(IO, "poll of loop readiness descriptors failed");
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
	for (const row of parkedLoops.splice(0)) {
		libcSyms().close(row.dup);
		row.exited();
	}
}

// `dup(2)` and the parking `poll(2)` from libc, opened lazily. The readiness
// descriptor is owned by the loop; the parker owns and closes only its dup.
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
