import { addressDesignator, listen, locator as tcpLocator, type Server } from "@pancake/tcp";
// DENO-SPECIFIC: dialing a rooms locator.
//
// The rooms server, its clients, the web bridge, and the orchestrator all carry
// the server's address as one string, so a member dials the same way regardless
// of transport: a `hostname:port` dials over TCP; an `ocapn://<nodeid>.iroh?…`
// URI dials over iroh's encrypted QUIC; an `ocapn://<serviceid>.onion` URI
// dials through Tor — directly from a terminal, or through serve.ts's `/relay`
// byte pipe from a browser (which has no socket API).

import { CAPTP_VERSION, CODEC } from "./protocol.ts";
import {
	designatorHostPort,
	formatLocatorUri,
	Host,
	type Locator,
	parseLocator,
	type Session,
	TRANSPORT_IROH,
	TRANSPORT_TCP,
} from "@pancake/runtime";
import { TRANSPORT_ONION } from "@pancake/abi";

/** Whether `locator` is an `ocapn://` URI (iroh) rather than a `hostname:port`. */
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
 * `127.0.0.1:<port>` TCP locator; an `ocapn://` URI passes through unchanged. */
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
	connect(partner: Locator): Promise<Session>;
}

export type RoomsDial = (locator: string) => Promise<Session>;

/** Parse the two locator spellings Rooms accepts into the shared OCapN value:
 * a complete URI, or the TCP `host:port` shorthand retained for interop and
 * local development. */
export function roomsLocator(locator: string): Locator {
	if (isUriLocator(locator)) return parseLocator(locator);
	const { hostname, port } = designatorHostPort(locator);
	return tcpLocator(hostname, port);
}

/** Say a parsed locator back in the spelling a rooms peer dials.
 *
 * The inverse of `roomsLocator`, and here beside it because the two spellings
 * are one decision: a caller that reads an address out of somewhere else — the
 * locator inside a room link, say — needs it back in the form `dial` accepts,
 * and a second place deciding that would be a second grammar. A TCP peer is
 * written as the `host:port` shorthand, which is exactly its designator and
 * carries the whole address; every other transport is written as its complete
 * URI, hints and all, because the hints are part of what makes it dialable. */
export function roomsAddress(locator: Locator): string {
	return locator.transport === TRANSPORT_TCP ? locator.designator : formatLocatorUri(locator);
}

/** Mint a Host for a rooms peer.
 *
 * Every rooms peer — the server, a terminal client, a browser tab, a test —
 * needs a Host that speaks the rooms profile — `CODEC` and `CAPTP_VERSION`
 * together — because both ends of an OCapN session must name the same pair
 * and a default Host speaks the v1.0 Syrup interop floor. Spelling
 * `new Host(...)` at each site is how a fleet drifts: one site keeps the
 * default, its sessions refuse every frame, and the failure reads as a
 * malformed frame rather than a disagreement. So the fleet's peers are
 * built here, once.
 *
 * `seed` pins the retained OCapN identity (the iroh endpoint shares it);
 * omitted, the host takes a fresh one. */
export type RoomsHostPosture = "full" | "next-baseline" | "v1-syrup";

export function roomsHost(seed?: Uint8Array, posture: RoomsHostPosture = "full"): Host {
	const profile = posture === "full"
		? { codec: CODEC, captpVersion: CAPTP_VERSION, features: "full" } as const
		: posture === "next-baseline"
		? { codec: CODEC, captpVersion: CAPTP_VERSION, features: "baseline" } as const
		: { codec: "syrup", captpVersion: "v1_0", features: "baseline" } as const;
	return new Host(seed, profile);
}

/** Listen for rooms peers on `bindHost:port`.
 *
 * A rooms peer comes into being two ways, by dialing and by being dialed, and
 * both have to wear the profile. `listen`'s own default host speaks the v1.0
 * Syrup floor, so a room server that takes it accepts sessions no rooms peer
 * can hold — and the refusal reads as a malformed frame, which sends the next
 * reader looking at the codec rather than at who minted the host. This is the
 * accepting half of `roomsHost`, and `zig build source-check` keeps the rooms
 * tree calling it rather than the raw `listen`.
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

/** Dial a rooms peer from a locator: an `ocapn://…iroh?…` URI over iroh, an
 * `ocapn://…onion` URI over Tor (in the browser, both ride the relay),
 * otherwise `hostname:port` over TCP. A `host` keys the dial with the host's
 * retained OCapN identity and live-session handoff directory (a member's listen endpoint
 * and its room dial share one Host, so an inbox it publishes giftably is the one
 * a caller's redeem withdraws). Omitted, the dial gets a fresh identity, which is
 * all an ordinary client needs.
 *
 * A browser and a terminal dial the same way; the browser's `connect` rides the
 * relay transparently.
 *
 * Either way the session speaks the rooms profile: a dial with no host of its
 * own mints one through `roomsHost`, so the codec and the CapTP version travel
 * together rather than one of them being passed loose. */
export function dial(locator: string, runtime: RoomsRuntime): Promise<Session> {
	if (isUriLocator(locator)) {
		const loc = roomsLocator(locator);
		if (loc.transport !== TRANSPORT_IROH && loc.transport !== TRANSPORT_ONION) {
			throw new Error(
				`rooms expected an iroh or onion ocapn:// URI, got "${loc.transport}": ${locator}`,
			);
		}
		return runtime.connect(loc);
	}
	return runtime.connect(roomsLocator(locator));
}
