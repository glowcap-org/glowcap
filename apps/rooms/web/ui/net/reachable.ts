// Being reachable as a browser, which nothing on the network can dial.
//
// A tab opens no listening socket, so the ordinary answer to "how does anyone
// reach you" does not apply. What it does instead is hold one host that
// survives every directory reconnect, publish an inbox on it for each peer it
// is willing to hear from, and let the relay's rendezvous bridge a cold dial
// onto the socket it already holds (ADR-0088).
//
// The lifetime is the whole point. A room server respawning takes every
// directory session with it, and none of what is written here goes with them:
// the host, the inboxes published on it, and the ledger counting them all
// outlive any one connection, because a line running browser to browser has
// nothing to do with the room. Parking any of it on a session is the mistake
// this module exists to keep out of reach.

import * as store from "../store.ts";
import { serveRendezvous } from "@pancake/web";
import type { RendezvousHandle, WebRuntime } from "@pancake/web";
import { formatLocatorUri, formatPeerUri, type Host, TRANSPORT_NOISE_RELAY, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { roomsLocator, WEBRTC_SIGNALING_DIRECTORY_HINT } from "../../../lib/locator.ts";
import { directMessageReceiverBehavior } from "../../../lib/direct_message.ts";
import { serveWebrtcSignaling } from "../../../lib/signaling.ts";
import type { IceServer } from "../../../lib/ice.ts";
import { type InboxOfferer, type InboxPublisher, inboxPublisher } from "../../../lib/dm_inbox.ts";
import type { Directory } from "../../../lib/room/client.ts";
import { NICK_TAKEN, roomErrorOf } from "../../../lib/errors.ts";
import * as prefs from "../prefs.ts";
import type { DirId } from "../types.ts";
import { reason, trouble } from "./common.ts";
import { convSession, dirSession, isCurrent, type Live } from "./live.ts";
import { directReceiverFor, establishRequestedDirect, sendDm } from "./direct.ts";
import { resendFile, resendRoomLine } from "./send.ts";
import type { RoomsPageContext } from "../page.ts";

type InboxOwner = {
	host: Host;
	publisher: InboxPublisher;
	iceServers: () => Promise<IceServer[]>;
};

/** Inbox host, offerers, rendezvous, and attach signaling that outlive any one
 * UI directory session. */
export class PageReachable {
	inboxOwner: InboxOwner | null = null;
	readonly offerers = new Map<DirId, InboxOfferer>();
	rendezvous: RendezvousHandle | null = null;
	saidRendezvousTrouble = false;
	/** Directory used only to route WebRTC attach signaling, never the store. */
	signalingDirectory: Directory | null = null;
	/** Directory Attach named so `signalOffer` can find the answering inbox. */
	signalingDirectoryLocator: string | null = null;

	stopSignalingDirectory(): void {
		const signaling = this.signalingDirectory;
		this.signalingDirectory = null;
		this.signalingDirectoryLocator = null;
		void signaling?.close();
	}

	stopRendezvous(): void {
		this.rendezvous?.stop();
		this.stopSignalingDirectory();
	}
}

/** The directory a webrtc Attach dials through when this tab holds no UI membership. */
export function attachSignalingDirectory(page: RoomsPageContext): Directory | null {
	return page.reachable.signalingDirectory;
}

// ── Cold-dial rendezvous: being reachable as a browser (ADR-0088) ──────────
// The one inbox host per page. It dials the directory AND accepts cold-dials,
// so the gift the room deposits over our directory session and the withdraw a
// cold-dial carries resolve through one live-session directory. It publishes one
// giftable inbox per peer we are willing to hear from, and registers our key
// designator at the relay's rendezvous, so a peer that redeems an introduction to
// us is bridged onto our held socket. Kept across reconnects: a cold-dial line is
// browser-to-browser through the relay, independent of the room server, so a room
// respawn must not tear it down.
//
// Each live peer gets one inbox, up to `MAX_DM_INBOXES`. A departing peer's
// alias is retired; any capability already issued to that peer keeps the exact
// old actor and is never retargeted to a later holder of the name.
//
// Which transport this tab advertises for direct messages: a `webrtc`
// identity by default, so the DataChannel carries the DM directly and the
// room directory carries only the signaling (ADR-0089), or the relay
// rendezvous identity when Settings (or `?dm=relay`) chooses the relay.
// Read on first use so importing the page owner graph does not require a
// window location.
function dmTransport() {
	return prefs.dmTransport();
}
// Reply back-channels a peer handed us with an incoming DM: the connection the
// message arrived on plus the reply capability it carried. Our own reply rides
// this arriving connection (`currentSession`, ADR-0088) — the only way to answer
// a peer that opened no listener — rather than cold-dialing them back.
//
// Keyed on the conversation, not the nick. A route reaches one connection, and a
// nick is a name the directory can reclaim: keyed by name, closing a stale
// conversation with a member who had left and rejoined took the live one's reply
// route with it. Keyed here, a row lives and dies with the conversation it
// belongs to.

// The inbox one named peer's direct messages arrive on. `peer` is the nick the
// room granted them, closed over at mint time, because the directory hands this
// inbox to that peer alone and the message names nobody.
//
// The inbox itself outlives every connection to the directory — it is a
// giftable on the inbox Host, reached by a cold dial — so it closes over the
// directory's *name* and resolves the live session state inside each turn.
// Closing over one `Live` blamed every later call on the connection that
// happened to be up at mint time: after a reconnect, a peer's reply route was
// filed on the dead session's table and a handed room was refused as if the
// offers list were full, on a tab where everything was healthy.
function inboxFor(page: RoomsPageContext, dir: DirId, peer: string, registrationId: string) {
	return directMessageReceiverBehavior(directReceiverFor(page, dir, peer, registrationId, true));
}

// Mint and offer one inbox per peer, on the inbox host so a redeem dial finds
// it. One offerer per directory: an inbox is offered *to* a nickname, and a
// nickname belongs to the directory that granted it, so two directories offering
// under the same name are offering to two different people. The offerer follows
// the giftables it counts — the inbox Host, which survives reconnects — so a
// reconnect re-offers the same inboxes rather than minting a second set (see
// `offerers`).
export function ensureOfferer(page: RoomsPageContext, dir: DirId): InboxOfferer {
	const projection = page.projection;
	const held = page.reachable.offerers.get(dir);
	if (held !== undefined) return held;
	const offerer = requireInboxPublisher(page).offerer({
		dir: () => dirSession(page, dir)?.dir ?? null,
		behaviorFor: (peer, registrationId) => inboxFor(page, dir, peer, registrationId),
		skip: (peer) => store.isSelf(projection, dir, peer),
		// That one person's direct messages toward this tab will not arrive,
		// and they are told only that the send failed — so this side says which
		// offer broke, where the reader can see it.
		onError: (peer, err) =>
			store.deliverActive(
				projection,
				store.sysItem(
					projection,
					`Could not prepare a direct-message inbox for ${peer}: ${reason(err)}. ` +
						`Their messages to you may not arrive.`,
				),
			),
	});
	page.reachable.offerers.set(dir, offerer);
	return offerer;
}

/** Retire one directory's aliases without resetting the Host-wide ledger that
 * bounds every directory together. */
export function forgetOfferer(page: RoomsPageContext, dir: DirId): void {
	const held = page.reachable.offerers.get(dir);
	page.reachable.offerers.delete(dir);
	void held?.close();
}

// Peers to offer an inbox to as soon as our own registration is acknowledged.
// The gate below is real — an offer sent before the directory has granted us a
// name is refused, so publishing before that answer only creates authority the
// offerer must retire. Dropping the request also loses it: `mintInboxFor`
// dispatches synchronously
// inside the inbound feed while the acknowledgement lands on a microtask, so the
// first peer to ask arrives before the flag does.

export function offerInboxFor(home: Live, peer: string, registrationId: string): void {
	if (!isCurrent(home)) return;
	if (!home.registered) {
		home.deferredOffers.set(registrationId, peer);
		return;
	}
	ensureOfferer(home.page, home.id).offer(peer, registrationId);
}

function flushDeferredOffers(home: Live): void {
	const waiting = [...home.deferredOffers];
	home.deferredOffers.clear();
	for (const [registrationId, peer] of waiting) offerInboxFor(home, peer, registrationId);
}

// What publishes the giftables an offer is made of. Reaching it before the inbox
// Runtime is open is a caller mistake rather than a state to handle, so it says
// so instead of answering null.
function requireInboxPublisher(page: RoomsPageContext): InboxPublisher {
	if (page.reachable.inboxOwner === null) throw new Error("rooms inbox Runtime is not open");
	return page.reachable.inboxOwner.publisher;
}

// Create the inbox host once and start serving cold-dials against it. Idempotent
// across reconnects so our identity, held registrations, and open cold-dial
// lines survive a room-server respawn.
export function ensureInbox(
	page: RoomsPageContext,
	runtime: WebRuntime,
	iceServers: () => Promise<IceServer[]>,
): Host {
	if (page.reachable.inboxOwner !== null) return page.reachable.inboxOwner.host;
	const transport = dmTransport();
	const host = runtime.host;
	// This Host owns the locator advertised in handoff gives. The directory
	// relays that signed locator claim; it does not replace it with registration input.
	if (transport === TRANSPORT_WEBRTC) {
		host.setAdvertisedLocator({
			transport,
			designator: host.designator(),
			hints: new Map(),
			hintWireForm: "map",
		});
	}
	page.reachable.inboxOwner = { host, publisher: inboxPublisher(host), iceServers };
	page.reachable.saidRendezvousTrouble = false;
	// Being reachable ourselves takes only the advertised transport's half: a
	// rendezvous registration holds sockets at the relay, a webrtc member
	// answers offers on the directory session instead (`advertisePresence`).
	if (transport === TRANSPORT_NOISE_RELAY) startHostRendezvous(page, host);
	return host;
}

function startHostRendezvous(page: RoomsPageContext, host: Host): void {
	if (page.reachable.rendezvous !== null) return;
	const projection = page.projection;
	page.reachable.rendezvous = serveRendezvous(host, TRANSPORT_NOISE_RELAY, {
		registerUrl: relayRegisterUrl,
		relayUrl: pageSocketBase("/relay"),
	}, {
		onError: (err) => {
			trouble(projection, "the relay would not take this tab's rendezvous registration", err);
			// Said once, not per attempt: the pool keeps trying with a backoff,
			// so an error here is a stretch of trouble rather than an end, and a
			// line each time would bury the conversation it is about. Said at
			// all because this is how a reader on the relay transport is
			// reachable — the directory will go on listing them as reachable
			// while nothing can land, and nobody on either side would learn why.
			if (page.reachable.saidRendezvousTrouble) return;
			// Latched only when a conversation was there to hear it: this fires
			// most readily while the join card is still up, where delivering
			// into the active conversation reaches nobody — and a latch set
			// then guaranteed the warning was never said at all.
			page.reachable.saidRendezvousTrouble = store.deliverActive(
				projection,
				store.sysItem(
					projection,
					`The relay would not take this tab's registration (${reason(err)}). ` +
						"Others may not be able to reach you directly until it does. It keeps trying.",
				),
			);
		},
	});
}

/** Keep relay rendezvous registered when DMs (and therefore a hosted session)
 * use `noise-relay`. WebRTC DMs already file signaling on the directory. */
export async function ensureHostRendezvous(page: RoomsPageContext): Promise<string> {
	const owner = page.reachable.inboxOwner;
	if (owner === null) throw new Error("rooms inbox Runtime is not open");
	startHostRendezvous(page, owner.host);
	const handle = page.reachable.rendezvous;
	if (handle === null) throw new Error("this tab has no relay rendezvous");
	await handle.ready();
	return formatLocatorUri(handle.locator);
}

/** This window's direct-message locator, the URI a peer would redeem. */
export function selfLocator(page: RoomsPageContext): string | null {
	if (page.reachable.inboxOwner === null) return null;
	if (dmTransport() === TRANSPORT_NOISE_RELAY && page.reachable.rendezvous !== null) {
		return formatLocatorUri(page.reachable.rendezvous.locator);
	}
	return formatPeerUri(dmTransport(), page.reachable.inboxOwner.host.designator());
}

/** The locator a session sturdyref names: the same door DMs already advertise,
 * plus the directory that filed this tab's WebRTC answering inbox. */
export function sessionHostLocator(page: RoomsPageContext): string | null {
	const advertised = selfLocator(page);
	if (advertised == null) return null;
	if (dmTransport() !== TRANSPORT_WEBRTC) return advertised;
	const directory = page.bootstrap.homeDirectoryLocator;
	if (directory == null || directory === "") return advertised;
	const loc = roomsLocator(advertised);
	return formatLocatorUri({
		transport: loc.transport,
		designator: loc.designator,
		hints: new Map([[WEBRTC_SIGNALING_DIRECTORY_HINT, directory]]),
		hintWireForm: "map",
	});
}

// Advertise our inbox host's direct-message locator to the directory so we appear
// in the DM-able roster and a peer can introduce+redeem us. Registered once per
// nick on the current directory session; a reconnect re-advertises because the
// new directory has no memory of the old introduction.
export function advertisePresence(session: Live): void {
	const page = session.page;
	const projection = page.projection;
	const nick = store.dirNick(projection, session.id);
	const owner = session.page.reachable.inboxOwner;
	if (owner === null || !nick) return;
	if (session.advertised === nick) return;
	session.advertised = nick;
	const host = owner.host;
	const locator = selfLocator(session.page);
	if (locator === null) return;
	session.dir.register(
		nick,
		locator,
		(peer, registrationId) => offerInboxFor(session, peer, registrationId),
		(peer, registrationId) => {
			offerInboxFor(session, peer, registrationId);
			establishRequestedDirect(session.page, session.id, peer, registrationId);
		},
	)
		.then(() => {
			// The session may have died while the room was answering it; a dead one
			// has nothing to flush and nothing to remember.
			if (!isCurrent(session) && !session.keepTransport) return;
			session.registered = true;
			// Share keeps the stolen session. Hosted re-register withdraws this
			// intro and files the inbox Attach looks up. A second file here races
			// that replace and can leave the directory holding a dead answerer.
			if (session.keepTransport) return;
			// Reachable again, which a reader who was told otherwise needs to see
			// as plainly as they were told the bad news.
			store.setDmUnreachable(projection, session.id, "");
			// A webrtc member is reached by signaling, so the inbox that answers
			// offers must be filed once the name is granted — and again after a
			// reconnect, because it lives on the directory session.
			if (dmTransport() === TRANSPORT_WEBRTC) {
				void serveWebrtcSignaling({
					host,
					dir: () => (isCurrent(session) ? session.dir : null),
					iceServers: owner.iceServers,
					onError: (err) => trouble(projection, "WebRTC signaling errored", err),
				}).then((signaling) => {
					if (!isCurrent(session) && !session.keepTransport) {
						void signaling.close();
						return;
					}
					// A re-register on the same session — a nick suffix retry — runs
					// this again. Close the one it replaces, or its accept loop,
					// peers map, and exported inbox stay live for the tab's life.
					void session.signaling?.close();
					session.signaling = signaling;
				}).catch((err) => {
					// With no signaling answerer, browser-to-browser direct
					// messages toward this tab cannot open, while every roster
					// goes on listing it as reachable. Said on the surface built
					// for exactly this registration, not only to the console.
					if (!isCurrent(session)) return;
					store.setDmUnreachable(
						projection,
						session.id,
						`this tab could not answer WebRTC direct messages: ${reason(err)}`,
					);
					store.deliverActive(
						projection,
						store.sysItem(
							projection,
							`Nobody can reach you for direct messages here: this tab could not answer WebRTC ` +
								`signaling (${reason(err)}).`,
						),
					);
				});
			}
			flushDeferredOffers(session);
		})
		.catch((err) => {
			if (!isCurrent(session) || session.advertised !== nick) return;
			session.advertised = null;
			// Retry rather than wait for a later join. The usual failure is a
			// name the room still holds for a session it has not reaped, which
			// clears on its own in a moment — and until this, nothing tried
			// again unless the member happened to change rooms. A registration
			// lost that way leaves them in everyone else's roster with no way
			// to be reached, permanently, and nothing anywhere says so.
			//
			// Bounded, because a name somebody else genuinely holds is not
			// transient and retrying at it forever would be a busy wait against
			// a fact that is not going to change.
			if (session.advertiseRetries <= 0) {
				trouble(projection, "could not advertise for direct messages", err);
				// And said where a reader can see it. This window stays in every
				// roster on this directory looking perfectly ordinary while no
				// direct message can arrive, and the person who cannot reach them
				// is told only that they are offline — so nobody involved learns
				// what is actually wrong unless this says it.
				const held = roomErrorOf(err)?.code === NICK_TAKEN;
				const why = held
					? `the name "${nick}" is registered to somebody else here, so nobody can reach you for direct messages`
					: `this directory would not register you for direct messages: ${reason(err)}`;
				store.setDmUnreachable(projection, session.id, why);
				const said = held
					? `Nobody can reach you for direct messages here: the name "${nick}" is registered to somebody ` +
						`else on this directory. Joining again under another name would fix it.`
					: `Nobody can reach you for direct messages here: ${reason(err)}`;
				const on = store.convsOn(projection, session.id).find((conv) => conv.type === "room");
				if (on !== undefined) store.deliver(projection, on.key, store.sysItem(projection, said));
				return;
			}
			session.advertiseRetries -= 1;
			globalThis.setTimeout(() => {
				if (!isCurrent(session)) return;
				advertisePresence(session);
			}, ADVERTISE_RETRY_MS);
		});
}

/** How long to wait before re-advertising a lost registration. Long enough for
 * the room to reap the session still holding the name, short enough that a
 * member is not sitting unreachable while they read the roster. */
const ADVERTISE_RETRY_MS = 1_500;

/** How many times to try. The transient case clears within a few seconds; past
 * that the name is somebody else's and waiting will not change it. */
export const ADVERTISE_RETRY_LIMIT = 4;

// Same-origin ws(s) URL for a relay endpoint, matching the page's scheme: an
// https page (a forwarded or deployed origin) must use `wss://`, or the browser
// blocks the insecure socket as mixed content. Every dial the wasm peer makes
// rides one of these to the page's own server, which relays the opaque bytes.
function pageSocketUrl(path: string, param: string, value: string): string {
	return `${pageSocketBase(path)}?${param}=${encodeURIComponent(value)}`;
}

function pageSocketBase(path: string): string {
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${location.host}${path}`;
}

// A dial rides `/relay?target=<locator>`: the room dial names a `host:port`
// (TCP), a member dial names an `ocapn://…iroh` URI, and serve.ts dials whichever.
// A cold-dial to a registered peer is a bridge, not a dial, so it has its own
// endpoint — `/relay?rendezvous=<id>`. The explicit relay Connector uses the
// locator's route hint, then bridges onto the inbound socket we hold by
// registering at `/register?id=<id>` through `serveRendezvous`.
export const relayLocatorUrl = (locator: string) => pageSocketUrl("/relay", "target", locator);
// A `host:port` is just a tcp dial target: reuse the one endpoint spelling so a
// later rename touches one line, not two.
export const relayWsUrl = (host: string, port: number) => relayLocatorUrl(`${host}:${port}`);
const relayRegisterUrl = (id: string) => pageSocketUrl("/register", "id", id);

// Our own room lines painted optimistically and awaiting the room's echo. The room
// echoes every post back to every member, so we paint ours at once as "sending" and
// reconcile it to confirmed when its echo arrives, rather than waiting on a round trip
// or eating a dropped send silently. Matched FIFO by text.

/** Re-send a line whose bubble's explicit retry control was pressed.
 *
 * The line is still in its conversation, so this reads it back rather than
 * holding a closure per outgoing send. Those closures had no owner: one was
 * added per line and dropped only when that line confirmed, so a line that
 * failed and was never retried kept its closure for the life of the tab, and
 * closing a conversation threw away the history while its closures stayed. A
 * conversation that is gone now simply has nothing to re-send. */
export function retrySend(page: RoomsPageContext, key: string, id: number): void {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	const item = store.historyOf(projection, key).find((line) => line.id === id);
	if (!conv || item?.kind !== "chat") return;
	// A message carrying files is retried by sending the files again. Re-posting
	// its caption would clear the failure while the room showed everyone a bare
	// line and our own bubble still drew an attachment nobody had.
	if (item.attachments !== undefined) {
		if (convSession(page, key)?.outgoing.has(id)) resendFile(page, key, id);
		else {
			// The file itself is gone — a reconnect took the session that held
			// it. Say so, because a press that quietly does nothing reads as a
			// broken control rather than as a file that has to be picked again.
			store.deliverActive(
				projection,
				store.sysItem(
					projection,
					"These files are no longer held by this tab. Attach them again to send this message.",
				),
			);
		}
		return;
	}
	if (conv.type === "room") resendRoomLine(page, key, id, item.text);
	else sendDm(page, key, id, item.text);
}
