// The layer-zero proof for the browser binding (ADR-0070): the byte-fed CapTP
// Host,
// compiled to freestanding wasm32 (`zig build wasm-driver`), holds a real keyed
// OCapN handshake driven entirely from JavaScript across the WASM/JS boundary.
//
// Two independent Hosts with distinct Ed25519 identities live in one wasm
// instance. One dials, one accepts, and their op:start-session frames shuttle
// between them over an in-memory byte pipe — no socket, no transport, no bridge.
// The proof is that both sessions reach `session_open`, then a wrong-peer
// sturdyref is refused before any frame is emitted. The signed handshake,
// keyed crypto, Syrup framing, entropy seam, URI parsing, and peer check all
// run inside the wasm sandbox. It mirrors the native
// `test/driver/core_host_test.zig` "two hosts complete the keyed handshake over
// fed bytes" scenario, one layer out through the wasm exports.
//
// The full binding lives one directory up: `mod.ts` / `adapter.ts` grow the
// same linear-memory marshalling into the runtime's wasm adapter, proved end
// to end (WebSocket, keyed handshake, both call directions) by
// `zig build web-peer-test`.

// Target-independent ABI values come straight from the generated, staleness-
// gated mirror (`gen-ts-abi-check`), so this proof cannot drift from the C ABI.
import {
	CAPTP_V1_0,
	CODEC_SYRUP,
	DEFAULT_FRAME_CAP,
	DESIGNATOR_SCHEME_ADDRESS,
	FEATURE_FULL,
	HINTS_BOOLEAN_FALSE,
	HOST_OUTBOUND_PREFIX_CAP,
	INVALID_ARGUMENT,
	LOCATOR_VIEW_ABI_VERSION,
	OK,
	WOULD_BLOCK,
} from "@pancake/abi";
import { layoutFromWasmDescriptor } from "../../runtime/internal/layout.ts";

// The `PancakeManagedFrame` byte offsets ARE target-specific (wasm32 pointers
// and usize are four bytes), so they cannot come from the 64-bit `abi.ts`. The
// wasm module reports its own layout instead, reflected at the wasm32 target it
// was compiled for, so a struct change regenerates these rather than silently
// invalidating a hand-copied constant. Read once, after instantiation.

const wasmPath = new URL("../../../../zig-out/wasm/pancake_host.wasm", import.meta.url);

type Exports = {
	memory: WebAssembly.Memory;
	pancake_wasm_alloc: (len: number) => number;
	pancake_wasm_free: (ptr: number, len: number) => void;
	pancake_host_new: (
		seed: number,
		seedLen: number,
		frameCap: number,
		verifyPartner: number,
		codec: number,
		captpVersion: number,
		features: number,
		localTurnBudget: number,
		outHost: number,
	) => number;
	pancake_host_release: (host: number) => void;
	pancake_host_designator_from_seed: (
		seed: number,
		seedLen: number,
		out: number,
		outLen: number,
	) => number;
	pancake_host_set_advertised_locator: (
		host: number,
		locator: number,
	) => number;
	pancake_host_remove_advertised_locator: (
		host: number,
		transport: number,
		transportLen: number,
	) => number;
	pancake_host_session_open_dialed_locator: (
		host: number,
		locator: number,
		outSession: number,
	) => number;
	pancake_host_session_open_accepted: (
		host: number,
		transport: number,
		transportLen: number,
		designatorScheme: number,
		serverDesignator: number,
		serverDesignatorLen: number,
		acceptedLocalAddr: number,
		acceptedLocalAddrLen: number,
		outSession: number,
	) => number;
	pancake_host_session_release: (session: number) => void;
	pancake_host_session_is_open: (session: number) => number;
	pancake_host_session_feed_bytes: (
		session: number,
		bytes: number,
		len: number,
	) => number;
	pancake_host_session_enliven: (
		session: number,
		sturdyrefUri: number,
		sturdyrefUriLen: number,
		outVow: number,
	) => number;
	pancake_host_session_take_outbound: (
		session: number,
		outFrame: number,
		outPrefix: number,
		prefixCap: number,
		outPrefixLen: number,
	) => number;
	pancake_managed_frame_release: (frame: number) => void;
	pancake_host_last_error: (out: number, cap: number) => number;
	pancake_wasm_abi_layout: (out: number, cap: number) => number;
};

