// DENO-SPECIFIC: dialing a rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way
// regardless of transport. A `hostname:port` dials over TCP. An
// `ocapn://<nodeid>.iroh?…` URI dials over iroh's encrypted QUIC. An
// `ocapn://<serviceid>.onion` URI dials through Tor, directly from a terminal
// or through serve.ts's `/relay` byte pipe from a browser (which has no socket
// API). An `ocapn://<key>.webrtc` URI is the default browser-to-browser door
// for both DMs and a tab-hosted session, signaled through a directory. A
// tab-hosted session sturdyref names that directory in its
// `signaling-directory` hint so Attach does not guess the attaching tab's page.
// An `ocapn://<key>.noise-relay?…` URI is that same door when DMs use the
// sealed relay. The browser connector reads a noise-relay locator's
// rendezvous-relay hint and opens it as a rendezvous bridge, often the same
// `/relay`.

import { addressDesignator, listen, locator as tcpLocator, type Server } from "@glowcap/tcp";
import { DIRECTORY } from "./protocol.ts";
import {
	designatorHostPort,
	formatLocatorUri,
	formatSturdyRef,
	Host,
	type Locator,
	parseLocator,
	parseSturdyRef,
	type Session,
	TRANSPORT_ID,
	TRANSPORT_IROH,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_ONION,
	TRANSPORT_TCP,
	TRANSPORT_WEBRTC,
} from "@glowcap/runtime";
import type { Ref } from "@glowcap/runtime";
import { roomsHostOptions, type RoomsHostPosture } from "./profile.ts";

/** Whether `locator` is an `ocapn://` URI rather than a `hostname:port`. */
export function isUriLocator(locator: string): boolean {
	return locator.includes("://");
}

/** The token the server prints after `ROOMS-SERVER-LISTENING`. */
const ANNOUNCE_RE = /ROOMS-SERVER-LISTENING (\S+)/;

/** A loopback TCP designator for an ephemeral/bound port. */
export function loopbackTcpDesignator(port: number): string {
	return addressDesignator("127.0.0.1", port);
}

/** Turn the server's announce token into a dial locator: a bare port becomes a
 * `127.0.0.1:<port>` TCP locator. An `ocapn://` URI passes through unchanged. */
export function announceToLocator(token: string): string {
	return /^\d+$/.test(token) ? loopbackTcpDesignator(Number(token)) : token;
}

/** Read a rooms server child's first `ROOMS-SERVER-LISTENING <token>` line from
 * its stdout and resolve it to a dial locator (a TCP `host:port`, or an iroh
 * `ocapn://` URI), giving up after `deadlineMs`. The orchestrator and the web
 * bridge both spawn a server and wait for this line, so the reader lives here
 * beside the announce vocabulary it parses. */
export async function readAnnouncedLocator(
	proc: Deno.ChildProcess,
	deadlineMs = 10_000,
): Promise<string> {
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	let buf = "";
	const deadline = Date.now() + deadlineMs;
	try {
		while (Date.now() < deadline) {
			const { value, done } = await reader.read();
			if (done) break;
			buf += decoder.decode(value);
			const m = buf.match(ANNOUNCE_RE);
			if (m) return announceToLocator(m[1]);
		}
	} finally {
		reader.releaseLock();
	}
	throw new Error("rooms server never announced its locator");
}

export interface RoomsRuntime {
	readonly host: Host;
	connect(partner: Locator, options?: { readonly signal?: AbortSignal }): Promise<Session>;
}

export type RoomsDial = (locator: string) => Promise<Session>;

/** A directory reached through the Host-owned route scheduler already carries
 * the public directory capability it redeemed. A concrete physical locator
 * carries only its session and fetches the same capability after opening. */
export type ReachedRoomsDirectory = Session | { session: Session; directory: Ref };
export type RoomsDirectoryDial = (locator: string) => Promise<ReachedRoomsDirectory>;

/** Rooms durable capabilities have one URI encoding, independent of the live
 * CapTP profile that later carries them. The Goblins-compatible base64url form
 * is the persisted and copyable application contract. */
const ROOMS_STURDYREF_VERSION = "v1_0" as const;

export function parseRoomsSturdyref(sturdyref: string): ReturnType<typeof parseSturdyRef> {
	return parseSturdyRef(sturdyref, ROOMS_STURDYREF_VERSION);
}

export function roomsSturdyrefLocator(sturdyref: string): Locator {
	return parseRoomsSturdyref(sturdyref).locator;
}

/** Locator hint naming the directory that routes WebRTC signaling for a
 * tab-hosted session sturdyref. A bare `webrtc` designator does not say which
 * directory filed the answering inbox. Attach reads this instead of guessing
 * the attaching tab's page directory. */
export const WEBRTC_SIGNALING_DIRECTORY_HINT = "signaling-directory";

/** The directory locator a webrtc session door names for `signalOffer`, or
 * undefined when the sturdyref predates the hint. */
export function webrtcSignalingDirectoryHint(locator: Locator): string | undefined {
	const hinted = locator.hints.get(WEBRTC_SIGNALING_DIRECTORY_HINT);
	return typeof hinted === "string" && hinted !== "" ? hinted : undefined;
}

export function formatRoomsSturdyref(locator: Locator, swissnum: string | Uint8Array): string {
	return formatSturdyRef(locator, swissnum, ROOMS_STURDYREF_VERSION);
}

/** Parse the two locator forms Rooms accepts into the shared OCapN value: a
 * complete URI, including a negotiated multi-location route, or the TCP
 * `host:port` shorthand retained for interop and local development. */
