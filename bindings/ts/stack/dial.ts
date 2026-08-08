// The dial executor (binding spine Pass 3c): one path that turns a parsed
// locator into an open, handshaken `Session`, shared by `connect` and
// handoff-redeem alike.
//
// Every dial decision — the host:port grammar, the direct-addresses hint rule,
// the peer-id reachability posture, the scheme dispatch, and the typed errors —
// is resolved once in the core by `pancake_host_plan_dial`, which hands back a
// `PancakeDialPlan`. This module holds no dial business logic: it marshals the
// posture, reads the plan into a language sum, and performs the one thing the
// core cannot — the async byte-channel open (`net.connect`, or the iroh
// companion). Adding a transport is a core change, not an edit here. Session
// owns mint/handshake (`establishDialedLocator` / `establishAccepted`); this
// module owns plan + channel open + the public `connect` dialer.

import { HANDSHAKE_TIMEOUT_MS, Session } from "./session.ts";
import { Host } from "./host.ts";
import { driverS } from "./internal/ffi/host.ts";
import { ensureRuntimeReady, ffi, net } from "./internal/ffi/runtime.ts";
import { ab, readBytes } from "./internal/seam.ts";
import { openWebSocketChannel } from "./ws_channel.ts";
import { checkHost, PancakeError } from "./errors.ts";
import { type Codec, Reachability } from "./value.ts";
import { HINT_DIRECT_ADDRESSES, parseLocator, TRANSPORT_TCP } from "./locator.ts";
import { L } from "./internal/layout.ts";
import {
	DIAL_POSTURE_EXPLICIT,
	DIAL_POSTURE_EXPLICIT_NONE,
	DIAL_POSTURE_REDEEM,
	DIAL_REACH_CONFIGURED,
	DIAL_REACH_DIRECT,
	DIAL_SHAPE_HOST_PORT,
	DIAL_SHAPE_PEER_ID,
	DIAL_SHAPE_RENDEZVOUS,
	DIAL_SHAPE_SIGNALING,
	INVALID_ARGUMENT,
} from "@pancake/abi";

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

/** The parsed locator plus the caller's context, everything the core needs to
 * resolve a dial. `connect` and handoff-redeem both fill it. */
export interface DialRequest {
	/** The locator's parsed transport scheme (tcp, keyed-tcp, iroh, ...). */
	readonly transport: string;
	/** The locator's designator (a tcp host:port, an iroh node id, ...). */
	readonly designator: string;
	/** The locator's `direct-addresses` hint, empty when absent. */
	readonly directAddresses: string;
	/** True when this dial redeems a three-party handoff give. */
	readonly redeem: boolean;
	/** The caller's iroh reachability posture on a `connect` (undefined on redeem). */
	readonly reachability?: Reachability;
	/** The host's configured redeem reachability, used for a hint-less redeem. */
	readonly redeemReachability: Reachability;
	/** How long the OCapN handshake may take once the byte channel is open;
	 * `0` or `null` waits unbounded. */
	readonly handshakeTimeoutMs: number | null;
}

/** A resolved dial from `pancake_host_plan_dial`: language sum over the C
 * shape flag (mirrors Zig `DialPlan`). */
type DialPlan =
	| { readonly tag: "host_port"; readonly hostname: string; readonly port: number }
	| {
		readonly tag: "peer_id";
		readonly addresses: string;
		readonly reachKind: number;
		readonly reachValue: number;
	}
	| { readonly tag: "signaling" }
	| { readonly tag: "rendezvous" };

/** Decode a plan view that aliases one of the UTF-8 input buffers (one OS
 * connect string decode). A non-alias view is a core contract break. */
function decodePlanView(sources: Uint8Array[], ptr: bigint, len: bigint): string {
	if (len === 0n) return "";
	const n = Number(len);
	for (const src of sources) {
		const base = ffi.pointerOf(src);
		if (ptr >= base && ptr + len <= base + BigInt(src.length)) {
			const off = Number(ptr - base);
			return utf8Decoder.decode(src.subarray(off, off + n));
		}
	}
	throw new PancakeError(INVALID_ARGUMENT, "dial plan view does not alias input buffers");
}

/** Resolve a dial in the core: the grammar, the hint rule, the posture, and the
 * error cases all decided by `pancake_host_plan_dial`. Plan views alias the
 * input UTF-8 buffers; decode those subslices only. */
