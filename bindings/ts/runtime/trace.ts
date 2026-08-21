/** The live timeline producer: a veneer over the native tap. The core is the
 * one owner of the facts — the host reports every session's open (with the
 * partner's locator as its designator plus its transport, the OCapN Session ID
 * both peers of the session derive, what proved the partner's durable name,
 * and the codec the handshake
 * actually negotiated), every message's verb in both directions, and every
 * close. This veneer only stamps time and forwards one flat record per fact in
 * the versioned timeline schema; even endpoint labeling belongs to the
 * consumer (ocapnviz resolves src/dst from the session-opened it already saw),
 * so nothing here keeps per-session state.
 *
 * The facts arrive through the drained seam, `pancake_host_set_trace_queue`
 * plus `pancake_host_next_trace`: the host captures each one into a fixed ring
 * and this veneer pops the ring on the same unwind that drains the action
 * queue. That is the seam a browser can reach — the wasm module declares
 * exactly one import, the behavior trampoline, so the callback seam beside it
 * has no wasm form — and using the one seam everywhere means a browser peer
 * and a native one produce the same stream through the same code.
 *
 * Off by default and zero-cost when off: with no sink installed no ring is
 * allocated and the core's emit sites are one null check.
 *
 * Times are `sim_t_ns` per the schema, measured from the sink's install
 * moment. A consumer merging several producers re-stamps them against its own
 * clock, since two processes share no time origin.
 */

import { hostS } from "./internal/ffi/host.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outU64, readBytes } from "./internal/seam.ts";
import { type Context, recordCallerlessFailure } from "./context.ts";
import { PancakeError } from "./errors.ts";
import { L } from "./internal/layout.ts";
import {
	BINDING_TRACE_PAYLOAD_CAP_BYTES,
	CAPTP_NEXT,
	CAPTP_V1_0,
	CODEC_CAPNP,
	CODEC_SYRUP,
	INTERNAL,
	TRACE_DIGEST_BYTES,
	TRACE_MESSAGE,
	TRACE_SESSION_CLOSE,
	TRACE_SESSION_OPEN,
} from "@pancake/abi";
import { type DurableProvenance, provenanceFromAbi } from "./session/identity.ts";

export type TraceCodec = "syrup" | "capnp";
export type TraceCaptpVersion = "1.0" | "pancake-next";

