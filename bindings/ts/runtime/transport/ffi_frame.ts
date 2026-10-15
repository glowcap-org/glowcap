import {
	FRAME_BYTES_OFF,
	FRAME_LEN_OFF,
	FRAME_SHAPE_BYTE,
	FRAME_SHAPE_OFF,
	FRAME_SIZE,
} from "../internal/constants.ts";
import { ffi } from "../internal/ffi/runtime.ts";

/** One FFI frame descriptor and its view, filled in place for each write.
 * A queue owns one because its writes run one at a time: the descriptor a
 * FFI call borrows is not touched again until that call has completed, so
 * a fresh descriptor per write was two allocations buying nothing. */
export class FrameDescriptorScratch {
	readonly bytes = new Uint8Array(FRAME_SIZE);
	readonly view = new DataView(this.bytes.buffer);
}

/** One frame owned for an asynchronous FFI write. Construction is the
 * explicit boundary copy: the caller may mutate or release its input as soon
 * as `writeFrame` returns. `argument` takes the nested pointer only in the
 * synchronous window of the outer FFI call. */
export class AsyncFfiFrame {
	readonly #bytes: Uint8Array;
	readonly #descriptor: FrameDescriptorScratch;
	readonly byteLength: number;

	constructor(frame: Uint8Array, descriptor: FrameDescriptorScratch) {
		this.#bytes = frame.slice();
		this.#descriptor = descriptor;
		this.byteLength = this.#bytes.byteLength;
	}

	/** The descriptor an FFI write borrows. It is the owning queue's one
	 * scratch, valid until that write completes and the next one fills it. */
	argument(): Uint8Array {
		const { bytes, view } = this.#descriptor;
		view.setBigUint64(FRAME_BYTES_OFF, ffi.pointerOf(this.#bytes), true);
		view.setBigUint64(FRAME_LEN_OFF, BigInt(this.#bytes.length), true);
		view.setUint32(FRAME_SHAPE_OFF, FRAME_SHAPE_BYTE, true);
		return bytes;
	}
}

// A frame-scale byte waterline plus this count keeps both payload retention and
// zero-length promise closures bounded. Ordinary Session pumps have one write
// outstanding; the extra seats exist only for direct concurrent connection use.
const maxPendingWrites = 16;

/** Validate the JavaScript representation before it crosses a `usize` ABI or
 * becomes the connection's write-admission waterline. */
export function checkedMaxFrameBytes(value: number): number {
	if (!Number.isSafeInteger(value) || value <= 0) {
		throw new TypeError("maxFrameBytes must be a positive safe integer");
	}
	return value;
}

/** Own and serialize asynchronous FFI writes under a bounded admission
 * budget. One admitted frame may take the queue to its byte waterline; later
 * calls are refused until queued ownership retires. Admission precedes the
 * copy, making refusal allocation-free and preserving the caller's right to
 * mutate its input as soon as `run` returns. */
export class AsyncFfiWriteQueue {
	readonly #label: string;
	readonly #highWaterBytes: number;
	#pendingBytes = 0;
	#pendingWrites = 0;
	#tail: Promise<void> = Promise.resolve();
	readonly #descriptor = new FrameDescriptorScratch();

	constructor(label: string, highWaterBytes: number) {
		this.#label = label;
		this.#highWaterBytes = highWaterBytes;
	}

	run<T>(frame: Uint8Array, body: (owned: AsyncFfiFrame) => Promise<T>): Promise<T> {
		if (
			frame.byteLength > this.#highWaterBytes ||
			this.#pendingWrites >= maxPendingWrites ||
			this.#pendingBytes + frame.byteLength > this.#highWaterBytes
		) {
			return Promise.reject(new Error(`glowcap ${this.#label} outbound queue exceeded`));
		}

		const owned = new AsyncFfiFrame(frame, this.#descriptor);
		this.#pendingWrites++;
		this.#pendingBytes += owned.byteLength;
		const result = this.#tail.then(() => body(owned));
		const completed = result.finally(() => {
			this.#pendingWrites--;
			this.#pendingBytes -= owned.byteLength;
		});
		this.#tail = completed.then(() => {}, () => {});
		return completed;
	}
}