function planDial(
	transport: string,
	designator: string,
	directAddresses: string,
	posturePolicy: number,
	postureValue: number,
): DialPlan {
	const t = utf8Encoder.encode(transport);
	const d = utf8Encoder.encode(designator);
	const h = utf8Encoder.encode(directAddresses);
	const out = new Uint8Array(L.DIAL_PLAN_SIZE);
	checkHost(driverS.pancake_host_plan_dial(
		ab(t),
		BigInt(t.length),
		ab(d),
		BigInt(d.length),
		ab(h),
		BigInt(h.length),
		posturePolicy,
		postureValue,
		ab(out),
	));
	const dv = new DataView(out.buffer);
	const sources = [d, h];
	const str = (off: number, lenOff: number): string =>
		decodePlanView(
			sources,
			L.getPtr(dv, off),
			L.getUsize(dv, lenOff),
		);
	const shape = dv.getUint32(L.DIAL_PLAN_SHAPE_OFF, true);
	if (shape === DIAL_SHAPE_PEER_ID) {
		return {
			tag: "peer_id",
			addresses: str(L.DIAL_PLAN_ADDRESSES_OFF, L.DIAL_PLAN_ADDRESSES_LEN_OFF),
			reachKind: dv.getUint32(L.DIAL_PLAN_REACH_KIND_OFF, true),
			reachValue: dv.getUint32(L.DIAL_PLAN_REACH_VALUE_OFF, true),
		};
	}
	if (shape === DIAL_SHAPE_HOST_PORT) {
		return {
			tag: "host_port",
			hostname: str(L.DIAL_PLAN_HOST_OFF, L.DIAL_PLAN_HOST_LEN_OFF),
			port: dv.getUint16(L.DIAL_PLAN_PORT_OFF, true),
		};
	}
	if (shape === DIAL_SHAPE_SIGNALING) {
		return { tag: "signaling" };
	}
	if (shape === DIAL_SHAPE_RENDEZVOUS) {
		return { tag: "rendezvous" };
	}
	throw new PancakeError(INVALID_ARGUMENT, `unknown dial shape ${shape}`);
}

/** How a relay opens the byte channel for a target locator: a raw TCP socket to
 * `hostname:port`, or the iroh companion dialed with the original locator. */
export type RelayTarget =
	| { readonly kind: "tcp"; readonly hostname: string; readonly port: number }
	| { readonly kind: "iroh"; readonly locator: string };

/** Sort a relay target locator into the channel to open, routing the decision
 * through the core `pancake_host_plan_dial` so every runtime's relay classifies
 * a locator identically (ADR-0086). The locator is a full `ocapn://` URI, or the
 * bare `host:port` tcp shorthand; either way the core decides the shape, so a
 * `tcp`-scheme URI sorts to TCP and an `iroh` one to the peer-id dial — the
 * relay never enumerates transports. Throws `PancakeError` for a malformed
 * locator. */
export function classifyRelayTarget(locator: string): RelayTarget {
	const parts = locator.includes("://")
		? (() => {
			const loc = parseLocator(locator);
			return {
				transport: loc.transport,
				designator: loc.designator,
				hint: loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "",
			};
		})()
		: { transport: TRANSPORT_TCP, designator: locator, hint: "" };
	const plan = planDial(
		parts.transport,
		parts.designator,
		parts.hint,
		DIAL_POSTURE_EXPLICIT,
		Reachability.Direct,
	);
	if (plan.tag === "signaling" || plan.tag === "rendezvous") {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`a relay cannot dial a ${parts.transport} locator: no socket opens it`,
		);
	}
	return plan.tag === "host_port"
		? { kind: "tcp", hostname: plan.hostname, port: plan.port }
		: { kind: "iroh", locator };
}

/** The core resolved which posture to dial a peer-id open under; substitute the
 * host's configured value for the CONFIGURED marker (the core is postureless). */
function reachOf(
	plan: Extract<DialPlan, { tag: "peer_id" }>,
	configured: Reachability,
): Reachability {
	switch (plan.reachKind) {
		case DIAL_REACH_DIRECT:
			return Reachability.Direct;
		case DIAL_REACH_CONFIGURED:
			return configured;
		default:
			return plan.reachValue as Reachability;
	}
}