/** One wire event in the versioned timeline schema. */
export type TraceEvent = {
	v: 1;
	sim_t_ns: number;
	kind:
		| "ocapn.session-opened"
		| "ocapn.message-decoded"
		| "ocapn.session-closed"
		| "ocapn.session-meta";
	/** This producer's own handle for the session. Scoped to the producer
	 * and meaningless outside it — the name two producers agree on is
	 * `session_id` below, which OCapN derives from both ends' keys. */
	session: string;
	/** `ocapn.session-opened`: the reporting host's own OCapN Designator. */
	a?: string;
	/** `ocapn.session-opened`: the partner's OCapN Designator. Half a name
	 * on its own — OCapN needs a designator and a transport together to
	 * tell two locations apart, so `transport` travels with it. */
	b?: string;
	/** `ocapn.session-opened`: the locator's OCapN Transport, the netlayer
	 * symbol this session runs over. */
	transport?: string;
	/** `ocapn.session-opened`: what the reporting host would like itself
	 * called on screen. Display only — `a` stays the identity a consumer
	 * merges on, and this text does not reach that decision. */
	a_label?: string;
	/** `ocapn.session-opened`: the implementation this producer runs, always
	 * `"pancake"` here. A statement about the producer, beside the designator
	 * it calls itself by and the label it would like to be shown under, and on
	 * the same footing as the `provenance` verdict beside it: a conclusion the
	 * producer states, not a raw wire fact.
	 *
	 * It is stated because this schema is not pancake's alone — the Goblins
	 * conformance peer publishes the same records — so a consumer cannot read
	 * an implementation off the fact that a record arrived, and a host that
	 * says nothing is honestly unknown to it. */
	a_profile?: string;
	/** `ocapn.session-opened`: the OCapN session identifier, 64 lowercase hex
	 * digits — the spec's own Session ID, derived from both ends' Public
	 * Identifiers. Both peers of one session derive the same value, so a consumer
	 * merging feeds from several producers can tell that two producers are
	 * watching one session rather than two unrelated ones. Absent when the
	 * partner sent no session key. */
	session_id?: string;
	/** `ocapn.session-opened`: the negotiated wire grammar. Built-in codecs
	 * use the model's own names. An ABI generation that cannot name the value
	 * reports an internal projection failure instead of inventing a codec. The signed hello carries the codec
	 * preference as a locator hint (ADR-0103). */
	codec?: TraceCodec;
	/** `ocapn.session-opened`: the negotiated CapTP profile, spelled the way
	 * the handshake spells it. A trace reports on the wire, so it uses the wire's own word
	 * rather than the enum tag the implementation happens to hold it under.
	 * Reported beside the codec because the two are one decision (ADR-0003). */
	captp_version?: TraceCaptpVersion;
	/** `ocapn.session-opened`: whether the realized channel proved the
	 * partner's durable name: `"authenticated-transport"` or
	 * `"unauthenticated"`. */
	provenance?: DurableProvenance;
	outbound?: boolean;
	op?: string;
	/** `ocapn.message-decoded`: the wire frame's byte length. Both
	 * directions carry the frame — the core's fact sites sit at the
	 * wire boundary. */
	len?: number;
	/** The whole frame, base64, when it fits the payload cap. */
	bytes_b64?: string;
	/** The frame's head when it outgrew the cap: `len` is the true
	 * length, `head_b64` the first cap bytes. */
	summary?: { len: number; head_b64: string };
	/** `ocapn.message-decoded`: a tag over the frame's bytes, lowercase hex,
	 * naming this one message across the two peers that carried it. One frame
	 * crosses one wire, so both ends derive the same tag from the bytes they
	 * hold, with no coordination. A consumer watching a session from both
	 * ends folds their two sightings into one message on this; without it,
	 * every message of a doubly-observed conversation would draw twice. */
	digest?: string;
	/** Facts the host's ring could not hold between the previous record and
	 * this one. Absent when none were lost, which is the ordinary case. */
	dropped?: number;
	/** `ocapn.session-meta`: an application annotation about the
	 * session — a CLAIM by the producing application, never protocol
	 * identity. `label` names the session's partner in the
	 * application's own vocabulary (a chat nick); `null` WITHDRAWS the
	 * claim, which is what an application says when it stops knowing the
	 * connection by that name. */
	meta?: { label?: string | null };
};

/** What a trace record calls each CapTP profile: the handshake's own words,
 * mirroring `model.CaptpVersion.wireString`. A consumer that compares a record
 * against a profile reads them from here rather than re-typing them, so the
 * spelling has one owner on this side of the ABI.
 *
 * The viewer keeps a second table (`CAPTP_VERSION_WIRE` in
 * `apps/ocapnviz/src/schema/topology.ts`) and that is deliberate: it reads a
 * schema several implementations publish, it is a separate Deno scope that
 * links no pancake package, and its copy doubles as the text a person reads on
 * screen. Neither table may drift from the Zig authority or from the other, so
 * `zig build source-check` holds both: `checkTraceVocabulary` for the producers
 * and `checkTraceViewerVocabulary` for the viewer. */
export const CAPTP_VERSION_WIRE = {
	v1_0: "1.0",
	next: "pancake-next",
} as const;

/** What this producer answers when a record asks what it runs. A constant and
 * not an option: the host behind this binding is a pancake host, and letting
 * an application name itself something else would put a claim on the wire that
 * nothing here could stand behind.
 *
 * Each of the four bindings states this word itself, because it is a claim
 * about the binding tier rather than a fact the core or the C ABI carries, so
 * there is no declaration to generate it from. `zig build source-check`
 * (`checkTraceViewerVocabulary`) holds all four against each other, against the
 * viewer that reads them, and against the Goblins conformance publisher, which
 * states a different word and must keep stating it. */
const SELF_PROFILE = "pancake";

export type TraceSink = (ev: TraceEvent) => void;

let sink: TraceSink | null = null;
/** The display label the application chose for its own endpoint, or null. */
let selfLabel: string | null = null;
let t0 = 0;
/** Payload bytes forwarded per message; 0 disables payload capture. */
let payloadCap = BINDING_TRACE_PAYLOAD_CAP_BYTES;
/** How many facts a host's ring holds before it starts dropping. One drain
 * runs on every action-queue unwind, so this only has to cover one pump's
 * worth of traffic. */
