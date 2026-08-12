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
import { DriverLoop, loopTierAvailable } from "./driver_loop.ts";
import { installProvider as installTcpProvider } from "./transport/tcp.ts";
import { hostS } from "./internal/ffi/host.ts";
import { ensureRuntimeReady, ffi, net } from "./internal/ffi/runtime.ts";
import { ab } from "./internal/seam.ts";
import { openWebSocketChannel } from "./ws_channel.ts";
import { checkHost, PancakeError } from "./errors.ts";
import { type Codec, Reachability } from "./value.ts";
import {
	HINT_DIRECT_ADDRESSES,
	type Locator,
	OwnedLocator,
	parseLocator,
	stringHint,
	TRANSPORT_TCP,
} from "./locator.ts";
import { L } from "./internal/layout.ts";
import { SignalingSendOwner } from "./signaling.ts";
import {
	BUFFER_TOO_SMALL,
	CLOSED,
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

function dialCancelled(): PancakeError {
	return new PancakeError(CLOSED, "host released while dialing");
}

function abortError(signal: AbortSignal): unknown {
	const reason = signal.reason;
	return reason instanceof Error && reason.name !== "AbortError" ? reason : dialCancelled();
}

function throwIfCancelled(signal?: AbortSignal): void {
	if (signal?.aborted) throw dialCancelled();
}

/** Reject promptly on cancellation while still taking responsibility for a
 * resource an uncancellable host promise may produce later. */
async function abortable<T>(
	pending: Promise<T>,
	signal?: AbortSignal,
	onLateValue?: (value: T) => void,
): Promise<T> {
	if (signal == null) return await pending;
	if (signal.aborted) {
		void pending.then((value) => onLateValue?.(value), () => {});
		throw abortError(signal);
	}
	return await new Promise<T>((resolve, reject) => {
		let settled = false;
		const onAbort = (): void => {
			if (settled) return;
			settled = true;
			reject(abortError(signal));
		};
		signal.addEventListener("abort", onAbort, { once: true });
		void pending.then(
			(value) => {
				if (settled) {
					onLateValue?.(value);
					return;
				}
				settled = true;
				signal.removeEventListener("abort", onAbort);
				resolve(value);
			},
			(error) => {
				if (settled) return;
				settled = true;
				signal.removeEventListener("abort", onAbort);
				reject(error);
			},
		);
	});
}

/** Deliver a remote ICE candidate without allowing a late/invalid candidate to
 * escape the signaling callback or resurrect a closed peer. */
export function acceptRemoteCandidate(
	peer: { addRemoteCandidate(candidate: RTCIceCandidateInit): Promise<void> },
	ice: string,
): void {
	try {
		void Promise.resolve(peer.addRemoteCandidate(JSON.parse(ice))).catch(() => {});
	} catch {
		// A candidate arriving after cleanup, or malformed signaling data, is harmless.
	}
}

/** The parsed locator plus the caller's context, everything the core needs to
 * resolve a dial. `connect` and handoff-redeem both fill it. */
export interface DialRequest {
	/** The complete typed locator retained by the caller or pending Host row. */
	readonly locator: Locator;
	/** True when this dial redeems a three-party handoff give. */
	readonly redeem: boolean;
	/** The caller's iroh reachability posture on a `connect` (undefined on redeem). */
	readonly reachability?: Reachability;
	/** The host's configured redeem reachability, used for a hint-less redeem. */
	readonly redeemReachability: Reachability;
	/** How long the OCapN handshake may take once the byte channel is open;
	 * `0` or `null` waits unbounded. */
	readonly handshakeTimeoutMs: number | null;
	/** Present only for a detached Host DIAL action. */
	readonly signal?: AbortSignal;
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
 * input UTF-8 buffers; decode those subslices only. Exported for the loop
 * route (`driver_loop.ts`), which classifies the same way before admission. */
export function planDial(
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
	checkHost(hostS.pancake_host_plan_dial(
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
				hint: stringHint(loc, HINT_DIRECT_ADDRESSES) ?? "",
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
	throwIfCancelled(req.signal);
	const { locator } = req;
	const directAddresses = stringHint(locator, HINT_DIRECT_ADDRESSES) ?? "";
	const [policy, value] = req.redeem
		? [DIAL_POSTURE_REDEEM, 0]
		: req.reachability != null
		? [DIAL_POSTURE_EXPLICIT, req.reachability]
		: [DIAL_POSTURE_EXPLICIT_NONE, 0];
	const plan = planDial(locator.transport, locator.designator, directAddresses, policy, value);
	switch (plan.tag) {
		case "peer_id": {
			const iroh = await abortable(import("@pancake/iroh/internal"), req.signal);
			return iroh._connectIroh(
				locator.designator,
				plan.addresses,
				reachOf(plan, req.redeemReachability),
				host,
				req.handshakeTimeoutMs,
				req.signal,
			);
		}
		case "host_port": {
			const tcp = await abortable(
				net.connect(plan.hostname, plan.port),
				req.signal,
				(conn) => conn.close(),
			);
			const cancel = (): void => tcp.close();
			req.signal?.addEventListener("abort", cancel, { once: true });
			try {
				return await abortable(
					Session.establishDialedLocator(
						host,
						locator.transport,
						locator.designator,
						tcp,
						req.handshakeTimeoutMs,
					),
					req.signal,
					(session) => session.closeTransport(),
				);
			} catch (err) {
				tcp.close();
				throw err;
			} finally {
				req.signal?.removeEventListener("abort", cancel);
			}
		}
		case "rendezvous": {
			// `keyed-relay` names a peer by key alone with no dialable address:
			// its byte path is a relay's rendezvous bridge (ADR-0088). The relay
			// mapping is deployment configuration, exactly like the redeem
			// reachability posture beside it on `Host`; without one the dial
			// refuses loud.
			const relay = await abortable(import("./transport/relay.ts"), req.signal);
			const route = relay.routeFromLocator(locator);
			const rendezvousUrl = host.rendezvousUrl;
			if (route === null && rendezvousUrl === null) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"relay dial: locator has no rendezvous-relay hint and the Host has no rendezvous mapping",
				);
			}
			const channel = await abortable(
				openWebSocketChannel(
					route === null
						? rendezvousUrl!(locator.designator)
						: relay.dialUrl(route, locator.designator),
				),
				req.signal,
				(late) => late.close(),
			);
			const cancel = (): void => channel.close();
			req.signal?.addEventListener("abort", cancel, { once: true });
			try {
				return await abortable(
					Session.establishDialedLocator(
						host,
						locator.transport,
						locator.designator,
						channel,
						req.handshakeTimeoutMs,
					),
					req.signal,
					(session) => session.closeTransport(),
				);
			} catch (err) {
				channel.close();
				throw err;
			} finally {
				req.signal?.removeEventListener("abort", cancel);
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
			const { RtcPeer } = await abortable(import("@pancake/webrtc"), req.signal);
			const peer = new RtcPeer({ offerer: true });
			const bringup = new AbortController();
			const forwardAbort = (): void => {
				if (!bringup.signal.aborted) bringup.abort();
			};
			if (req.signal?.aborted) forwardAbort();
			else req.signal?.addEventListener("abort", forwardAbort, { once: true });
			let disposeCandidates: (() => void) | null = null;
			let candidatesStopped = false;
			const stopCandidates = (): void => {
				if (candidatesStopped) return;
				candidatesStopped = true;
				disposeCandidates?.();
			};
			const candidateSends = new SignalingSendOwner(
				"webrtc dial",
				(error) => bringup.abort(error),
			);
			let peerClosed = false;
			let session: Session | null = null;
			const closePeer = (): void => {
				if (peerClosed) return;
				peerClosed = true;
				peer.close();
			};
			const cancel = (): void => {
				candidateSends.stopAdmission();
				stopCandidates();
				closePeer();
			};
			bringup.signal.addEventListener("abort", cancel, { once: true });
			if (bringup.signal.aborted) cancel();
			try {
				// The far peer's candidates can trickle from the moment it holds our
				// offer, so the sink is registered before the offer is sent.
				disposeCandidates = signaling.onCandidate(locator.designator, (ice) => {
					acceptRemoteCandidate(peer, ice);
				});
				peer.onLocalCandidate((candidate) =>
					candidateSends.admit(() =>
						signaling.candidate(locator.designator, JSON.stringify(candidate))
					)
				);
				const offer = await abortable(peer.createOffer(), bringup.signal);
				const answer = await abortable(
					signaling.offer(locator.designator, offer),
					bringup.signal,
				);
				await abortable(peer.setRemoteAnswer(answer), bringup.signal);
				await abortable(peer.waitOpen(), bringup.signal);
				session = await abortable(
					Session.establishDialedLocator(
						host,
						locator.transport,
						locator.designator,
						peer.channel(),
						req.handshakeTimeoutMs,
					),
					bringup.signal,
					(session) => session.closeTransport(),
				);
			} catch (err) {
				closePeer();
				throw err;
			} finally {
				candidateSends.stopAdmission();
				try {
					stopCandidates();
				} finally {
					if (bringup.signal.aborted) closePeer();
					try {
						await candidateSends.join();
					} finally {
						bringup.signal.removeEventListener("abort", cancel);
						req.signal?.removeEventListener("abort", forwardAbort);
					}
				}
			}
			if (candidateSends.failure != null) {
				session?.closeTransport();
				throw candidateSends.failure;
			}
			return session!;
		}
	}
}

/** The dial entry for `connect` and handoff redeem alike: no dispatch, no
 * grammar, no posture — the core resolves all of that in `dialResolved`.
 *
 * The driver archive (ADR-0112) owns TCP, keyed-TCP, noise-TCP, and iroh:
 * a bare bounded dial gets a new loop, while a supplied Host is transferred
 * before its first native dial. Keyed-relay and WebRTC remain explicit
 * byte-channel integrations because they have no driver resident. Handoff
 * redeem remains on the byte-fed Host action path. */
export async function dialParsedLocator(
	locator: Locator,
	host: Host | undefined,
	opts: {
		reachability?: Reachability;
		redeem?: boolean;
		codec?: Codec;
		handshakeTimeoutMs?: number | null;
		signal?: AbortSignal;
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
		const loop = host?.driverLoop;
		const boundedMs = opts.handshakeTimeoutMs == null
			? HANDSHAKE_TIMEOUT_MS
			: opts.handshakeTimeoutMs;
		const plan = planDial(
			locator.transport,
			locator.designator,
			stringHint(locator, HINT_DIRECT_ADDRESSES) ?? "",
			opts.reachability != null ? DIAL_POSTURE_EXPLICIT : DIAL_POSTURE_EXPLICIT_NONE,
			opts.reachability ?? 0,
		);
		const relayPackage = plan.tag === "rendezvous"
			? await abortable(import("./transport/relay.ts"), opts.signal)
			: null;
		const relayRoute = relayPackage?.routeFromLocator(locator) ?? null;
		const nativeShape = plan.tag === "host_port" || plan.tag === "peer_id" ||
			(plan.tag === "rendezvous" && relayRoute != null);
		if (nativeShape && loopTierAvailable()) {
			if (!boundedMs) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"native driver dials require a positive handshake timeout",
				);
			}
			let driverLoop: DriverLoop;
			let startsLoop = false;
			if (loop != null) {
				driverLoop = loop as DriverLoop;
			} else if (host != null) {
				driverLoop = DriverLoop.takeHost(host, { handshakeMs: boundedMs });
				startsLoop = true;
			} else {
				driverLoop = DriverLoop.open({ codec: opts.codec, handshakeMs: boundedMs });
				startsLoop = true;
			}
			try {
				if (plan.tag === "peer_id") {
					const iroh = await abortable(import("@pancake/iroh/internal"), opts.signal);
					await abortable(
						iroh._ensureIrohProvider(driverLoop, {
							reachability: reachOf(
								plan,
								opts.reachability ?? Reachability.Direct,
							),
						}),
						opts.signal,
					);
				} else if (plan.tag === "host_port") {
					installTcpProvider(driverLoop);
				} else {
					relayPackage!.installProvider(driverLoop, { relayUrl: relayRoute! });
				}
				if (startsLoop) driverLoop.start();
				const session = await driverLoop.connectSession(locator);
				session.ownsHost = host == null;
				return session;
			} catch (error) {
				if (startsLoop) await driverLoop.close();
				throw error;
			}
		}
		dialHost = host ?? new Host(undefined, { codec: opts.codec });
		ownsHost = host == null;
	}
	try {
		const session = await dialResolved(dialHost, {
			locator,
			redeem,
			reachability: opts.reachability,
			redeemReachability: dialHost.redeemReachability,
			handshakeTimeoutMs: opts.handshakeTimeoutMs == null
				? HANDSHAKE_TIMEOUT_MS
				: opts.handshakeTimeoutMs,
			signal: opts.signal,
		});
		session.ownsHost = ownsHost;
		return session;
	} catch (err) {
		if (ownsHost) dialHost.release();
		throw err;
	}
}

/** Dial an exporter a DIAL action names, keyed with `host`'s retained
 * identity, and bind the result to that same host so the redeemed
 * capability and any further handoff it triggers share one identity and
 * connection table. An exporter that never finishes the handshake breaks the
 * redeem on `HANDSHAKE_TIMEOUT_MS` rather than stalling the drain.
 * Binding-internal: the host's action drain calls this. */
export async function dialExporter(
	locator: Locator,
	host: Host,
	signal?: AbortSignal,
): Promise<Session> {
	return await dialParsedLocator(
		locator,
		host,
		{ redeem: true, signal },
	);
}

/** Ticket-only DIAL arm: clone the complete locator, dial, and report.
 * Binding-internal: the action drain calls this. */
export async function runDialTicket(
	host: Host,
	ticket: bigint,
	signal?: AbortSignal,
): Promise<void> {
	let session: Session | null = null;
	try {
		if (host.released || signal?.aborted) return;
		let capacity = 4;
		let locator: Locator;
		for (;;) {
			const hints = new Uint8Array(L.LOCATOR_HINT_VIEW_SIZE * capacity);
			const view = new Uint8Array(L.LOCATOR_VIEW_SIZE);
			const count = new Uint8Array(L.ptrSize);
			const rc = hostS.pancake_host_pending_dial(
				host.raw,
				ticket,
				ab(hints),
				BigInt(capacity),
				ab(view),
				ab(count),
			);
			if (rc === BUFFER_TOO_SMALL) {
				capacity = Number(L.getUsize(new DataView(count.buffer), 0));
				continue;
			}
			checkHost(rc);
			const owned = OwnedLocator.cloneView(view);
			try {
				locator = owned.value();
			} finally {
				owned.release();
			}
			break;
		}
		session = await dialExporter(locator!, host, signal);
		if (host.released || signal?.aborted) {
			session.closeTransport();
			return;
		}
		// The session self-registers in the host's session table (its constructor),
		// so `Session.sendRedeeming` resolves it deterministically from the reply's
		// route via `Host.exporterFor` (ADR-0088) — no capture window to feed here.
		checkHost(hostS.pancake_host_dialed(host.raw, ticket, session.raw));
		session.serve().catch(() => {});
		session = null; // the Host registry now owns terminal teardown
	} catch (err) {
		session?.closeTransport();
		if (host.released || signal?.aborted) return;
		const reason = utf8Encoder.encode(
			err instanceof Error ? err.message : String(err),
		);
		checkHost(hostS.pancake_host_dial_failed(
			host.raw,
			ticket,
			ab(reason),
			BigInt(reason.length),
		));
	}
}

/** Dial a partner from its `ocapn://` locator — the one public dialer.
 *
 * A `tcp` or `iroh` dial runs on the driver archive (ADR-0112): the
 * session rides one stepping native loop that owns the socket, the pumping,
 * and — for a session opened with no shared `host` — the whole stack, so
 * closing the session closes it all. A `keyed-tcp`, `keyed-relay`, or
 * `webrtc` dial, a dial sharing a byte-fed `Host`, an unbounded handshake
 * opt-in, and a runtime whose FFI cannot park a loop (Bun, the browser) still
 * open a byte channel the binding pumps itself.
 *
 * `handshakeTimeoutMs` bounds the OCapN handshake once the byte channel is
 * open, at `HANDSHAKE_TIMEOUT_MS` by default. A peer that accepts the
 * connection and then says nothing rejects with `PancakeError` carrying
 * `TIMEOUT` instead of parking the caller; pass `0` to wait without a bound,
 * which also selects the byte-fed dial, because a native loop requires a
 * positive handshake budget by construction. The bound does not cover opening
 * the channel itself: a TCP connect keeps the runtime's own timeout, and an
 * iroh dial-by-id keeps its discovery retry budget (ADR-0082) before the
 * handshake starts. */
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
	return await dialParsedLocator(
		loc,
		host,
		{ reachability, codec, handshakeTimeoutMs },
	);
}
