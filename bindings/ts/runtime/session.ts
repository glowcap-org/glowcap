// The application surface over the byte-fed host (libglowcap_host,
// ADR-0072): `Session` and its verbs (`fetch`/`send`/`tell`/`spawn`/
// `publish`/`enliven`/`serve`/`close`), plus mint/handshake
// (`establishDialedLocator` / `establishAccepted`). The dial executor and
// `connect` live in `dial.ts`; Server/`listen` live in `listen.ts`. The
// `RemotePromise` handle, fetch/enliven mint→await, far-send `sendFar` /
// `promiseFor`, live in `promise.ts`. Spawn/publish hosting, ADR-0064
// proxies, and Host-reference send·tell dispatch live in `trampoline.ts`. The
// byte-fed embedder pump (handshake,
// read transport packets, feed, drain, flush) lives in `pump.ts`. The host owns
// everything else: routing, redemption, gift origination, far vows. `mod.ts`
// re-exports the public members.

import { DESIGNATOR_SCHEME_ADDRESS, DESIGNATOR_SCHEME_KEY, HANDSHAKE_TIMEOUT_MS } from "@glowcap/abi";
import { checkHost, GlowcapError } from "./errors.ts";
import { Host } from "./host.ts";
import { hostS } from "./internal/ffi/host.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer } from "./internal/seam.ts";
import { type CloseOptions } from "./lifecycle.ts";
import { type Locator, withOwnedLocator } from "./locator.ts";
import { SessionApplication } from "./session/application.ts";
import { currentTurnSession } from "./trampoline.ts";
import { type Argument } from "./value.ts";

// Encoder for establish/fetch swiss bytes.
const utf8Encoder = new TextEncoder();

export {
	durableIdentityAuthenticated,
	type DurableProvenance,
	type PartnerIdentity,
	provenanceFromAbi,
} from "./session/identity.ts";

/** How long a partner has to finish the keyed handshake once the byte channel
 * is open, on both halves: what `connect` allows a dialed partner, and what a
 * listener allows an accepted one.
 *
 * Matches the CLI's own product default. Something finite is the point: this
 * project's rule for CapTP waits is that an unbounded one is a hang rather than
 * a slow success, and neither half of a connection is exempt. It bounds the
 * handshake alone, never opening the channel: a TCP connect keeps the runtime's
 * own timeout, and an iroh dial-by-id is one transport attempt, both spent
 * before the handshake starts. */
export { HANDSHAKE_TIMEOUT_MS };

/** How transport packets move for one connection. It is the seam the byte-fed pump
 * reads and the FLUSH drain writes. The core supplies the TCP wrapper below
 * over the runtime's own sockets; the `@glowcap/iroh` companion supplies the
 * iroh one, so the iroh artifact stays out of this core module entirely.
 * Framing is never the channel's job: the Host transport profile owns whether
 * reads are byte-stream chunks or whole message frames. */
export interface Channel {
	/** The next inbound transport packet, or `null` at a clean end of stream. */
	read(): Promise<Uint8Array | null>;
	/** Write every byte of `data`, awaiting the runtime's flush/backpressure. */
	write(data: Uint8Array): Promise<void>;
	/** Stop I/O immediately. A returned promise is the FFI release barrier. */
	close(): void | Promise<void>;
}

/** Generic metadata an embedder-owned listener supplies with one accepted byte
 * channel. The provider, not the binding core, declares how its designator is
 * interpreted; adding a transport therefore adds no name dispatch here. */
export interface AcceptedTransport {
	readonly transport: string;
	readonly designatorScheme:
		| typeof DESIGNATOR_SCHEME_ADDRESS
		| typeof DESIGNATOR_SCHEME_KEY;
	readonly serverDesignator: string;
	readonly channel: Channel;
	readonly localAddress?: string;
	readonly verifiedChannelKey?: string | null;
}

/** Result of {@link Session.sendRedeeming}: the ordinary send reply plus the
 * direct exporter session selected by that reply's route, when one exists. */
export interface SendRedeemingResult {
	reply: Argument;
	via: Session | null;
}

/** What a loop-minted `Session` needs from the driver loop that owns it
 * (ADR-0112). Declared here and implemented by `driver_loop.ts`'s `DriverLoop`,
 * so the Session arms can dispatch on it without importing the loop tier. */
export interface DriverLoopHandle {
	/** One zero-timeout step plus an event dispatch, on the driving thread. */
	stepNow(): void;
	/** Schedule one step soon: a kick that is legal from inside a turn. */
	scheduleStep(): void;
	/** Schedule one deferred step and join its complete effect drain. */
	settleStep(): Promise<void>;
	/** Release one loop-owned session through the loop's own verb. */
	ffiSessionRelease(ptr: Ptr): void;
	/** Start delivering one loop-owned session's inbound: setup is done. */
	serveSession(ptr: Ptr): void;
	/** Resolve and claim the exporter session for a Host capability. */
	claimReferenceExporter(reference: Uint8Array): Ptr | null;
	/** Close one loop-owned session through the loop's FFI barrier. */
	closeSession(ptr: Ptr, options?: CloseOptions): Promise<void>;
	/** Release the loop and everything it owns, to the FFI barrier. */
	close(options?: CloseOptions): Promise<void>;
	/** Wrap a loop-minted session handle as the public `Session`. */
	adoptSession(ptr: Ptr): Session;
}

/** The loop-backed `Channel` (ADR-0112): the driver loop owns the wire, so it
 * carries no byte verbs the pump would drive. It has only the closed event the serve
 * promise awaits and the loop back-reference the Session arms dispatch on. */