let queueDepth = 512;

/** Every live Host, keyed by its raw pointer. `cookie` is the small integer a
 * session id is scoped by: a core session id is host-scoped (the Names rule:
 * a bare id needs its namespace named), so two hosts in one process would
 * otherwise collide on the same `live-s1`. `designator` is the host's own key
 * designator, which is what a partner names it by, so one peer's node in a
 * merged feed is the same node whichever producer reported it. */
type TracedHost = { cookie: number; designator: string; context: Context; diagnosticId: bigint };
const hosts = new Map<Ptr, TracedHost>();
let nextHostCookie = 1;

const utf8 = new TextDecoder();

function retainSinkFailure(host: TracedHost, error: unknown): void {
	recordCallerlessFailure(host.context, {
		layer: "application-observer",
		scope: "host",
		scopeId: host.diagnosticId,
		operation: "trace.sink",
		primaryName: error instanceof Error ? error.name : "ThrownValue",
		primaryResult: INTERNAL,
		primaryMessage: error instanceof Error ? error.message : String(error),
	});
}

function retainDecodeFailure(host: TracedHost, error: unknown): void {
	recordCallerlessFailure(host.context, {
		layer: "binding",
		scope: "host",
		scopeId: host.diagnosticId,
		operation: "trace.decode",
		primaryName: error instanceof Error ? error.name : "ThrownValue",
		primaryResult: INTERNAL,
		primaryMessage: error instanceof Error ? error.message : String(error),
	});
}

function now_ns(): number {
	return Math.round((performance.now() - t0) * 1_000_000);
}

function codecFromAbi(codec: number): TraceCodec {
	if (codec === CODEC_CAPNP) return "capnp";
	if (codec === CODEC_SYRUP) return "syrup";
	throw new PancakeError(INTERNAL, `pancake ABI returned unknown trace codec ${codec}`);
}

function captpVersionFromAbi(version: number): TraceCaptpVersion {
	if (version === CAPTP_NEXT) return CAPTP_VERSION_WIRE.next;
	if (version === CAPTP_V1_0) return CAPTP_VERSION_WIRE.v1_0;
	throw new PancakeError(INTERNAL, `pancake ABI returned unknown trace CapTP version ${version}`);
}

/** Base64 of a small buffer (bounded by the payload cap), chunked so
 * `String.fromCharCode` never sees an argument list past the engine's
 * apply limit. */
function base64(bytes: Uint8Array): string {
	let binary = "";
	for (let i = 0; i < bytes.length; i += 0x1000) {
		binary += String.fromCharCode(...bytes.subarray(i, i + 0x1000));
	}
	return btoa(binary);
}

/** The message tag as lowercase hex. It sits inline in the record rather than
 * behind a pointer, so it is read straight off the scratch bytes. */
function hex(out: Uint8Array, off: number, len: number): string {
	let s = "";
	for (let i = off; i < off + len; i++) s += out[i].toString(16).padStart(2, "0");
	return s;
}

function view(dv: DataView, ptrOff: number, lenOff: number): string | undefined {
	const ptr = L.getPtr(dv, ptrOff);
	const len = L.getUsize(dv, lenOff);
	if (len === 0n || ptr === NULL) return undefined;
	return utf8.decode(readBytes(ptr, len));
}

