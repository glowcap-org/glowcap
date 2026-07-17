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

import { Session } from "./session.ts";
import { Host } from "./host.ts";
import { driverS } from "./internal/ffi/driver.ts";
import { ffi, net } from "./internal/ffi/runtime.ts";
import { ab, readBytes } from "./internal/seam.ts";
import { checkHost, PancakeError } from "./errors.ts";
import { type Codec, Reachability } from "./value.ts";
import { HINT_DIRECT_ADDRESSES, parseLocator } from "./locator.ts";
import {
	DIAL_PLAN_ADDRESSES_LEN_OFF,
	DIAL_PLAN_ADDRESSES_OFF,
	DIAL_PLAN_HOST_LEN_OFF,
	DIAL_PLAN_HOST_OFF,
	DIAL_PLAN_PORT_OFF,
	DIAL_PLAN_REACH_KIND_OFF,
	DIAL_PLAN_REACH_VALUE_OFF,
	DIAL_PLAN_SHAPE_OFF,
	DIAL_PLAN_SIZE,
	DIAL_POSTURE_EXPLICIT,
	DIAL_POSTURE_EXPLICIT_NONE,
	DIAL_POSTURE_REDEEM,
	DIAL_REACH_CONFIGURED,
	DIAL_REACH_DIRECT,
	DIAL_SHAPE_HOST_PORT,
	DIAL_SHAPE_PEER_ID,
	INVALID_ARGUMENT,
	PENDING_DIAL_DESIGNATOR_LEN_OFF,
	PENDING_DIAL_DESIGNATOR_OFF,
	PENDING_DIAL_HINT_LEN_OFF,
	PENDING_DIAL_HINT_OFF,
	PENDING_DIAL_SIZE,
	PENDING_DIAL_TRANSPORT_LEN_OFF,
	PENDING_DIAL_TRANSPORT_OFF,
} from "./internal/abi.ts";

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
	};

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
	const out = new Uint8Array(DIAL_PLAN_SIZE);
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
			dv.getBigUint64(off, true),
			dv.getBigUint64(lenOff, true),
		);
	const shape = dv.getUint32(DIAL_PLAN_SHAPE_OFF, true);
	if (shape === DIAL_SHAPE_PEER_ID) {
		return {
			tag: "peer_id",
			addresses: str(DIAL_PLAN_ADDRESSES_OFF, DIAL_PLAN_ADDRESSES_LEN_OFF),
			reachKind: dv.getUint32(DIAL_PLAN_REACH_KIND_OFF, true),
			reachValue: dv.getUint32(DIAL_PLAN_REACH_VALUE_OFF, true),
		};
	}
	if (shape === DIAL_SHAPE_HOST_PORT) {
		return {
			tag: "host_port",
			hostname: str(DIAL_PLAN_HOST_OFF, DIAL_PLAN_HOST_LEN_OFF),
			port: dv.getUint16(DIAL_PLAN_PORT_OFF, true),
		};
	}
	throw new PancakeError(INVALID_ARGUMENT, `unknown dial shape ${shape}`);
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
 * it names and drive the keyed handshake to a ready `Session`. */
export async function dialResolved(host: Host, req: DialRequest): Promise<Session> {
	const [policy, value] = req.redeem
		? [DIAL_POSTURE_REDEEM, 0]
		: req.reachability !== undefined
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
			);
		}
		case "host_port": {
			const tcp = await net.connect(plan.hostname, plan.port);
			try {
				return await Session.establishDialedLocator(host, req.transport, req.designator, tcp);
			} catch (err) {
				tcp.close();
				throw err;
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
	} = {},
): Promise<Session> {
	const redeem = opts.redeem ?? false;
	let dialHost: Host;
	if (redeem) {
		if (host === undefined) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"handoff redeem requires a shared host",
			);
		}
		dialHost = host;
	} else {
		dialHost = host ?? new Host(undefined, { codec: opts.codec });
	}
	return await dialResolved(dialHost, {
		transport,
		designator,
		directAddresses: directAddressesHint,
		redeem,
		reachability: opts.reachability,
		redeemReachability: dialHost.redeemReachability,
	});
}

/** Dial an exporter a DIAL action names, keyed with `host`'s retained
 * identity, and bind the result to that same host so the redeemed
 * capability and any further handoff it triggers share one identity and
 * connection table. Binding-internal: the host's action drain calls this. */
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
	const out = new Uint8Array(PENDING_DIAL_SIZE);
	try {
		checkHost(driverS.pancake_host_pending_dial(host.raw, ticket, ab(out)));
		const dv = new DataView(out.buffer);
		const str = (off: number, lenOff: number): string => {
			const len = dv.getBigUint64(lenOff, true);
			return len === 0n ? "" : utf8Decoder.decode(readBytes(dv.getBigUint64(off, true), len));
		};
		const transport = str(PENDING_DIAL_TRANSPORT_OFF, PENDING_DIAL_TRANSPORT_LEN_OFF);
		const designator = str(PENDING_DIAL_DESIGNATOR_OFF, PENDING_DIAL_DESIGNATOR_LEN_OFF);
		const hint = str(PENDING_DIAL_HINT_OFF, PENDING_DIAL_HINT_LEN_OFF);
		const session = await dialExporter(transport, designator, hint, host);
		session.hostDialed = true;
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

/** Dial a partner from its `ocapn://` locator — the one public dialer. */
export async function connect(
	uri: string,
	reachability?: Reachability,
	host?: Host,
	codec?: Codec,
): Promise<Session> {
	const loc = parseLocator(uri);
	if (host !== undefined && codec !== undefined && codec !== host.codec) {
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
		{ reachability, codec },
	);
}