export function roomsLocator(locator: string): Locator {
	if (isUriLocator(locator)) return parseLocator(locator);
	const { hostname, port } = designatorHostPort(locator);
	return tcpLocator(hostname, port);
}

/** Say a parsed locator back in the form a rooms peer dials.
 *
 * The inverse of `roomsLocator`, kept beside it because the two forms are one
 * decision. A caller that reads an address out of somewhere else, such as the
 * locator inside a room link, needs it back in the form `dial` accepts, and a
 * second place deciding that would be a second grammar. A TCP peer is written
 * as the `host:port` shorthand, which is its designator and carries the whole
 * address. Every other transport is written as its complete URI, hints and
 * all, because the hints are part of what makes it dialable. */
export function roomsAddress(locator: Locator): string {
	return locator.transport === TRANSPORT_TCP ? locator.designator : formatLocatorUri(locator);
}

/** Create a Host for a rooms peer.
 *
 * Every rooms peer (the server, a terminal client, a browser tab, a test)
 * needs a Host that speaks the Rooms wire posture, because both ends of an
 * OCapN session must name a coherent profile and a default Host speaks the
 * v1.0 Syrup interop floor. Writing `new Host(...)` at each site lets a fleet
 * drift: one site keeps the default, its sessions refuse every frame, and the
 * failure reads as a malformed frame and not as a disagreement. So the peers
 * are built here, once.
 *
 * `seed` pins the retained OCapN identity (the iroh endpoint shares it).
 * Omitted, the host takes a fresh one. */
export function roomsHost(seed?: Uint8Array, posture: RoomsHostPosture = "full"): Host {
	return new Host(seed, roomsHostOptions(posture));
}

/** Listen for rooms peers on `bindHost:port`.
 *
 * A rooms peer comes into being two ways, by dialing and by being dialed, and
 * both have to wear the profile. `listen`'s default host speaks the v1.0 Syrup
 * floor, so a room server that takes it accepts sessions no rooms peer can
 * hold, and the refusal reads as a malformed frame, which sends the next
 * reader looking at the codec and not at who created the host. This is the
 * accepting half of `roomsHost`, and `zig build source-check` keeps the rooms
 * tree calling it and not the raw `listen`.
 *
 * `advertisedHost` is the dialable hostname signed into the listener's
 * locator, which a wildcard bind requires because it has no address of its
 * own. */
export function roomsListen(
	bindHost: string,
	port: number,
	host: Host = roomsHost(),
	advertisedHost?: string,
): Promise<Server> {
	return listen(bindHost, port, { host, advertisedHost });
}

/** Dial one physical Rooms transport: an iroh URI over iroh, an onion URI over Tor,
 * a webrtc URI through directory signaling (the default browser-to-browser door
 * for DMs and a tab-hosted session), a noise-relay URI over the sealed relay
 * (the same door when DMs use relay), otherwise `hostname:port` over TCP. In the
 * browser, iroh and onion ride `/relay?target=`, webrtc uses the directory, and
 * noise-relay opens the locator's rendezvous-relay hint. A `host` keys the dial
 * with the host's retained OCapN identity and live-session handoff directory (a
 * member's listen endpoint and its room dial share one Host, so an inbox it
 * publishes giftably is the one a caller's redeem withdraws). Omitted, the dial
 * gets a fresh identity, which is all an ordinary client needs.
 *
 * A browser and a terminal dial the same way, and the browser's `connect` rides
 * the relay transparently.
 *
 * Either way the session speaks the rooms profile. A dial with no host creates
 * one through `roomsHost`, so the codec and the CapTP version travel together
 * and are not passed loose. */
export function dial(locator: string, runtime: RoomsRuntime, signal?: AbortSignal): Promise<Session> {
	if (isUriLocator(locator)) {
		const loc = roomsLocator(locator);
		if (loc.transport === TRANSPORT_ID) {
			throw new Error("a Rooms identity locator must be reached through a named capability");
		}
		if (
			loc.transport !== TRANSPORT_IROH && loc.transport !== TRANSPORT_ONION &&
			loc.transport !== TRANSPORT_WEBRTC && loc.transport !== TRANSPORT_NOISE_RELAY &&
			loc.transport !== TRANSPORT_TCP
		) {
			throw new Error(
				`rooms expected an iroh, onion, webrtc, noise-relay, or tcp ocapn:// URI, got "${loc.transport}": ${locator}`,
			);
		}
		return runtime.connect(loc, { signal });
	}
	return runtime.connect(roomsLocator(locator), { signal });
}

/** Reach the public Rooms directory through the owner appropriate to its
 * locator. Concrete transports open one physical session. An `id/via` locator
 * is authority plus routing advice, not a physical transport, so let the
 * Host's Node expand, validate, race, cancel, and fall back through the bundle
 * while Rooms supplies only the publication name it wants. */
export async function dialDirectory(
	locator: string,
	runtime: RoomsRuntime,
	signal?: AbortSignal,
): Promise<ReachedRoomsDirectory> {
	const parsed = roomsLocator(locator);
	if (parsed.transport !== TRANSPORT_ID) return await dial(locator, runtime, signal);
	const directory = await runtime.host.fetchAt(parsed, DIRECTORY);
	const session = runtime.host.exporterFor(directory);
	if (session === null) {
		throw new Error("the identity route returned a directory capability without its exporter session");
	}
	return { session, directory };
}