/** Turn one popped `PancakeTraceEvent` into its schema record. */
function decode(host: TracedHost, out: Uint8Array): TraceEvent {
	const dv = new DataView(out.buffer, out.byteOffset, out.byteLength);
	const kind = dv.getUint32(L.TRACE_EVENT_KIND_OFF, true);
	const session = `live-h${host.cookie}-s${dv.getBigUint64(L.TRACE_EVENT_SESSION_OFF, true)}`;
	const dropped = Number(dv.getBigUint64(L.TRACE_EVENT_DROPPED_OFF, true));
	const gap = dropped > 0 ? { dropped } : {};
	if (kind === TRACE_SESSION_OPEN) {
		return {
			v: 1,
			sim_t_ns: now_ns(),
			kind: "ocapn.session-opened",
			session,
			a: host.designator,
			a_profile: SELF_PROFILE,
			...(selfLabel === null ? {} : { a_label: selfLabel }),
			b: view(dv, L.TRACE_EVENT_DESIGNATOR_OFF, L.TRACE_EVENT_DESIGNATOR_LEN_OFF) ?? "peer",
			transport: view(dv, L.TRACE_EVENT_TRANSPORT_OFF, L.TRACE_EVENT_TRANSPORT_LEN_OFF),
			session_id: view(dv, L.TRACE_EVENT_SESSION_ID_OFF, L.TRACE_EVENT_SESSION_ID_LEN_OFF),
			codec: codecFromAbi(dv.getUint32(L.TRACE_EVENT_CODEC_OFF, true)),
			captp_version: captpVersionFromAbi(
				dv.getUint32(L.TRACE_EVENT_CAPTP_VERSION_OFF, true),
			),
			provenance: provenanceFromAbi(dv.getUint32(L.TRACE_EVENT_PROVENANCE_OFF, true)),
			...gap,
		};
	}
	if (kind === TRACE_MESSAGE) {
		const ev: TraceEvent = {
			v: 1,
			sim_t_ns: now_ns(),
			kind: "ocapn.message-decoded",
			session,
			outbound: dv.getUint8(L.TRACE_EVENT_OUTBOUND_OFF) !== 0,
			op: view(dv, L.TRACE_EVENT_VERB_OFF, L.TRACE_EVENT_VERB_LEN_OFF),
			digest: hex(out, L.TRACE_EVENT_DIGEST_OFF, TRACE_DIGEST_BYTES),
			...gap,
		};
		// The frame is borrowed until the next pop, so the payload copy happens
		// here or never. The host's ring already clipped it to the queue's
		// payload window; `frame_total_len` is how long it really was, so a
		// clipped frame reports its true length beside the head it kept.
		const framePtr = L.getPtr(dv, L.TRACE_EVENT_FRAME_OFF);
		const captured = Number(L.getUsize(dv, L.TRACE_EVENT_FRAME_LEN_OFF));
		const total = Number(L.getUsize(dv, L.TRACE_EVENT_FRAME_TOTAL_LEN_OFF));
		if (payloadCap > 0 && total > 0 && framePtr !== NULL && captured > 0) {
			ev.len = total;
			const head = readBytes(framePtr, BigInt(Math.min(captured, payloadCap)));
			if (total <= payloadCap && captured >= total) {
				ev.bytes_b64 = base64(head);
			} else {
				ev.summary = { len: total, head_b64: base64(head) };
			}
		} else if (total > 0) {
			ev.len = total;
		}
		return ev;
	}
	if (kind === TRACE_SESSION_CLOSE) {
		return { v: 1, sim_t_ns: now_ns(), kind: "ocapn.session-closed", session, ...gap };
	}
	throw new PancakeError(INTERNAL, `pancake ABI returned unknown trace event kind ${kind}`);
}

/** Scratch for one pop; the pop overwrites it and the string views it names
 * die at the next pop, so it is reused rather than reallocated per record.
 * Sized from the ACTIVE layout, which is four-byte-pointer on wasm32 and
 * eight elsewhere, and taken on first use because the browser adapter chooses
 * that layout as it loads. */
let popScratch: Uint8Array | null = null;
// A sink may call back into Host.close(), which drains this same ring. Keep
// one active drainer per Host and let the outer call finish or observe detach.
const drainingHosts = new Set<Ptr>();

/** Drain one host's captured facts to the sink. Called on the same unwind
 * that drains the action queue (`Host.kickActions`) and before any record
 * this veneer emits itself, so causal order survives the queueing.
 * Binding-internal. */
export function traceDrainHost(raw: Ptr): void {
	if (sink == null || !hosts.has(raw) || drainingHosts.has(raw)) return;
	drainingHosts.add(raw);
	if (popScratch === null) popScratch = new Uint8Array(L.TRACE_EVENT_SIZE);
	const out = popScratch;
	try {
		while (hosts.has(raw)) {
			const currentSink = sink;
			if (currentSink == null) return;
			if (hostS.pancake_host_next_trace(raw, ab(out)) !== 0) return;
			const host = hosts.get(raw);
			if (host == null) return;
			let ev: TraceEvent;
			try {
				ev = decode(host, out);
			} catch (error) {
				retainDecodeFailure(host, error);
				continue;
			}
			try {
				currentSink(ev);
			} catch (error) {
				retainSinkFailure(host, error);
			}
		}
	} finally {
		drainingHosts.delete(raw);
	}
}