export interface LoopChannel extends Channel {
	readonly driverLoop: DriverLoopHandle;
	waitClosed(): Promise<void>;
	/** Settle the loop-backed serve boundary from the FFI SESSION_CLOSED
	 * event before generic transport retirement runs. */
	finishClosed(error: GlowcapError | null): void;
}

/** A live CapTP session with one OCapN partner, the one object an application
 * holds, over one byte-fed `GlowcapHostSession` the shared `Host` minted.
 *
 *   await using runtime = await Runtime.open({ providers: [tcp.provider()] });
 *   await using session = await runtime.connect(tcp.locator("127.0.0.1", 9099));
 *   session.serve().catch((e) => console.error(e));
 *   const room = await session.fetch("room");
 *   const inbox = session.spawn((verb, args) => { ...; });
 *   await session.send(room, "subscribe", ["alice", inbox]);
 */
export class Session extends SessionApplication {
	private constructor(ptr: Ptr, host: Host, transport: Channel) {
		super(ptr, host, transport);
		// Join the host's registry here, not in the base constructor: the
		// registry stores `Session`, and only this constructor can type `this`
		// as one. Nothing can observe the registration window, because a
		// FLUSH action cannot run until construction returns to the loop.
		host.registerSession(ptr, this);
	}

	// ── Construction: establish, dial, accept ──────────────────────────────────

	/** Mint the dialing half over a byte channel the caller already realized
	 * for `locator`. The locator travels whole; the host retains its own dial
	 * default for the transport and keys duplicate-dial refusal on the
	 * designator, so no locator policy lives here. The handshake is bounded by
	 * `handshakeTimeoutMs` (`HANDSHAKE_TIMEOUT_MS` on every dial the binding
	 * performs; `0` or `null` waits unbounded), and overrunning it rejects
	 * with `GlowcapError` carrying `TIMEOUT`. Binding-internal. */
	static async establishDialedLocator(
		host: Host,
		locator: Locator,
		transport: Channel,
		handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
		verifiedChannelKey: string | null = null,
	): Promise<Session> {
		let session: Session | null = null;
		try {
			const out = new Uint8Array(8);
			withOwnedLocator(
				locator,
				(owned) =>
					checkHost(hostS.glowcap_host_session_open_dialed_locator(host.raw, owned.borrowView(), ab(out))),
			);
			session = new Session(outPointer(out), host, transport);
			// Before the first partner byte, which is the only window a realizer's
			// proof can be weighed in.
			if (verifiedChannelKey) session.bindVerifiedChannelKey(verifiedChannelKey);
			return await session.establish(handshakeTimeoutMs);
		} catch (error) {
			if (session == null) await transport.close();
			else await session.closeTransport();
			throw error;
		}
	}

	/** Mint the accepting half over a connection the caller's own listener
	 * produced. `accepted` carries the provider's transport metadata and byte
	 * channel as one value; the host resolves what this accept signs and
	 * retains it without displacing an explicitly selected advertised locator
	 * (ADR-0078), with no locator policy in this binding layer. The handshake
	 * is bounded by `handshakeTimeoutMs` (`HANDSHAKE_TIMEOUT_MS` in every
	 * accept loop here; `0` or `null` waits unbounded, which a caller parking
	 * a registration rather than running an accept loop wants), and
	 * overrunning it rejects with `GlowcapError` carrying `TIMEOUT`, which an
	 * accept loop treats as any other bad partner. Binding-internal. */
	static async establishAccepted(
		host: Host,
		accepted: AcceptedTransport,
		handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
	): Promise<Session> {
		const {
			transport: transportName,
			designatorScheme,
			serverDesignator,
			channel: transport,
			localAddress: acceptedLocalAddr = "",
			verifiedChannelKey = null,
		} = accepted;
		let session: Session | null = null;
		try {
			const server = utf8Encoder.encode(serverDesignator);
			const local = utf8Encoder.encode(acceptedLocalAddr);
			const t = utf8Encoder.encode(transportName);
			const out = new Uint8Array(8);
			const openCode = hostS.glowcap_host_session_open_accepted(
				host.raw,
				ab(t),
				BigInt(t.length),
				designatorScheme,
				ab(server),
				BigInt(server.length),
				ab(local),
				BigInt(local.length),
				ab(out),
			);
			checkHost(openCode);
			session = new Session(
				outPointer(out),
				host,
				transport,
			);
			// Before the first partner byte, which is the only window a realizer's
			// proof can be weighed in.
			if (verifiedChannelKey) session.bindVerifiedChannelKey(verifiedChannelKey);
			return await session.establish(handshakeTimeoutMs);
		} catch (error) {
			if (session == null) await transport.close();
			else await session.closeTransport();
			throw error;
		}
	}

	static adoptLoopSession(ptr: Ptr, host: Host, transport: LoopChannel): Session {
		return new Session(ptr, host, transport);
	}
}

/** The live session whose inbound call is running right now, or null outside
 * any hosted turn.
 *
 * A hosted actor can answer calls arriving through any Port on its Host. When
 * behavior must reply to its caller (send to a reply capability it was handed,
 * or hand back a fresh one), it reads the arriving session here:
 *
 *   host.publish("dm", (verb, args) => {
 *     const from = String(args[0]), text = String(args[1]);
 *     const reply = args[2];                     // a Ref the caller passed
 *     const session = currentSession();          // the session it arrived through
 *     if (session && reply instanceof Ref) {
 *       session.send(reply, "ack", [from]);      // reply on the same session
 *     }
 *   });
 *
 * The reply capability is a far import in the arriving session, so it must be
 * sent in that same session. Capture the session synchronously inside the
 * turn (it is null once the turn returns) to reply on a later turn. */
export function currentSession(): Session | null {
	const s = currentTurnSession();
	return s instanceof Session ? s : null;
}