const wasmBytes = await Deno.readFile(wasmPath);
// The module declares the behavior-dispatch and hosted-free imports. The real
// callbacks live in the `@pancake/web` adapter; this smoke hosts no objects, so
// no-op stubs only need to exist for the module to instantiate.
const { instance } = await WebAssembly.instantiate(wasmBytes, {
	env: {
		pancake_behavior_trampoline: (
			_ctx: number,
			_turn: number,
			_verbPtr: number,
			_verbLen: number,
			_argsPtr: number,
			_argsLen: number,
			_outReplyPtr: number,
		) => 0,
		pancake_hosted_free_trampoline: (_ctx: number) => {},
	},
});
const ex = instance.exports as unknown as Exports;
const mem = ex.memory;

// The wasm heap can grow (invalidating old ArrayBuffers), so every view is
// materialized fresh against the current buffer.
const u8 = () => new Uint8Array(mem.buffer);
const dv = () => new DataView(mem.buffer);
const readU32 = (off: number) => dv().getUint32(off, true);

// The wasm32 `PancakeManagedFrame` byte offsets are target-specific (four-byte
// pointers and `usize`), so the module reports its own layout rather than the
// 64-bit host mirror in `abi.ts`. `pancake_wasm_abi_layout` writes a blob of
// little-endian u32 words: for each struct in canonical order, the words are
// `name_hash, size, nfields, off_0 … off_{nfields-1}` — an FNV-1a identity
// over the struct's manifest prefix, then the offsets in field-declaration
// order. A cap=0 probe returns the total word count; allocate `count * 4`
// bytes and call again to fill. `PancakeManagedFrame` is struct index 0
// (fields: bytes, len, shape, release, private_words), so its block is
// `hash, size, 5, bytes_off, len_off, …`.
function readLayout() {
	const count = ex.pancake_wasm_abi_layout(0, 0);
	const ptr = ex.pancake_wasm_alloc(count * 4);
	if (ptr === 0) throw new Error("wasm alloc failed for abi layout descriptor");
	try {
		if (ex.pancake_wasm_abi_layout(ptr, count) !== count) {
			throw new Error("pancake_wasm_abi_layout returned a short descriptor");
		}
		return layoutFromWasmDescriptor(
			new Uint32Array(mem.buffer.slice(ptr, ptr + count * 4)),
		);
	} finally {
		ex.pancake_wasm_free(ptr, count * 4);
	}
}

const L = readLayout();
const MF_SIZE = L.MANAGED_FRAME_SIZE;
const MF_BYTES_OFF = L.MANAGED_FRAME_BYTES_OFF;
const MF_LEN_OFF = L.MANAGED_FRAME_LEN_OFF;

function writeBytes(bytes: Uint8Array): number {
	if (bytes.length === 0) return 0;
	const ptr = ex.pancake_wasm_alloc(bytes.length);
	if (ptr === 0) throw new Error("wasm alloc failed");
	u8().set(bytes, ptr);
	return ptr;
}
const enc = new TextEncoder();
function writeStr(s: string): { ptr: number; len: number } {
	const bytes = enc.encode(s);
	return { ptr: writeBytes(bytes), len: bytes.length };
}
const free = (ptr: number, len: number) => ex.pancake_wasm_free(ptr, len);

function lastHostError(): string {
	const cap = 256;
	const ptr = ex.pancake_wasm_alloc(cap);
	try {
		const len = ex.pancake_host_last_error(ptr, cap);
		return new TextDecoder().decode(u8().slice(ptr, ptr + Math.min(len, cap)));
	} finally {
		free(ptr, cap);
	}
}

function hostNew(seed: Uint8Array): number {
	// Durable identity followed by a session-key root, so every session this
	// host opens signs with its own key (ADR-0097). The wasm module draws no
	// entropy; the page supplies it, exactly as the native bindings do.
	const seedWithRoot = new Uint8Array(64);
	seedWithRoot.set(seed.subarray(0, 32), 0);
	crypto.getRandomValues(seedWithRoot.subarray(32));
	const seedPtr = writeBytes(seedWithRoot);
	const outPtr = ex.pancake_wasm_alloc(4);
	try {
		const rc = ex.pancake_host_new(
			seedPtr,
			seedWithRoot.length,
			DEFAULT_FRAME_CAP,
			1, // verify_partner: the secure default
			CODEC_SYRUP,
			CAPTP_V1_0,
			FEATURE_FULL,
			0, // local_turn_budget: unbounded
			outPtr,
		);
		if (rc !== OK) throw new Error(`pancake_host_new failed: rc=${rc}`);
		return readU32(outPtr);
	} finally {
		free(seedPtr, seedWithRoot.length);
		free(outPtr, 4);
	}
}