/** Install the sink (replacing any prior one), start the clock, and install
 * the capture ring on every live Host (a Host minted later installs its own).
 * Returns an uninstall that also clears the rings.
 *
 * `payloadCap` bounds the message-frame bytes forwarded per event
 * (base64; whole frame under the cap, head + true length above it);
 * 0 turns payload capture off. `selfLabel`, when given, is what the producing
 * application would like its own endpoint CALLED — a display name beside the
 * identity, never instead of it: the `a` endpoint stays the host's own key
 * designator, which is what a partner names it by and so the only name two
 * producers can agree on. */
export function enableTrace(
	next: TraceSink,
	options?: { selfLabel?: string; payloadCap?: number; queueDepth?: number },
): () => void {
	sink = next;
	selfLabel = options?.selfLabel ?? null;
	payloadCap = options?.payloadCap ?? BINDING_TRACE_PAYLOAD_CAP_BYTES;
	queueDepth = options?.queueDepth ?? 512;
	t0 = performance.now();
	for (const raw of hosts.keys()) installQueue(raw);
	return () => {
		if (sink !== next) return;
		for (const raw of hosts.keys()) {
			traceDrainHost(raw);
			hostS.pancake_host_set_trace_queue(raw, 0n, 0n);
		}
		sink = null;
	};
}

/** The per-record payload window: the message cap plus room for the strings
 * an open carries (a designator and the 64-digit wire name), so enabling
 * payload capture does not squeeze out the identity a consumer keys on. */
function windowBytes(): number {
	return payloadCap + 512;
}

function installQueue(raw: Ptr): void {
	hostS.pancake_host_set_trace_queue(raw, BigInt(queueDepth), BigInt(windowBytes()));
}

/** Annotate a session with application metadata — the SET half of the
 * three-layer annotation design (set where meaning lives, pass through
 * dumb, use at the edge): the application that knows what a session
 * MEANS (a chat server that knows which member it carries) states it
 * here, and the record rides the same stream as the protocol facts,
 * named for the same session row the tap names. An annotation is a
 * claim, never identity — a consumer may display it, and must not let
 * it merge or split peers. No sink installed, or a host the trace
 * never attached: silently nothing, like every other trace emit. */
export function annotateSession(
	session: { readonly raw: Ptr; readonly host: { readonly raw: Ptr } },
	meta: { label?: string | null },
): void {
	if (sink == null) return;
	const hostRaw = session.host.raw;
	const host = hosts.get(hostRaw);
	if (host === undefined) return;
	const out = new Uint8Array(8);
	const code = hostS.pancake_host_session_trace_id(session.raw, ab(out));
	if (code !== 0) return;
	// The session's own open may still be sitting in the capture ring; drain
	// first so an annotation never reaches a consumer ahead of the session it
	// names.
	traceDrainHost(hostRaw);
	const currentSink = sink;
	if (currentSink == null || hosts.get(hostRaw) !== host) return;
	const event: TraceEvent = {
		v: 1,
		sim_t_ns: now_ns(),
		kind: "ocapn.session-meta",
		session: `live-h${host.cookie}-s${outU64(out)}`,
		meta,
	};
	try {
		currentSink(event);
	} catch (error) {
		retainSinkFailure(host, error);
	}
}

/** Binding-internal: a Host reports its raw pointer and its own key
 * designator at construction so an installed trace covers it, and a trace
 * installed later finds it. */
export function traceAttachHost(raw: Ptr, designator: string, context: Context, diagnosticId: bigint): void {
	hosts.set(raw, { cookie: nextHostCookie++, designator, context, diagnosticId });
	if (sink !== null) installQueue(raw);
}

/** Binding-internal: a released Host leaves the registry. The core dropped
 * its own ring with the host, so no native call is needed. */
export function traceDetachHost(raw: Ptr): void {
	hosts.delete(raw);
}
