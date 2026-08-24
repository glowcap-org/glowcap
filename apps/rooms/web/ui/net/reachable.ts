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

import { serveRendezvous } from "@pancake/web";
import type { RendezvousHandle, WebRuntime } from "@pancake/web";
import {
	annotateSession,
	type Argument,
	currentSession,
	formatLocatorUri,
	formatPeerUri,
	type Host,
	Ref,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_WEBRTC,
} from "@pancake/runtime";
import { serveWebrtcSignaling } from "../../../lib/signaling.ts";
import type { IceServer } from "../../../lib/ice.ts";
import { readAttachments } from "../../../lib/attachment.ts";
import { type InboxOfferer, type InboxPublisher, inboxPublisher } from "../../../lib/dm_inbox.ts";
import { DM, HAND_ROOM, OFFER_ROOM, TYPING } from "../../../lib/protocol.ts";
import { NICK_TAKEN, roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import * as prefs from "../prefs.ts";
import type { DirId } from "../types.ts";
import { reason, trouble } from "./common.ts";
import { convSession, dirSession, isCurrent, type Live } from "./live.ts";
import { applyTyping } from "./typing.ts";
import {
	adoptBackChannel,
	handedRoom,
	noteIgnoredDm,
	offeredRoom,
	receiveDm,
	releaseIncomingRef,
	sendDm,
} from "./direct.ts";
import { resendFile, resendRoomLine } from "./send.ts";
import { hydrateDm } from "./history.ts";

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
const DM_TRANSPORT = prefs.dmTransport();
let inboxOwner: {
	host: Host;
	publisher: InboxPublisher;
	iceServers: () => Promise<IceServer[]>;
} | null = null;
// Each directory's peer-to-alias mapping, homed with the Host its giftables live
// on rather than with any one connection. The publisher in `inboxOwner` owns the
// one process-wide alias ledger; these rows only preserve directory identity
// across reconnects and leave when the directory itself is left.
const offerers = new Map<DirId, InboxOfferer>();
let rendezvous: RendezvousHandle | null = null;
// Reply back-channels a peer handed us with an incoming DM: the connection the
// message arrived on plus the reply capability it carried. Our own reply rides
// this arriving connection (`currentSession`, ADR-0088) — the only way to answer
// a peer that opened no listener — rather than cold-dialing them back.
//
// Keyed on the conversation, not the nick. A route reaches one connection, and a
// nick is a claim the room hands back: keyed by name, closing a stale
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
function inboxFor(dir: DirId, peer: string): (verb: string, args: unknown[]) => Argument {
	return (verb: string, args: unknown[]): Argument => {
		const home = dirSession(dir);
		// The ephemeral sibling of a message: the peer's typing flag,
		// same auto-clear rule as a room's.
		if (verb === TYPING) {
			const conv = store.ensureDm(dir, peer);
			if (conv === null) return null;
			hydrateDm(conv);
			applyTyping(conv.key, peer, args[0] === true);
			return null;
		}
		if (verb === HAND_ROOM) {
			const label = typeof args[0] === "string" ? args[0] : "";
			const room = args[1];
			if (!(room instanceof Ref)) return null;
			const arriving = currentSession();
			if (arriving === null) {
				throw new Error("a handed room is reachable only during its arriving session turn");
			}
			// Between connections to this directory there is nobody to file the
			// offer under, so it is refused loudly and the reference handed back on
			// the connection it arrived over rather than parked unspendably.
			if (home === null) {
				releaseIncomingRef(arriving, room, "refused room offer");
				throw new Error("they are between connections; ask again in a moment");
			}
			// Thrown rather than swallowed when the offer cannot be kept, so the
			// sender's send rejects and their screen tells the truth — a quiet
			// decline here would leave them believing it arrived.
			if (!handedRoom(home, arriving, label, room, peer)) {
				throw new Error("their offers list is full; ask again once they have answered some");
			}
			return null;
		}
		if (verb === OFFER_ROOM) {
			const label = typeof args[0] === "string" ? args[0] : "";
			const link = typeof args[1] === "string" ? args[1] : "";
			if (link === "") return null;
			if (home === null) throw new Error("they are between connections; ask again in a moment");
			// The same loud refusal as a handed room: a sender told "delivered"
			// about an offer this side let go is being lied to.
			if (!offeredRoom(home, label, link, peer)) {
				throw new Error("their offers list is full; ask again once they have answered some");
			}
			return null;
		}
		if (verb !== DM) throw new Error(`dm inbox has no method ${verb}`);
		const text = typeof args[0] === "string" ? args[0] : "";
		const reply = args[1];
		const attachments = readAttachments(args as Argument[], reply instanceof Ref ? 2 : 1);
		// The arriving connection has to be read inside the turn; it is null once
		// the turn returns, and our reply sends on a later one.
		const conv = store.ensureDm(dir, peer);
		if (conv === null) return null;
		hydrateDm(conv);
		const key = conv.key;
		noteIgnoredDm(key, peer);
		const session = currentSession();
		// Name the arriving direct connection for whoever is watching the live
		// timeline. The dialer names it too, from the other end; either end's
		// annotation is enough, and a watcher only ever hears the one whose
		// view of this wire it is being shown.
		if (session !== null) annotateSession(session, { label: peer });
		if (session !== null && reply instanceof Ref) {
			const adopted = home !== null && adoptBackChannel(key, session, reply);
			// Every projected capability occurrence owns a retain. A duplicate reply
			// route, or one arriving while its directory is down, is not adopted and
			// must be handed back rather than falling out of the callback unowned.
			if (!adopted) releaseIncomingRef(session, reply, "unused direct reply route");
		}
		// Answer the sender the handle to this line, so a later edit or withdrawal
		// reaches it. A message we will not show, or one with no connection to host
		// a handle on, answers nothing and simply cannot be changed.
		return receiveDm(key, peer, text, attachments, session);
	};
}

// Mint and offer one inbox per peer, on the inbox host so a redeem dial finds
// it. One offerer per directory: an inbox is offered *to* a nickname, and a
// nickname belongs to the directory that granted it, so two directories offering
// under the same name are offering to two different people. The offerer follows
// the giftables it counts — the inbox Host, which survives reconnects — so a
// reconnect re-offers the same inboxes rather than minting a second set (see
// `offerers`).
export function ensureOfferer(dir: DirId): InboxOfferer {
	const held = offerers.get(dir);
	if (held !== undefined) return held;
	const offerer = requireInboxPublisher().offerer({
		dir: () => dirSession(dir)?.dir ?? null,
		behaviorFor: (peer) => inboxFor(dir, peer),
		skip: (peer) => store.isSelf(dir, peer),
		// That one person's direct messages toward this tab will not arrive,
		// and they are told only that the send failed — so this side says which
		// offer broke, where the reader can see it.
		onError: (peer, err) =>
			store.deliverActive(store.sysItem(
				`Could not prepare a direct-message inbox for ${peer}: ${reason(err)}. ` +
					`Their messages to you may not arrive.`,
			)),
	});
	offerers.set(dir, offerer);
	return offerer;
}

/** Retire one directory's aliases without resetting the Host-wide ledger that
 * bounds every directory together. */
export function forgetOfferer(dir: DirId): void {
	const held = offerers.get(dir);
	offerers.delete(dir);
	void held?.close();
}

// Peers to offer an inbox to as soon as our own registration is acknowledged.
// The gate below is real — an offer sent before the directory has granted us a
// name is refused, so publishing before that answer only creates authority the
// offerer must retire. Dropping the request also loses it: `mintInboxFor`
// dispatches synchronously
// inside the inbound feed while the acknowledgement lands on a microtask, so the
// first peer to ask arrives before the flag does.

export function offerInboxFor(home: Live, peer: string): void {
	if (!home.registered) {
		home.deferredOffers.add(peer);
		return;
	}
	ensureOfferer(home.id).offer(peer);
}

function flushDeferredOffers(home: Live): void {
	const waiting = [...home.deferredOffers];
	home.deferredOffers.clear();
	for (const peer of waiting) offerInboxFor(home, peer);
}

// What publishes the giftables an offer is made of. Reaching it before the inbox
// Runtime is open is a caller mistake rather than a state to handle, so it says
// so instead of answering null.
function requireInboxPublisher(): InboxPublisher {
	if (inboxOwner === null) throw new Error("rooms inbox Runtime is not open");
	return inboxOwner.publisher;
}

// Create the inbox host once and start serving cold-dials against it. Idempotent
// across reconnects so our identity, held registrations, and open cold-dial
// lines survive a room-server respawn.
export function ensureInbox(runtime: WebRuntime, iceServers: () => Promise<IceServer[]>): Host {
	if (inboxOwner !== null) return inboxOwner.host;
	const host = runtime.host;
	// This Host owns the locator advertised in handoff gives. The directory
	// relays that signed claim; it does not replace it with registration input.
	if (DM_TRANSPORT === TRANSPORT_WEBRTC) {
		host.setAdvertisedLocator({
			transport: DM_TRANSPORT,
			designator: host.designator(),
			hints: new Map(),
			hintWireForm: "map",
		});
	}
	inboxOwner = { host, publisher: inboxPublisher(host), iceServers };
	saidRendezvousTrouble = false;
	// Being reachable ourselves takes only the advertised transport's half: a
	// rendezvous registration holds sockets at the relay, a webrtc member
	// answers offers on the directory session instead (`advertisePresence`).
	if (DM_TRANSPORT === TRANSPORT_NOISE_RELAY) {
		rendezvous = serveRendezvous(host, DM_TRANSPORT, {
			registerUrl: relayRegisterUrl,
			relayUrl: pageSocketBase("/relay"),
		}, {
			onError: (err) => {
				trouble("the relay would not take this tab's rendezvous registration", err);
				// Said once, not per attempt: the pool keeps trying with a backoff,
				// so an error here is a stretch of trouble rather than an end, and a
				// line each time would bury the conversation it is about. Said at
				// all because this is how a reader on the relay transport is
				// reachable — the directory will go on listing them as reachable
				// while nothing can land, and nobody on either side would learn why.
				if (saidRendezvousTrouble) return;
				// Latched only when a conversation was there to hear it: this fires
				// most readily while the join card is still up, where delivering
				// into the active conversation reaches nobody — and a latch set
				// then guaranteed the warning was never said at all.
				saidRendezvousTrouble = store.deliverActive(store.sysItem(
					`The relay would not take this tab's registration (${reason(err)}). ` +
						"Others may not be able to reach you directly until it does; it keeps trying.",
				));
			},
		});
	}
	return host;
}

// Whether this tab has already said that the relay is not taking its
// registration. One inbox host, one telling.
let saidRendezvousTrouble = false;

/** This window's direct-message locator, the URI a peer would redeem. */
export function selfLocator(): string | null {
	if (inboxOwner === null) return null;
	return rendezvous === null
		? formatPeerUri(DM_TRANSPORT, inboxOwner.host.designator())
		: formatLocatorUri(rendezvous.locator);
}

// Advertise our inbox host's direct-message locator to the directory so we appear
// in the DM-able roster and a peer can introduce+redeem us. Registered once per
// nick on the current directory session; a reconnect re-advertises because the
// new directory has no memory of the old introduction.
export function advertisePresence(session: Live): void {
	const nick = store.dirNick(session.id);
	const owner = inboxOwner;
	if (owner === null || !nick) return;
	if (session.advertised === nick) return;
	session.advertised = nick;
	const host = owner.host;
	const locator = selfLocator();
	if (locator === null) return;
	session.dir.register(nick, locator, (peer) => offerInboxFor(session, peer))
		.then(() => {
			// The session may have died while the room was answering it; a dead one
			// has nothing to flush and nothing to remember.
			if (!isCurrent(session)) return;
			session.registered = true;
			// Reachable again, which a reader who was told otherwise needs to see
			// as plainly as they were told the bad news.
			store.setDmUnreachable(session.id, "");
			// A webrtc member is reached by signaling, so the inbox that answers
			// offers must be filed once the name is granted — and again after a
			// reconnect, because it lives on the directory session.
			if (DM_TRANSPORT === TRANSPORT_WEBRTC) {
				void serveWebrtcSignaling({
					host,
					dir: () => (isCurrent(session) ? session.dir : null),
					iceServers: owner.iceServers,
					onError: (err) => trouble("WebRTC signaling errored", err),
				}).then((signaling) => {
					if (!isCurrent(session)) {
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
					// for exactly this claim, not only to the console.
					if (!isCurrent(session)) return;
					store.setDmUnreachable(
						session.id,
						`this tab could not answer WebRTC direct messages: ${reason(err)}`,
					);
					store.deliverActive(store.sysItem(
						`Nobody can reach you for direct messages here: this tab could not answer WebRTC ` +
							`signaling (${reason(err)}).`,
					));
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
				trouble("could not advertise for direct messages", err);
				// And said where a reader can see it. This window stays in every
				// roster on this directory looking perfectly ordinary while no
				// direct message can arrive, and the person who cannot reach them
				// is told only that they are offline — so nobody involved learns
				// what is actually wrong unless this says it.
				const held = roomErrorOf(err)?.code === NICK_TAKEN;
				const why = held
					? `the name "${nick}" is registered to somebody else here, so nobody can reach you for direct messages`
					: `this directory would not register you for direct messages: ${reason(err)}`;
				store.setDmUnreachable(session.id, why);
				const said = held
					? `Nobody can reach you for direct messages here: the name "${nick}" is registered to somebody ` +
						`else on this directory. Joining again under another name would fix it.`
					: `Nobody can reach you for direct messages here: ${reason(err)}`;
				const on = store.convsOn(session.id).find((conv) => conv.type === "room");
				if (on !== undefined) store.deliver(on.key, store.sysItem(said));
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
export function retrySend(key: string, id: number): void {
	const conv = store.getConv(key);
	const item = conv?.history.find((line) => line.id === id);
	if (!conv || item?.kind !== "chat") return;
	// A message carrying files is retried by sending the files again. Re-posting
	// its caption would clear the failure while the room showed everyone a bare
	// line and our own bubble still drew an attachment nobody had.
	if (item.attachments !== undefined) {
		if (convSession(key)?.outgoing.has(id)) resendFile(key, id);
		else {
			// The file itself is gone — a reconnect took the session that held
			// it. Say so, because a press that quietly does nothing reads as a
			// broken control rather than as a file that has to be picked again.
			store.deliverActive(
				store.sysItem("These files are no longer held by this tab; attach them again to send this message."),
			);
		}
		return;
	}
	if (conv.type === "room") resendRoomLine(key, id, item.text);
	else sendDm(key, id, item.text);
}

/** Move one of our own lines between sending, failed, and confirmed. */

// End our rendezvous registration when the tab goes away. The relay reclaims a
// dropped socket on its own (its idle ping/pong), so this is a courtesy close,
// not a correctness requirement; a browser is a rendezvous, not a mailbox.
globalThis.addEventListener("beforeunload", () => {
	rendezvous?.stop();
});