/** The one dial path. Resolve the plan in the core, then open the byte channel
 * it names and drive the keyed handshake to a ready `Session`. Every dial
 * through here carries `req.handshakeTimeoutMs`: a peer that accepts the
 * connection and never finishes the OCapN handshake costs one dial, not the
 * caller. */
export async function dialResolved(host: Host, req: DialRequest): Promise<Session> {
	const [policy, value] = req.redeem
		? [DIAL_POSTURE_REDEEM, 0]
		: req.reachability != null
		? [DIAL_POSTURE_EXPLICIT, req.reachability]
		: [DIAL_POSTURE_EXPLICIT_NONE, 0];
	const plan = planDial(req.transport, req.designator, req.directAddresses, policy, value);
	switch (plan.tag) {
		case "peer_id": {
			const iroh = await import("@pancake/iroh/internal");
			return iroh._connectIroh(
				req.designator,
				plan.addresses,
				reachOf(plan, req.redeemReachability),
				host,
				req.handshakeTimeoutMs,
			);
		}
		case "host_port": {
			const tcp = await net.connect(plan.hostname, plan.port);
			try {
				return await Session.establishDialedLocator(
					host,
					req.transport,
					req.designator,
					tcp,
					req.handshakeTimeoutMs,
				);
			} catch (err) {
				tcp.close();
				throw err;
			}
		}
		case "rendezvous": {
			// `keyed-relay` names a peer by key alone with no dialable address:
			// its byte path is a relay's rendezvous bridge (ADR-0088). The relay
			// mapping is deployment configuration, exactly like the redeem
			// reachability posture beside it on `Host`; without one the dial
			// refuses loud.
			const rendezvousUrl = host.rendezvousUrl;
			if (rendezvousUrl === null) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"keyed-relay dial: no rendezvous relay configured; call Host.setRendezvousUrl first",
				);
			}
			const channel = await openWebSocketChannel(rendezvousUrl(req.designator));
			try {
				return await Session.establishDialedLocator(
					host,
					req.transport,
					req.designator,
					channel,
					req.handshakeTimeoutMs,
				);
			} catch (err) {
				channel.close();
				throw err;
			}
		}
		case "signaling": {
			// A `webrtc` locator names a designator and no route: the channel is
			// opened by an offer, answer, and candidate exchange, not a socket
			// (ADR-0089). The authority that carries the exchange is deployment
			// configuration of the dialing host, exactly like the rendezvous
			// mapping above; without one the dial refuses loud.
			const signaling = host.signaling;
			if (signaling === null) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"webrtc dial: no signaling authority configured; call Host.setSignaling first",
				);
			}
			const { RtcPeer } = await import("@pancake/webrtc");
			const peer = new RtcPeer({ offerer: true });
			// The far peer's candidates can trickle from the moment it holds our
			// offer, so the sink is registered before the offer is sent.
			const stopCandidates = signaling.onCandidate(req.designator, (ice) => {
				peer.addRemoteCandidate(JSON.parse(ice)).catch(() => {
					// A late or duplicate candidate is harmless.
				});
			});
			try {
				peer.onLocalCandidate((candidate) =>
					void signaling.candidate(req.designator, JSON.stringify(candidate))
				);
				const answer = await signaling.offer(req.designator, await peer.createOffer());
				await peer.setRemoteAnswer(answer);
				await peer.waitOpen();
				return await Session.establishDialedLocator(
					host,
					req.transport,
					req.designator,
					peer.channel(),
					req.handshakeTimeoutMs,
				);
			} catch (err) {
				peer.close();
				throw err;
			} finally {
				stopCandidates();
			}
		}
	}
}

/** The dial entry for `connect` and handoff redeem alike: no dispatch, no
 * grammar, no posture — the core resolves all of that in `dialResolved`. */