function designatorFromSeed(seed: Uint8Array): string {
	const seedPtr = writeBytes(seed);
	const out = ex.pancake_wasm_alloc(64);
	try {
		const rc = ex.pancake_host_designator_from_seed(seedPtr, seed.length, out, 64);
		if (rc !== OK) throw new Error(`designator_from_seed failed: rc=${rc}`);
		return new TextDecoder().decode(u8().slice(out, out + 64));
	} finally {
		free(seedPtr, seed.length);
		free(out, 64);
	}
}

function openAccepted(host: number, transport: string, designator: string): number {
	// An address-scheme accept signs the accepted local address; the host
	// derives and retains the locator itself (no set_advertised_locator here).
	const t = writeStr(transport);
	const d = writeStr(designator);
	const outPtr = ex.pancake_wasm_alloc(4);
	try {
		const rc = ex.pancake_host_session_open_accepted(
			host,
			t.ptr,
			t.len,
			DESIGNATOR_SCHEME_ADDRESS,
			0,
			0,
			d.ptr,
			d.len,
			outPtr,
		);
		if (rc !== OK) throw new Error(`open_accepted failed: rc=${rc}`);
		return readU32(outPtr);
	} finally {
		free(t.ptr, t.len);
		free(d.ptr, d.len);
		free(outPtr, 4);
	}
}

function openDialed(host: number, transport: string, designator: string): number {
	// The host retains its own dial default and the locator travels whole as
	// one hintless view; no binding-side ensure precedes the open.
	const t = writeStr(transport);
	const d = writeStr(designator);
	const outPtr = ex.pancake_wasm_alloc(4);
	const locator = ex.pancake_wasm_alloc(L.LOCATOR_VIEW_SIZE);
	try {
		const view = dv();
		view.setUint32(locator + L.LOCATOR_VIEW_ABI_VERSION_OFF, LOCATOR_VIEW_ABI_VERSION, true);
		view.setUint32(locator + L.LOCATOR_VIEW_STRUCT_SIZE_OFF, L.LOCATOR_VIEW_SIZE, true);
		view.setUint32(locator + L.LOCATOR_VIEW_TRANSPORT_OFF, t.ptr, true);
		view.setUint32(locator + L.LOCATOR_VIEW_TRANSPORT_LEN_OFF, t.len, true);
		view.setUint32(locator + L.LOCATOR_VIEW_DESIGNATOR_OFF, d.ptr, true);
		view.setUint32(locator + L.LOCATOR_VIEW_DESIGNATOR_LEN_OFF, d.len, true);
		view.setUint32(locator + L.LOCATOR_VIEW_HINTS_OFF, 0, true);
		view.setUint32(locator + L.LOCATOR_VIEW_HINT_COUNT_OFF, 0, true);
		view.setUint32(locator + L.LOCATOR_VIEW_HINT_WIRE_FORM_OFF, HINTS_BOOLEAN_FALSE, true);
		const rc = ex.pancake_host_session_open_dialed_locator(host, locator, outPtr);
		if (rc !== OK) throw new Error(`open_dialed_locator failed: rc=${rc}`);
		return readU32(outPtr);
	} finally {
		free(t.ptr, t.len);
		free(d.ptr, d.len);
		free(outPtr, 4);
		free(locator, L.LOCATOR_VIEW_SIZE);
	}
}

const sessionOpen = (session: number) => ex.pancake_host_session_is_open(session) !== 0;

// Drain each transport-ready prefix/payload vector. Keeping the two chunks
// separate mirrors the real binding pump without allocating a combined wrapper.
function drainOutbound(session: number): Uint8Array[] {
	const frames: Uint8Array[] = [];
	const mf = ex.pancake_wasm_alloc(MF_SIZE);
	const prefix = ex.pancake_wasm_alloc(HOST_OUTBOUND_PREFIX_CAP);
	const prefixLen = ex.pancake_wasm_alloc(4);
	try {
		for (;;) {
			const rc = ex.pancake_host_session_take_outbound(
				session,
				mf,
				prefix,
				HOST_OUTBOUND_PREFIX_CAP,
				prefixLen,
			);
			if (rc === WOULD_BLOCK) break;
			if (rc !== OK) throw new Error(`take_outbound failed: rc=${rc}`);
			const bytesPtr = readU32(mf + MF_BYTES_OFF);
			const len = readU32(mf + MF_LEN_OFF);
			frames.push(u8().slice(prefix, prefix + readU32(prefixLen)));
			frames.push(u8().slice(bytesPtr, bytesPtr + len));
			ex.pancake_managed_frame_release(mf);
		}
		return frames;
	} finally {
		free(prefixLen, 4);
		free(prefix, HOST_OUTBOUND_PREFIX_CAP);
		free(mf, MF_SIZE);
	}
}

// Feed an inbound buffer. The library owns framing and the tail, so one call
// moves the whole buffer; an empty buffer resumes frames the session held
// behind its handshake open.
function feedBytes(session: number, buf: Uint8Array): void {
	const bufPtr = buf.length === 0 ? 0 : writeBytes(buf);
	try {
		const rc = ex.pancake_host_session_feed_bytes(session, bufPtr, buf.length);
		if (rc !== OK) throw new Error(`feed_bytes failed: rc=${rc}`);
	} finally {
		if (buf.length > 0) free(bufPtr, buf.length);
	}
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array<ArrayBuffer> {
	const out = new Uint8Array(a.length + b.length);
	out.set(a, 0);
	out.set(b, a.length);
	return out;
}

// ── The scenarios ──────────────────────────────────────────────────────────
type ScenarioResult = {
	transport: string;
	aliceOpen: boolean;
	bobOpen: boolean;
	mismatchRc: number;
	mismatchOutput: number;
	mismatchError: string;
	ok: boolean;
};

function runScenario(
	transport: string,
	designator: string,
	wrongDesignator: string,
): ScenarioResult {
	const alice = hostNew(new Uint8Array(32).fill(0x11));
	const bob = hostNew(new Uint8Array(32).fill(0x22));
	const bobSession = openAccepted(bob, transport, designator);
	const aliceSession = openDialed(alice, transport, designator);
	try {
		let aliceInbox = new Uint8Array(0);
		let bobInbox = new Uint8Array(0);
		let converged = false;
		for (let round = 0; round < 64; round++) {
			let moved = false;
			for (const frame of drainOutbound(aliceSession)) {
				bobInbox = concat(bobInbox, frame);
				moved = true;
			}
			for (const frame of drainOutbound(bobSession)) {
				aliceInbox = concat(aliceInbox, frame);
				moved = true;
			}
			if (aliceInbox.length > 0) {
				feedBytes(aliceSession, aliceInbox);
				aliceInbox = new Uint8Array(0);
				moved = true;
			}
			if (bobInbox.length > 0) {
				feedBytes(bobSession, bobInbox);
				bobInbox = new Uint8Array(0);
				moved = true;
			}
			if (sessionOpen(aliceSession) && sessionOpen(bobSession)) {
				converged = true;
				break;
			}
			if (!moved) break;
		}

		const aliceOpen = sessionOpen(aliceSession);
		const bobOpen = sessionOpen(bobSession);
		drainOutbound(aliceSession);
		const wrongSturdyref = writeStr(
			`ocapn://${encodeURIComponent(wrongDesignator)}.${transport}/s/d2lkZ2V0`,
		);
		const outVow = ex.pancake_wasm_alloc(8);
		let mismatchRc = OK;
		let mismatchOutput = 0;
		let mismatchError = "";
		try {
			mismatchRc = ex.pancake_host_session_enliven(
				aliceSession,
				wrongSturdyref.ptr,
				wrongSturdyref.len,
				outVow,
			);
			mismatchOutput = drainOutbound(aliceSession).length;
			mismatchError = lastHostError();
		} finally {
			free(wrongSturdyref.ptr, wrongSturdyref.len);
			free(outVow, 8);
		}
		return {
			transport,
			aliceOpen,
			bobOpen,
			mismatchRc,
			mismatchOutput,
			mismatchError,
			ok: converged && aliceOpen && bobOpen && mismatchRc === INVALID_ARGUMENT &&
				mismatchOutput === 0,
		};
	} finally {
		ex.pancake_host_session_release(aliceSession);
		ex.pancake_host_session_release(bobSession);
		ex.pancake_host_release(alice);
		ex.pancake_host_release(bob);
	}
}

const bobSeed = new Uint8Array(32).fill(0x22);
const aliceSeed = new Uint8Array(32).fill(0x11);
const results = [
	runScenario("tcp", "127.0.0.1:7099", "127.0.0.1:7999"),
	runScenario("noise-tcp", designatorFromSeed(bobSeed), designatorFromSeed(aliceSeed)),
];
const failed = results.find((result) => !result.ok);
if (failed) {
	console.error(
		`FAIL: wasm ${failed.transport} Host proof failed ` +
			`(alice open=${failed.aliceOpen}, bob open=${failed.bobOpen}, ` +
			`wrong-peer rc=${failed.mismatchRc}, outbound chunks=${failed.mismatchOutput}, ` +
			`error=${failed.mismatchError})`,
	);
	Deno.exit(1);
}
console.log(
	"PASS: wasm Hosts completed tcp and noise-tcp handshakes and refused wrong-peer enlivenment without output",
);