export async function dialParsedLocator(
	transport: string,
	designator: string,
	directAddressesHint: string,
	host: Host | undefined,
	opts: {
		reachability?: Reachability;
		redeem?: boolean;
		codec?: Codec;
		handshakeTimeoutMs?: number | null;
	} = {},
): Promise<Session> {
	const redeem = opts.redeem ?? false;
	let dialHost: Host;
	let ownsHost = false;
	if (redeem) {
		if (host == null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"handoff redeem requires a shared host",
			);
		}
		dialHost = host;
	} else {
		dialHost = host ?? new Host(undefined, { codec: opts.codec });
		ownsHost = host == null;
	}
	const session = await dialResolved(dialHost, {
		transport,
		designator,
		directAddresses: directAddressesHint,
		redeem,
		reachability: opts.reachability,
		redeemReachability: dialHost.redeemReachability,
		handshakeTimeoutMs: opts.handshakeTimeoutMs === undefined
			? HANDSHAKE_TIMEOUT_MS
			: opts.handshakeTimeoutMs,
	});
	session.ownsHost = ownsHost;
	return session;
}

/** Dial an exporter a DIAL action names, keyed with `host`'s retained
 * identity, and bind the result to that same host so the redeemed
 * capability and any further handoff it triggers share one identity and
 * connection table. An exporter that never finishes the handshake breaks the
 * redeem on `HANDSHAKE_TIMEOUT_MS` rather than stalling the drain.
 * Binding-internal: the host's action drain calls this. */
export async function dialExporter(
	transport: string,
	designator: string,
	directAddressesHint: string,
	host: Host,
): Promise<Session> {
	return await dialParsedLocator(
		transport,
		designator,
		directAddressesHint,
		host,
		{ redeem: true },
	);
}

/** Ticket-only DIAL arm: borrow parsed parts (no URI re-parse), dial, report.
 * Binding-internal: the action drain calls this. */
export async function runDialTicket(host: Host, ticket: bigint): Promise<void> {
	const out = new Uint8Array(L.PENDING_DIAL_SIZE);
	try {
		checkHost(driverS.pancake_host_pending_dial(host.raw, ticket, ab(out)));
		const dv = new DataView(out.buffer);
		const str = (off: number, lenOff: number): string => {
			const len = L.getUsize(dv, lenOff);
			return len === 0n ? "" : utf8Decoder.decode(readBytes(L.getPtr(dv, off), len));
		};
		const transport = str(L.PENDING_DIAL_TRANSPORT_OFF, L.PENDING_DIAL_TRANSPORT_LEN_OFF);
		const designator = str(L.PENDING_DIAL_DESIGNATOR_OFF, L.PENDING_DIAL_DESIGNATOR_LEN_OFF);
		const hint = str(L.PENDING_DIAL_HINT_OFF, L.PENDING_DIAL_HINT_LEN_OFF);
		const session = await dialExporter(transport, designator, hint, host);
		// The session self-registers in the host's session table (its constructor),
		// so `Session.sendRedeeming` resolves it deterministically from the reply's
		// route via `Host.exporterFor` (ADR-0088) — no capture window to feed here.
		session.serve().catch(() => {});
		checkHost(driverS.pancake_host_dialed(host.raw, ticket, session.raw));
	} catch (err) {
		const reason = utf8Encoder.encode(
			err instanceof Error ? err.message : String(err),
		);
		checkHost(driverS.pancake_host_dial_failed(
			host.raw,
			ticket,
			ab(reason),
			BigInt(reason.length),
		));
	}
}

/** Dial a partner from its `ocapn://` locator — the one public dialer.
 *
 * `handshakeTimeoutMs` bounds the OCapN handshake once the byte channel is
 * open, at `HANDSHAKE_TIMEOUT_MS` by default. A peer that accepts the
 * connection and then says nothing rejects with `PancakeError` carrying
 * `TIMEOUT` instead of parking the caller; pass `0` or `null` to wait without a
 * bound. It does not cover opening the channel itself: a TCP connect keeps the
 * runtime's own timeout, and an iroh dial-by-id keeps its discovery retry
 * budget (ADR-0082) before the handshake starts. */
export async function connect(
	uri: string,
	reachability?: Reachability,
	host?: Host,
	codec?: Codec,
	handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
): Promise<Session> {
	await ensureRuntimeReady();
	const loc = parseLocator(uri);
	if (host != null && codec != null && codec != host.codec) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`codec "${codec}" conflicts with the shared host's "${host.codec}"`,
		);
	}
	const directHint = loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "";
	return await dialParsedLocator(
		loc.transport,
		loc.designator,
		directHint,
		host,
		{ reachability, codec, handshakeTimeoutMs },
	);
}
