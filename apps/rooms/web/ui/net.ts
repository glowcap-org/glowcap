// The rooms page's data layer, as a real OCapN peer in the browser. The page
// instantiates the pancake stack over `@pancake/web` (the wasm Host, no dlopen),
// dials the room server through serve.ts's `/relay` byte pipe, and drives the
// directory and room as capabilities — the same `lib/room_client.ts` the
// terminal clients use. No JSON bridge: the browser holds the room capability
// itself.
//
// Direct messages work by introduction. The browser asks the directory to
// introduce it to a member, redeems the handoff-give by dialing that member
// through the relay's `?locator=` iroh path, and messages them straight over
// that direct line, with the room never on the message path — the same
// three-party handoff `demo-rooms-dm-iroh` proves, driven from a browser tab.
// The relay dials any iroh node but pins TCP to the room server, so a member
// reachable only over TCP surfaces an honest "couldn't reach directly" rather
// than a fake send. The other direction — a member dialing a browser first —
// still waits on browser reachability, so a browser opens the line by sending.
//
// Nothing here draws anything. It reads and writes the store, and the interface
// is a function of the store; this file imports no component and touches no
// element. That is also why the peer survives anything React does: the session
// is owned here, at module scope, so a remount, a StrictMode double-pass, or an
// error boundary catching a render never disturbs a live conversation.

import { init, type RendezvousHandle, serveRendezvous } from "@pancake/web";
import {
	annotateSession,
	currentSession,
	enableTrace,
	formatPeerUri,
	Host,
	Ref,
	type Session,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_WEBRTC,
} from "@pancake/stack";
import { publishViz, type VizPublisher } from "../../lib/viz_publish.ts";
import { directorySignalingAuthority, serveWebrtcSignaling } from "../../lib/signaling.ts";
import { MAX_LINE, MAX_NICK, TYPING_CLEAR_MS } from "../../lib/limits.ts";
import { DirectMessage, Directory, Room } from "../../lib/room_client.ts";
import { type InboxOfferer, inboxOfferer } from "../../lib/dm_inbox.ts";
import { DM, TYPING } from "../../lib/protocol.ts";
import { enterOrOpen } from "../../lib/enter_room.ts";
import { dial, roomsHost } from "../../lib/locator.ts";
import { NICK_TAKEN, PEER_OFFLINE, roomErrorOf } from "../../lib/errors.ts";
import type { DmConv } from "./types.ts";
import * as store from "./store.ts";
import { maybeNotify } from "./notify.ts";
import { mentionsYou, tooLong } from "./text.ts";

/** Everything that belongs to one directory session, and nothing that outlives
 * one.
 *
 * The page has two lifetimes and they are easy to confuse. A directory session
 * dies whenever the room server restarts, and everything it was holding dies
 * with it: the room it had us in, the direct lines redeemed over it, the name it
 * advertised. What is reachable *about us* does not — a cold-dial line is
 * browser-to-browser through the relay, so a room respawn must not disturb it —
 * and that state stays in module scope below.
 *
 * Both used to be module scope, and which was which lived in one place: a list
 * inside the disconnect handler, of everything to put back. A field added
 * without a line added there is a value that survives a reconnect it has no
 * business surviving, on the path hardest to exercise. Here the session is one
 * object, and ending it is dropping the object; what is left to do by hand is
 * only what has to be *released*, which is a shorter and more obvious list. */
interface Live {
	readonly dir: Directory;
	/** The room this session has us in, which is not always the one on screen. */
	room: Room | null;
	/** Introduced direct lines, by conversation. One introduction each: the first
	 * send opens it, later sends reuse it, and a failed open is dropped so the
	 * next send retries. */
	lines: Map<string, Promise<DirectMessage>>;
	/** Reply routes a peer handed us with an incoming message, by conversation. */
	backChannels: Map<string, { session: Session; reply: Ref }>;
	/** Our own room lines painted and awaiting the room's echo. */
	echoes: { key: string; id: number; text: string }[];
	/** Attempts left to re-advertise a registration this session lost. */
	advertiseRetries: number;
	/** The nick this session advertised a locator for, so we register once per
	 * name rather than on every room switch. */
	advertised: string | null;
	/** Whether that registration has been acknowledged, which is when we may
	 * offer inboxes. */
	registered: boolean;
	/** Peers to offer an inbox to as soon as it is. */
	deferredOffers: Set<string>;
	/** Fires once this session has lasted long enough to count as stable. */
	stable: ReturnType<typeof setTimeout> | null;
}
let live: Live | null = null;

let userPickedRoom = false; // set when the user taps a room, so entering switches to it
let stackReady: Promise<unknown> | null = null;
let pumpToken = 0; // bumped on each room switch so a stale pump stops delivering
let backoff = 500;
// A session must survive this long before its handshake counts as a stable
// connection worth resetting the backoff to 500. Below it, a server that accepts
// then drops keeps the exponential backoff climbing instead of storming.
const BACKOFF_STABLE_MS = 10_000;
// The longest we wait between attempts. A room server being restarted is back in
// seconds, so a slower retry than this only makes the page look dead when it is
// not.
const BACKOFF_CEILING_MS = 5_000;
let everConnected = false;

/** Settles when the directory has answered with its first list of rooms.
 *
 * The rail waits on this before it says anything about which rooms exist,
 * because "no rooms" and "we have not asked yet" are different facts and only
 * one of them is ever true at load. It settles once and is never replaced, so a
 * later reconnect leaves the last known list on screen instead of blanking it. */
let announceDirectory: () => void = () => {};
export const directoryReady: Promise<void> = new Promise((resolve) => {
	announceDirectory = resolve;
});

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
// Each of those inboxes is permanent — nothing withdraws a giftable — so the tab
// accumulates one per member it has seen, up to `MAX_DM_INBOXES`, which the
// offerer holds for us.
//
// Which transport this tab advertises for direct messages: the relay
// rendezvous identity by default, or a `webrtc` identity when the page is
// opened with `?dm=webrtc` — the DataChannel then carries the DM directly and
// the room directory carries only the signaling (ADR-0089).
const DM_TRANSPORT: typeof TRANSPORT_KEYED_RELAY | typeof TRANSPORT_WEBRTC =
	new URLSearchParams(location.search).get("dm") === "webrtc"
		? TRANSPORT_WEBRTC
		: TRANSPORT_KEYED_RELAY;
// The live timeline endpoint this tab publishes its own trace to. The page
// asks its own server for one (`/viz`, answered when the room was started with
// ROOMS_VIZ_PORT), and `?viz=ws://host:port/` on the page URL overrides that
// for a run where the endpoint is somewhere else. Off by default: with no
// endpoint the tap is never installed and the host's emit sites are one null
// check.
//
// This is the only way a direct message becomes visible. A DM is a session
// between two members, held on the members' own hosts, so the room server sees
// none of it and must not start seeing it. What travels to the endpoint is
// telemetry on a one-way socket; the conversation stays direct.
const VIZ_OVERRIDE = new URLSearchParams(location.search).get("viz");
let inboxHost: Host | null = null;
let vizPublisher: VizPublisher | null = null;

// Ask the page's own server where the live timeline endpoint is. A run without
// one answers 404, and this tab then publishes nothing.
async function vizEndpoint(): Promise<string | null> {
	if (VIZ_OVERRIDE !== null) return VIZ_OVERRIDE;
	try {
		const res = await fetch("/viz");
		if (!res.ok) {
			await res.body?.cancel();
			return null;
		}
		const port = (await res.text()).trim();
		if (!/^[0-9]+$/.test(port)) return null;
		const proto = location.protocol === "https:" ? "wss://" : "ws://";
		return `${proto}${location.hostname}:${port}/`;
	} catch {
		return null;
	}
}

// Install the tap, once, before the first host exists so its very first
// session open is captured. A run with no endpoint answers 404 and this is
// asked again on the next reconnect, so a room that gains one is picked up
// rather than decided against for the tab's life.
async function ensureVizPublisher(): Promise<void> {
	if (vizPublisher !== null) return;
	const url = await vizEndpoint();
	if (url === null) return;
	vizPublisher = publishViz(url, {
		onError: (err) => console.error("rooms: viz publish error:", reason(err)),
	});
	enableTrace(vizPublisher.sink);
}
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
function inboxFor(peer: string): (verb: string, args: unknown[]) => null {
	return (verb: string, args: unknown[]): null => {
		// The ephemeral sibling of a message: the peer's typing flag,
		// same auto-clear rule as a room's.
		if (verb === TYPING) {
			applyTyping(store.ensureDm(peer).key, peer, args[0] === true);
			return null;
		}
		if (verb !== DM) throw new Error(`dm inbox has no method ${verb}`);
		const text = typeof args[0] === "string" ? args[0] : "";
		const reply = args[1];
		// The arriving connection has to be read inside the turn; it is null once
		// the turn returns, and our reply sends on a later one.
		const key = store.ensureDm(peer).key;
		const session = currentSession();
		// Name the arriving direct connection for whoever is watching the live
		// timeline. The dialer names it too, from the other end; either end's
		// annotation is enough, and a watcher only ever hears the one whose
		// view of this wire it is being shown.
		if (session !== null) annotateSession(session, { label: peer });
		if (live !== null && session !== null && reply instanceof Ref) {
			const held = live.backChannels.get(key);
			// A working route is not displaced: this peer may open a second
			// connection while the first still carries our replies.
			if (held === undefined || !held.session.sessionOpen) {
				live.backChannels.set(key, { session, reply });
			}
		}
		receiveDm(key, peer, text);
		return null;
	};
}

// Mint and offer one inbox per peer, on the inbox host so a redeem dial finds it.
let offerer: InboxOfferer | null = null;

function ensureOfferer(): InboxOfferer {
	if (offerer) return offerer;
	offerer = inboxOfferer({
		host: ensureInbox(),
		dir: () => live?.dir ?? null,
		behaviorFor: inboxFor,
		skip: (peer) => peer.toLowerCase() === store.get().nick.toLowerCase(),
		onError: (peer, err) =>
			console.error(`rooms: could not offer an inbox for ${peer}:`, reason(err)),
	});
	return offerer;
}

// Peers to offer an inbox to as soon as our own registration is acknowledged.
// The gate below is real — an offer sent before the directory has granted us a
// name is refused, and the giftable it published stays published for nothing —
// but dropping the request loses it: `mintInboxFor` dispatches synchronously
// inside the inbound feed while the acknowledgement lands on a microtask, so the
// first peer to ask arrives before the flag does.

function offerInboxFor(peer: string): void {
	if (live === null) return;
	if (!live.registered) {
		live.deferredOffers.add(peer);
		return;
	}
	ensureOfferer().offer(peer);
}

function flushDeferredOffers(): void {
	if (live === null) return;
	const waiting = [...live.deferredOffers];
	live.deferredOffers.clear();
	for (const peer of waiting) offerInboxFor(peer);
}

// Create the inbox host once and start serving cold-dials against it. Idempotent
// across reconnects so our identity, held registrations, and open cold-dial
// lines survive a room-server respawn.
function ensureInbox(): Host {
	if (inboxHost) return inboxHost;
	const host = roomsHost();
	// This Host owns the locator advertised in handoff gives. The directory
	// relays that signed claim; it does not replace it with registration input.
	host.setAdvertisedLocator(DM_TRANSPORT, host.designator());
	// Reaching other members is this host's deployment configuration, whatever
	// we advertise ourselves: a `keyed-relay` identity bridges through
	// `/relay?rendezvous=` (ADR-0088), and a `webrtc` identity is signaled
	// through the room directory (ADR-0089).
	host.setRendezvousUrl(relayRendezvousUrl);
	host.setSignaling(directorySignalingAuthority(() => live?.dir ?? null));
	inboxHost = host;
	// Being reachable ourselves takes only the advertised transport's half: a
	// rendezvous registration holds sockets at the relay, a webrtc member
	// answers offers on the directory session instead (`advertisePresence`).
	if (DM_TRANSPORT === TRANSPORT_KEYED_RELAY) {
		rendezvous = serveRendezvous(host, relayRegisterUrl, {
			onError: (err) => console.error("rooms: rendezvous registration error:", reason(err)),
		});
	}
	return host;
}

// Advertise our inbox host's keyed-relay locator to the directory so we appear
// in the DM-able roster and a peer can introduce+redeem us. Registered once per
// nick on the current directory session; a reconnect re-advertises because the
// new directory has no memory of the old introduction.
function advertisePresence(): void {
	const nick = store.get().nick;
	const session = live;
	if (session === null || !inboxHost || !nick) return;
	if (session.advertised === nick) return;
	session.advertised = nick;
	const host = inboxHost;
	const locator = formatPeerUri(DM_TRANSPORT, host.designator());
	session.dir.register(nick, locator, offerInboxFor)
		.then(() => {
			// The session may have died while the room was answering it; a dead one
			// has nothing to flush and nothing to remember.
			if (live !== session) return;
			session.registered = true;
			// A webrtc member is reached by signaling, so the inbox that answers
			// offers must be filed once the name is granted — and again after a
			// reconnect, because it lives on the directory session.
			if (DM_TRANSPORT === TRANSPORT_WEBRTC) {
				void serveWebrtcSignaling({
					host,
					dir: () => live?.dir ?? null,
					onError: (err) => console.error("rooms: webrtc signaling error:", reason(err)),
				}).catch((err) => console.error("rooms: could not offer signaling:", reason(err)));
			}
			flushDeferredOffers();
		})
		.catch(() => {
			if (live !== session || session.advertised !== nick) return;
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
				console.error(
					"rooms: could not advertise for direct messages; others cannot reach you",
				);
				return;
			}
			session.advertiseRetries -= 1;
			globalThis.setTimeout(() => {
				if (live !== session) return;
				advertisePresence();
			}, ADVERTISE_RETRY_MS);
		});
}

/** How long to wait before re-advertising a lost registration. Long enough for
 * the room to reap the session still holding the name, short enough that a
 * member is not sitting unreachable while they read the roster. */
const ADVERTISE_RETRY_MS = 1_500;

/** How many times to try. The transient case clears within a few seconds; past
 * that the name is somebody else's and waiting will not change it. */
const ADVERTISE_RETRY_LIMIT = 4;

// Same-origin ws(s) URL for a relay endpoint, matching the page's scheme: an
// https page (a forwarded or deployed origin) must use `wss://`, or the browser
// blocks the insecure socket as mixed content. Every dial the wasm peer makes
// rides one of these to the page's own server, which relays the opaque bytes.
function pageSocketUrl(path: string, param: string, value: string): string {
	const proto = location.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${location.host}${path}?${param}=${encodeURIComponent(value)}`;
}

// A dial rides `/relay?target=<locator>`: the room dial names a `host:port`
// (TCP), a member dial names an `ocapn://…iroh` URI, and serve.ts dials whichever.
// A cold-dial to a registered peer is a bridge, not a dial, so it has its own
// endpoint — `/relay?rendezvous=<id>` (the redeem side, wired into the inbox
// host as `setRendezvousUrl`) bridges onto the inbound socket we *hold* by
// registering at `/register?id=<id>` (wired into `serveRendezvous`).
const relayLocatorUrl = (locator: string) => pageSocketUrl("/relay", "target", locator);
// A `host:port` is just a tcp dial target: reuse the one endpoint spelling so a
// later rename touches one line, not two.
const relayWsUrl = (host: string, port: number) => relayLocatorUrl(`${host}:${port}`);
const relayRendezvousUrl = (id: string) => pageSocketUrl("/relay", "rendezvous", id);
const relayRegisterUrl = (id: string) => pageSocketUrl("/register", "id", id);

function isConnected(): boolean {
	return live !== null;
}

// Our own room lines painted optimistically and awaiting the room's echo. The room
// echoes every post back to every member, so we paint ours at once as "sending" and
// reconcile it to confirmed when its echo arrives, rather than waiting on a round trip
// or eating a dropped send silently. Matched FIFO by text.

/** Re-send a line whose bubble is marked failed (a tap on it, or Enter/Space).
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
	if (conv.type === "room") resendRoomLine(key, id, item.text);
	else sendDm(key, id, item.text);
}

/** Move one of our own lines between sending, failed, and confirmed. */
function markSend(key: string, id: number, sendState: "sending" | "failed" | undefined): void {
	store.updateItem(key, id, { state: sendState });
}

// ── Sending ───────────────────────────────────────────────────────────────
/** Send whatever is in the composer to whatever is on screen. */
export function send(): void {
	const s = store.get();
	const text = s.draft.trim();
	const conv = store.activeConv();
	if (!text || !conv) return;
	if (!isConnected()) {
		store.deliverActive(store.sysItem("Not connected, your message was not sent"));
		return;
	}
	if (text.length > MAX_LINE) {
		store.deliverActive(store.sysItem(tooLong("Message", MAX_LINE)));
		return;
	}
	// A room echoes every post back to every member, which is what confirms our
	// own line. A direct message has no echo, so it is confirmed by the send
	// settling instead.
	if (conv.type === "room") sayLine(text);
	else dmSay(conv, text);
	store.setDraft("");
}

/** Put an @mention of `who` into the composer, from the toolbar on a message. */
export function mention(who: string): void {
	const draft = store.get().draft;
	const gap = draft && !/\s$/.test(draft) ? " " : "";
	store.setDraft(draft + gap + "@" + who + " ");
}

export function setDraft(text: string): void {
	store.setDraft(text);
}

/**
 * Say a line into the joined room. We paint our own line at once as "sending"; the room
 * echoes it back to every member, which confirms it (see `pump`). A rejected post marks
 * the line failed and tap-to-retry instead of vanishing.
 */
function sayLine(text: string): void {
	const joined = store.get().joinedRoom;
	if (!joined) return;
	const conv = store.ensureRoom(joined);
	const item = store.chatItem(store.get().nick, text, true, "sending");
	store.deliver(conv.key, item);
	live?.echoes.push({ key: conv.key, id: item.id, text });
	postRoomLine(item.id, text);
}

// Re-arm a failed line as "sending" and post it again. The line is already in the
// conversation, so this changes it in place rather than adding a fresh one.
function resendRoomLine(key: string, id: number, text: string): void {
	markSend(key, id, "sending");
	live?.echoes.push({ key, id, text });
	postRoomLine(id, text);
}

// Post a line to the joined room, marking it failed if there is no room or the post
// rejects. Success is silent: the room's echo confirms the line through `confirmRoomEcho`.
function postRoomLine(id: number, text: string): void {
	const room = live?.room;
	if (!room) {
		failRoomSend(id);
		return;
	}
	room.say(text).catch(() => failRoomSend(id));
}

// A room line that cannot be confirmed: drop it from the echo queue and tint it failed.
function failRoomSend(id: number): void {
	if (live === null) return;
	const at = live.echoes.findIndex((row) => row.id === id);
	// Already off the queue means the room echoed this line back and
	// `confirmRoomEcho` cleared it. A `say` that rejects afterwards is reporting
	// on a line the room demonstrably received, so tinting it failed here would
	// contradict the echo the user can see.
	if (at < 0) return;
	const [row] = live.echoes.splice(at, 1);
	markSend(row.key, row.id, "failed");
}

// The room echoed a line back to us. If it matches an optimistic send still in flight,
// confirm that line in place (clear its "sending" tint) and report that it is handled,
// so `pump` does not paint a second copy.
function confirmRoomEcho(text: string): boolean {
	if (live === null) return false;
	const at = live.echoes.findIndex((row) => row.text === text);
	if (at < 0) return false;
	const [row] = live.echoes.splice(at, 1);
	markSend(row.key, row.id, undefined);
	return true;
}

/** Set our typing flag in the active conversation — the room's own
 * channel for a room, the peer's inbox for a direct line. The one
 * failure here that is genuinely nothing: a typing flag is ephemeral
 * and self-correcting, because a reader clears an unrefreshed one
 * after `TYPING_CLEAR_MS` whatever we manage to send. */
export function setTyping(on: boolean): void {
	const s = store.get();
	const conv = s.activeKey !== null ? store.getConv(s.activeKey) : undefined;
	if (conv?.type === "dm") {
		sendDmTyping(conv.key, on);
		return;
	}
	live?.room?.setTyping(on).catch(() => {});
}

/** A typing flag rides only a route that already exists — the reply
 * capability the peer handed us, or an introduced line already open
 * (or opening). An ephemeral signal must never cause a dial. */
function sendDmTyping(key: string, on: boolean): void {
	const session = live;
	if (session === null) return;
	const back = session.backChannels.get(key);
	if (back !== undefined && back.session.sessionOpen) {
		back.session.tell(back.reply, TYPING, [on]).catch(() => {});
		return;
	}
	session.lines.get(key)?.then((line) => line.typing(on)).catch(() => {});
}

// ── Rooms: picking, creating, joining ─────────────────────────────────────
export function pickRoom(name: string): void {
	const s = store.get();
	if (s.joinedRoom && s.nick && live) {
		const key = store.roomKey(name);
		if (key === s.activeKey) {
			store.showRail(false);
			return;
		}
		if (s.convs.has(key) && name.toLowerCase() === s.joinedRoom.toLowerCase()) {
			store.switchTo(key);
		} else switchRoom(name);
		return;
	}
	// Not in a room yet, so this is a request to join that one. Fill the card in
	// and put it up: it used to only set the field, which worked while the card
	// happened to be showing and stranded a reader who had a direct message open,
	// because the field it filled was behind it.
	store.setDrafts({ draftRoom: name });
	store.showJoinCard();
}

function switchRoom(name: string): void {
	userPickedRoom = true;
	store.setStatus("entering #" + name + "…");
	void enterRoom(name, store.get().nick);
}

/// A join asked for before the peer session was open. The session is fetched,
/// instantiated, and handshaked after the page loads, and a returning visitor's
/// name is prefilled with the Join button focused — so pressing Enter inside
/// that window is the *common* first interaction, not an unusual one. The
/// request is held, and `openSession` replays it the moment it can.
let staged: { room: string; nick: string } | null = null;
let stagedSettle: ((message: string) => void) | null = null;

function settleStaged(message: string): void {
	const settle = stagedSettle;
	stagedSettle = null;
	settle?.(message);
}

/** Enter a room, settling with "" once we are in or with the reason we are not.
 *
 * A server that is merely unreachable does not settle it as a refusal and then
 * forget: the request stays staged and the next session that opens replays it. */
export function joinRoom(room: string, nick: string): Promise<string> {
	store.setNick(nick);
	store.setDrafts({ draftRoom: room });
	if (!isConnected()) {
		// One join is staged at a time, so anything still waiting is superseded by
		// this one and is let go rather than left pending on a card that has moved
		// on.
		settleStaged("");
		staged = { room, nick };
		store.setStatus("reaching the room server…");
		return new Promise<string>((resolve) => {
			stagedSettle = resolve;
		});
	}
	store.setStatus("entering #" + room + "…");
	return enterRoom(room, nick);
}

/** Leave the room without entering another one.
 *
 * A room is a capability and leaving it is telling the room so: the membership
 * is released, everyone else sees the departure, and the name frees up if we
 * were the last one in. The page returns to the card it opened with, which is
 * the only way back there in a window with no reload — a kiosk, an installed
 * app, a browser someone handed you. The directory session stays up, so the
 * live room list keeps arriving and rejoining is one click.
 */
export function leaveRoom(): void {
	const room = live?.room ?? null;
	if (live) live.room = null;
	const was = store.get().joinedRoom;
	// Read what is on screen before anything is cleared: a direct conversation
	// does not depend on the room that introduced it, so leaving the room while
	// reading one should leave you reading it, and only a reader who was in the
	// room itself needs somewhere to go.
	const readingDm = store.activeConv()?.type === "dm";
	store.setJoinedRoom(null);
	if (was !== null) store.forgetConv(store.roomKey(was));
	if (!readingDm) store.showJoinCard();
	store.setStatus(live ? "pick a room" : "not connected");
	// A leave that fails leaves the room still holding the nick, which the next
	// join will discover as a name already taken. Nothing here can fix it, but a
	// silent version of it is very hard to recognise later.
	if (room) {
		void room.leave().catch((err) =>
			console.error("rooms: could not leave the room:", reason(err))
		);
	}
}

/** The title's mark ends whatever it names: a room is left, a direct line is
 * closed. One control, because from the reader's side it is one gesture. */
export function endConversation(): void {
	const conv = store.activeConv();
	if (conv?.type === "dm") closeDm(conv);
	else leaveRoom();
}

/** Close a direct conversation and go back to whatever is behind it.
 *
 * A direct line is not a room: there is no membership to hand back. Closing one
 * ends the connections this conversation runs on, in both directions, and drops
 * the history. The person stays reachable, and messaging them again opens a
 * fresh line through a fresh introduction.
 *
 * What is behind it is the room you are still in, if you are still in one, and
 * the join card if you are not.
 */
export function closeDm(conv: DmConv): void {
	const key = conv.key;
	const s = store.get();
	store.forgetConv(key);
	// Hand the line's own connection back. A redeemed introduction holds one open
	// to the member for as long as the line lives, so forgetting the line here
	// without closing it would leave the connection and the reply inbox on it
	// standing with nothing on this side referring to them.
	if (live) dropLine(live, key);
	// The back-channel is the other direction: a connection the member opened to
	// us, captured as it arrived. It carries this conversation and nothing else
	// (a cold dial is per-peer), so closing the conversation closes it. Dropping
	// only the map entry left the session up with nothing on this side referring
	// to it, and the far end holding a line to a conversation that no longer
	// exists here.
	const back = live?.backChannels.get(key);
	live?.backChannels.delete(key);
	if (back !== undefined) {
		try {
			back.session.close();
		} catch (err) {
			console.error(
				"rooms: an arriving direct connection would not close, so it stays up:",
				reason(err),
			);
		}
	}
	// Only the conversation you are looking at needs somewhere to go. Closing one
	// from the rail while reading something else should leave you reading it, the
	// same as leaving a room you are not currently in.
	if (s.activeKey !== key) return;
	if (s.joinedRoom) {
		const room = store.roomKey(s.joinedRoom);
		if (store.getConv(room)) {
			store.switchTo(room);
			return;
		}
	}
	store.showJoinCard();
}

// Enter `name` as `nick`: subscribe to the room (a capability), then leave the
// current one, so a rejected claim leaves the current room intact — the same
// order the room_client client uses. Resolves with "" once we are in, or with
// the reason a reader needs to act on.
async function enterRoom(name: string, nick: string, attempt = 0): Promise<string> {
	const session = live;
	if (session === null) {
		// Never silently: a caller that reaches here with no session has a live
		// "Joining…" button waiting on an answer that will not come.
		return "not connected to the room server yet";
	}
	try {
		const ref = await enterOrOpen(session.dir, name);
		const next = await Room.subscribe(
			session.dir.session,
			ref,
			nick,
			(from, on) => setRoomTyping(from, on),
		);
		const prev = session.room;
		session.room = next;
		if (prev) {
			await prev.leave().catch((err) =>
				console.error("rooms: could not leave the previous room:", reason(err))
			);
		}
		// Commit the nick we actually claimed. Two tabs of one browser share the
		// persisted nick, so a collision may have suffixed it below; reflect the
		// real name in the store so a member never sees a stale one.
		store.setNick(nick);
		// Now that we hold a nick in a room, advertise our keyed-relay locator so
		// others can introduce+redeem us for direct messages (ADR-0088 cold-dial).
		advertisePresence();
		enteredRoom(name);
		void pump(next);
		return "";
	} catch (err) {
		const re = roomErrorOf(err);
		if (re?.code === NICK_TAKEN && attempt < 20) {
			// A second tab of the same browser prefills the first tab's persisted
			// nick, so it dead-ends on the room's duplicate-name guard. Claim a free
			// variant instead — `alice` → `alice-2` → `alice-3` — so "open a tab,
			// click Join" just works, which is the whole point of two-tab DMs.
			const base = nick.replace(/-\d+$/, "");
			const candidate = `${base}-${attempt + 2}`.slice(0, MAX_NICK);
			return await enterRoom(name, candidate, attempt + 1);
		}
		if (re?.code === NICK_TAKEN) {
			store.showJoinCard();
			store.setStatus("pick another name");
			return re.detail;
		}
		if (!store.get().joinedRoom) {
			store.setStatus("could not join");
			return reason(err);
		}
		// Already in a room, so this was a switch that failed: say so where the
		// reader is looking rather than sending them back to the card.
		if (store.activeConv()) store.deliverActive(store.sysItem(reason(err)));
		else store.setBanner(reason(err));
		return "";
	}
}

// The room confirmed us. Show it, creating its conversation on first entry.
function enteredRoom(name: string): void {
	const nick = store.get().nick;
	store.setJoinedRoom(name);
	const conv = store.ensureRoom(name);
	store.clearMembers(conv.key);
	// The foot names the room, not just the connection. It is the one line that
	// is always on screen whatever is open, so it is where "which room am I in"
	// belongs — a direct message fills the whole conversation column and used to
	// leave that unanswered anywhere.
	store.setStatus("in #" + name + " as " + nick);
	const cur = store.activeConv();
	if (userPickedRoom || !cur || cur.type === "room") store.switchTo(conv.key);
	userPickedRoom = false;
}

// Deliver a room's lines to its conversation until we switch away (a newer pump
// token) or the stream ends.
//
// Read through an explicit reader rather than `for await (… of room.messages)`.
// Iterating a ReadableStream needs `Symbol.asyncIterator` on its prototype, and
// WebKit did not have it until December 2025: the request was filed in February
// 2019 as WebKit bug 194379 and landed in 303970@main on 2025-12-05, so every
// Safari built before that lacks it, iOS 26 included. Where it is missing the
// loop throws before the first read, and the room then looks entirely healthy —
// it joins, it sends, presence and the typing indicator both arrive, because
// `room_client` routes those around the stream as callbacks — while not one
// line is ever delivered. `getReader` works wherever ReadableStream does, and
// is already how `bindings/ts/web` reads its socket. The date is written down
// because it is checkable against the bug, and the answer is not guessable.
async function pump(room: Room): Promise<void> {
	const token = ++pumpToken;
	const reader = room.messages.getReader();
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) return;
			if (token !== pumpToken) {
				// A newer pump owns the view. Drop this stream rather than leave it
				// locked and half-read; `for await` used to do this on return.
				await reader.cancel().catch(() => {});
				return;
			}
			const { from, text, system, presence } = value;
			const joined = store.get().joinedRoom;
			if (!joined) continue;
			const conv = store.ensureRoom(joined);
			if (presence) store.applyPresence(conv.key, presence);
			if (system) store.deliver(conv.key, store.sysItem(text));
			else {
				const nick = store.get().nick;
				const mine = from === nick;
				// Our own line was painted optimistically; its echo confirms it in
				// place rather than painting a duplicate.
				if (mine && confirmRoomEcho(text)) continue;
				store.deliver(conv.key, store.chatItem(from, text, mine));
				if (!mine && mentionsYou(text, nick)) {
					maybeNotify("#" + joined + " · " + from, text);
				}
			}
		}
	} catch (err) {
		// Leaving a room ends the stream cleanly, which arrives as `done` above,
		// not here. Reaching this means something actually broke, and silence is
		// what made the missing-iterator failure take so long to find: the room
		// simply never spoke. Say so where the reader is looking.
		if (token === pumpToken) {
			store.deliverActive(
				store.sysItem("This room stopped delivering messages: " + reason(err)),
			);
		}
	} finally {
		try {
			reader.releaseLock();
		} catch { /* already released by cancel above */ }
	}
}

// ── Direct messages by introduction ───────────────────────────────────────
// Open a DM conversation with `peer` and show it. The direct line itself opens
// lazily on the first send, so opening the thread asks the directory for nothing.
export function startDm(peer: string): void {
	if (!peer) return;
	const nick = store.get().nick;
	if (nick && peer.toLowerCase() === nick.toLowerCase()) {
		store.deliverActive(store.sysItem("You can't start a direct message with yourself."));
		return;
	}
	store.switchTo(store.ensureDm(peer).key);
}

// Send a direct message to `peer`, opening the introduced line on first use. A
// DM has no echo, so paint our own line at once; a dial that can't land (a member
// reachable only over TCP, or one who has left) says so in the thread.
function dmSay(conv: DmConv, text: string): void {
	// The conversation, not the name. Resolving by name here would find whichever
	// conversation currently answers to it — which after the member left is a
	// different one, so a message typed into the thread on screen would land in
	// another, or open a line to whoever holds the name now.
	const item = store.chatItem(store.get().nick, text, true, "sending");
	store.deliver(conv.key, item);
	sendDm(conv.key, item.id, text);
}

// Open the introduced line (lazily on first use) and deliver one line to the peer,
// tracking the bubble's send state honestly. On success the bubble clears to confirmed;
// on failure it tints failed and tap-to-retry, and a friendly note names why. A retry
// runs this again with the same bubble.
function sendDm(key: string, id: number, text: string): void {
	const conv = store.getConv(key);
	if (conv?.type !== "dm") return;
	const peer = conv.id;
	// A conversation whose member left is closed for good. The room has their
	// name back, so reaching for it now would find whoever holds it next — which
	// is the one thing this conversation must never quietly do.
	if (conv.line === "closed") {
		markSend(key, id, "failed");
		store.deliver(
			key,
			store.sysItem(
				`${peer} left, so this conversation is closed. ` +
					`Starting a new one with that name reaches whoever holds it now, ` +
					`who may be someone else.`,
			),
		);
		return;
	}
	markSend(key, id, "sending");
	// A peer who direct-messaged us first handed us a reply capability on the
	// connection their message arrived on. Answer over that same connection
	// (ADR-0088 receiver primitive), the only path that reaches a peer that
	// opened no listener; otherwise open (or reuse) an introduced line to them.
	//
	// The capability is only good while that connection is. A peer who went
	// offline and came back is a *new* connection, and nothing else drops the
	// entry: the `unregistered` arm below clears their introduced line, and the
	// clear at disconnect is about our own session ending, not theirs.
	const session = live;
	if (session === null) return;
	let cached = session.backChannels.get(key);
	if (cached && !cached.session.sessionOpen) {
		session.backChannels.delete(key);
		cached = undefined;
	}
	const back = cached;
	// Started inside a promise on purpose. Anything this expression raises
	// synchronously would escape the `.catch` below, and that catch is what
	// drops the dead route. Skipping it once turned one lost message into every
	// message: the entry stayed, so the next send failed in the same place.
	// `Session.send` itself now reports a closed session as a rejected handle
	// rather than a throw, but this is the wrapper for everything else.
	const delivered = back
		? (async () => await back.session.send(back.reply, DM, [text]))()
		: openDm(conv).then((line) => line.say(text));
	delivered
		.then(() => {
			markSend(key, id, undefined);
			store.setDmLine(key, "live");
		})
		.catch((err) => {
			// Let the dead line go so the next send retries: a stale back-channel
			// falls back to a fresh introduction, a stale introduction re-redeems.
			// The line is handed back rather than merely forgotten. A line is
			// counted onto the connection it rides, and a forgotten one keeps its
			// count for good, so the last conversation to close never hangs up and
			// the next redeem resolves to the connection that close was supposed
			// to end. The back-channel is the other direction, a connection the
			// peer owns, so there only the route is dropped.
			if (back) session.backChannels.delete(key);
			else dropLine(session, key);
			markSend(key, id, "failed");
			store.deliver(key, store.sysItem(dmFailureText(peer, err)));
		});
}

// A friendly reason a direct message could not land, from the typed taxonomy rather than
// the raw wire reason: a member the directory has no registration for is offline, and any
// other failure is reported generically instead of leaking a wire code.
function dmFailureText(peer: string, err: unknown): string {
	const re = roomErrorOf(err);
	if (re?.code === PEER_OFFLINE) return `${peer} is offline.`;
	return `Couldn't reach ${peer}.`;
}

// The introduced direct line to a peer, opened once and reused. `DirectMessage.open`
// asks the directory to introduce us and wraps the handoff-give; the redeem dial
// opens the direct connection, riding the relay's iroh path to the member. The
// line hosts a reply inbox on that connection, so a member's reply lands here and
// paints in the peer's DM thread — the member never dials us.
function openDm(conv: DmConv): Promise<DirectMessage> {
	const peer = conv.id;
	const key = conv.key;
	const session = live;
	if (session === null) return Promise.reject(new Error("not connected"));
	const existing = session.lines.get(key);
	if (existing) {
		// Same staleness as the back-channel above, one step softer: `say` is
		// async, so a dead line surfaces as a rejection and repairs itself after
		// one visibly failed message. Checking here spends no message at all.
		const reopen = () => {
			// Only if it is still the entry we looked at; a concurrent send may
			// already have replaced it. Handed back rather than forgotten, for the
			// same reason the failed send above hands its line back.
			if (session.lines.get(key) === existing) dropLine(session, key);
			return openDm(conv);
		};
		return existing.then((line) => (line.live ? line : reopen()), reopen);
	}
	// A conversation whose member has gone is never re-introduced: the name is
	// back in the room's hands and the next holder is a different person, so
	// continuing here would quietly point this thread at them.
	if (conv.line === "closed") {
		return Promise.reject(new Error(`${peer} left, so this conversation is closed`));
	}
	const line = DirectMessage.open(session.dir, peer, (text) => receiveDm(key, peer, text));
	session.lines.set(key, line);
	return line;
}

/** Let go of the line for one conversation, handing its connection back.
 *
 * Every site that stops using a line comes through here. Dropping the map entry
 * alone leaves a redeemed connection up and the reply inbox exported on it, with
 * nothing left on this side that can reach either. */
function dropLine(session: Live, key: string): void {
	const line = session.lines.get(key);
	if (line === undefined) return;
	session.lines.delete(key);
	void line.then((l) => l.close()).catch((err) =>
		console.error(
			"rooms: a direct line would not close, so its connection stays up:",
			reason(err),
		)
	);
}

/** A line arriving from `peer` in the conversation `key`. Both directions land
 * here: a reply on a line we opened, and a message from a member who reached us
 * first. Neither reads the sender off the message — a line we opened goes to the
 * member the directory introduced, and an inbox belongs to the one member the
 * directory handed it to. */
function receiveDm(key: string, peer: string, text: string): void {
	store.setDmLine(key, "live");
	store.deliver(key, store.chatItem(peer, text, false));
	if (store.get().activeKey !== key) maybeNotify(peer, text);
}

// Another peer's typing flag — one auto-clear rule for rooms and
// direct lines alike, so a dropped "off" still fades. Timers key on
// (conversation, peer): the same nick may type in the room and a DM
// at once, and neither flag may clear the other.
const typingTimers = new Map<string, ReturnType<typeof setTimeout>>();
function applyTyping(key: string, from: string, on: boolean): void {
	const timerKey = `${key}\u0000${from}`;
	const running = typingTimers.get(timerKey);
	if (running) clearTimeout(running);
	if (on) {
		typingTimers.set(
			timerKey,
			setTimeout(() => {
				typingTimers.delete(timerKey);
				store.setTyper(key, from, false);
			}, TYPING_CLEAR_MS),
		);
	} else typingTimers.delete(timerKey);
	store.setTyper(key, from, on);
}

function setRoomTyping(from: string, on: boolean): void {
	const s = store.get();
	if (!s.joinedRoom || from === s.nick) return;
	applyTyping(store.ensureRoom(s.joinedRoom).key, from, on);
}

/** Turn desktop notifications on or off, asking the browser the first time. */
export async function toggleNotify(): Promise<void> {
	const { notifyOn } = store.get();
	if (notifyOn) {
		store.setNotify(false);
		return;
	}
	if (!("Notification" in globalThis)) {
		store.deliverActive(store.sysItem("This browser can't show desktop notifications"));
		return;
	}
	let permitted = Notification.permission;
	if (permitted === "default") permitted = await Notification.requestPermission();
	if (permitted !== "granted") {
		store.deliverActive(store.sysItem("Notifications are blocked in your browser settings"));
		return;
	}
	store.setNotify(true);
}

function reason(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

// ── Connection ────────────────────────────────────────────────────────────
/** What a reader is told when an attempt to reach the room server did not get
 * there. Two surfaces say it — the join card, which was waiting on a join, and
 * the status line, which is waiting on nothing — and they say the same thing
 * because it is one fact. */
const UNREACHABLE = "could not reach the room server; retrying…";

export function connect(): void {
	store.setSession(everConnected ? "reconnecting" : "connecting");
	store.setStatus(everConnected ? "reconnecting…" : "connecting…");
	if (everConnected && store.get().joinedRoom) store.setBanner("Reconnecting…");
	void openSession();
}

async function openSession(): Promise<void> {
	try {
		// Instantiate the wasm peer once; its adapter injection lets the stack's
		// `connect` (which `Directory.connect` rides) dial over the relay. Cache
		// only a *resolved* init: `/pancake_host.wasm` answers 503 until the
		// module is built, so a first attempt can lose that race — a rejected
		// promise left cached would make every reconnect re-await the same failure
		// forever instead of retrying once the asset is live.
		if (stackReady === null) {
			const attempt = init({
				wasm: fetch("/pancake_host.wasm"),
				wsUrl: relayWsUrl,
				relayUrl: relayLocatorUrl,
			});
			attempt.catch(() => {
				if (stackReady === attempt) stackReady = null;
			});
			stackReady = attempt;
		}
		await stackReady;
		// The live timeline tap goes in before the host, so the directory
		// session's own open is captured rather than missed.
		await ensureVizPublisher();
		// The inbox host both dials the directory and accepts cold-dials, so start
		// it before the dial: the directory session must be present in the same
		// host's live-session directory when a later cold-dial withdraws from that
		// session's gift table.
		const host = ensureInbox();
		const locator = (await (await fetch("/locator")).text()).trim();
		// Dial transport-neutrally, the same as every terminal client: the rooms
		// `dial` normalises a bare `host:port` into a `tcp` locator and passes an
		// `ocapn://…iroh` URI through, both routed over the relay by the injected
		// browser adapter. The stack's default `connect` would reject the bare
		// designator `/locator` serves.
		const next = await Directory.connect(locator, (l) => dial(l, host));
		// Everything this session will hold, minted with it. Nothing below adds a
		// field to module scope, so nothing below can outlive the session by
		// being forgotten at the other end.
		const session: Live = {
			dir: next,
			room: null,
			lines: new Map(),
			backChannels: new Map(),
			echoes: [],
			advertised: null,
			advertiseRetries: ADVERTISE_RETRY_LIMIT,
			registered: false,
			deferredOffers: new Set(),
			stable: null,
		};
		live = session;
		const seen = await next.watch((event) => {
			switch (event.kind) {
				case "closed":
					store.dropLiveRoom(event.name);
					break;
				case "registered":
					store.setDmable(event.name, true);
					// Offer a member who arrives after us an inbox straight away, so their
					// first message costs no extra round trip. One already on the roster
					// before we had a name is covered by the directory asking on demand.
					offerInboxFor(event.name);
					break;
				case "unregistered":
					store.setDmable(event.name, false);
					// The member left, so the room has their name back and may grant
					// it to someone else. Close what we have with them and hand the
					// lines back; a later introduction under the same name opens a
					// new conversation, because it may well be a new person.
					// Their reply route goes with them: it reached that connection,
					// and the next holder of the name is not on it.
					for (const key of store.closeDmsWith(event.name)) {
						if (live) dropLine(live, key);
						live?.backChannels.delete(key);
					}
					// The next holder of this name is a different person and gets an
					// inbox of their own. An offer still queued for them is dropped
					// rather than spending a permanent name on someone who has left.
					for (const p of session.deferredOffers) {
						if (p.toLowerCase() === event.name.toLowerCase()) {
							session.deferredOffers.delete(p);
						}
					}
					ensureOfferer().forget(event.name);
					break;
				default:
					store.setLiveRoom(event.name, event.count);
					break;
			}
		});
		store.resetLiveRooms(seen.map((room) => [room.name, room.count] as const));
		announceDirectory();
		store.setSession("connected");

		store.setBanner("");
		if (everConnected && store.get().joinedRoom) {
			store.deliverActive(store.sysItem("Reconnected"));
		}
		everConnected = true;

		// A dropped directory session (the server respawning) reconnects the page.
		next.session.serve()
			.catch((err) => console.error("rooms: the directory session ended:", reason(err)))
			.finally(() => endSession(session));
		// Reset the backoff only once this session has *survived* a stability
		// window, not the instant the handshake reached `watch`. A server that
		// accepts, answers `watch`, then drops immediately (a post-accept crash
		// loop) would otherwise re-earn the reset every cycle and reconnect every
		// 500 ms — a storm, not a backoff. Cleared in `onDisconnected` if the
		// session dies before the window elapses, because the timer belongs to it.
		session.stable = setTimeout(() => {
			backoff = 500;
			session.stable = null;
		}, BACKOFF_STABLE_MS);

		// If we were in a room, re-enter it. Otherwise honour a join the user
		// asked for while this session was still opening, and only then wait.
		const joined = store.get().joinedRoom;
		if (joined && store.get().nick) {
			store.setStatus("rejoining #" + joined + "…");
			void enterRoom(joined, store.get().nick);
		} else if (staged) {
			const wanted = staged;
			staged = null;
			store.setStatus("entering #" + wanted.room + "…");
			settleStaged(await enterRoom(wanted.room, wanted.nick));
		} else store.setStatus("pick a room");
	} catch (err) {
		// Surface the real cause for the devtools console; the user sees a plain
		// retry line, but a blocked ws (an http page over https, say) or a wasm
		// load failure is otherwise invisible.
		console.error("rooms: could not open the peer session:", err);
		// A staged join is not lost on a failed attempt: the retry below opens
		// another session, which replays it. The card is told so it can offer the
		// button back, in case the reader would rather change their mind.
		settleStaged(UNREACHABLE);
		// The attempt is over and it failed. Left on "connecting", the dot in the
		// foot of the rail would go on claiming an attempt that is no longer
		// running, and the opening screen would go on waiting for an answer that
		// has already come back. The retry sets it to "connecting" again itself,
		// so each attempt reads as the attempt it is.
		store.setSession("disconnected");
		store.setStatus(UNREACHABLE);
		scheduleReconnect();
	}
}

/** This session is over.
 *
 * Ending it is dropping the object, which is the whole point of it being one:
 * the room it had us in, the lines redeemed over it, the name it advertised, the
 * offers it had queued and the stability timer it was running all go with it,
 * and none of them is named here. What is left is only what has to be *released*
 * or *reported* — a redeemed line holds a connection and an exported inbox on
 * it, a line awaiting an echo will never get one, and the page has to be told —
 * which is a shorter list, and one that fails loudly rather than quietly when it
 * is incomplete. */
function endSession(which: Live): void {
	if (live !== which) return; // already replaced by a newer session
	live = null;
	if (which.stable !== null) clearTimeout(which.stable);
	// A redeemed introduction holds a connection open and an inbox exported on
	// it, so these are handed back rather than merely forgotten.
	for (const key of [...which.lines.keys()]) dropLine(which, key);
	// Our own room lines still awaiting an echo will never get one now, so mark
	// them failed and tap-to-retry rather than leaving them dimmed forever.
	for (const row of which.echoes.splice(0)) markSend(row.key, row.id, "failed");
	// The new session's `watch` replays who is reachable, and re-advertises us,
	// so the page goes back to knowing neither.
	store.clearDmable();
	store.unreadyDms();
	store.setSession("reconnecting");
	store.setStatus("reconnecting…");
	if (store.get().joinedRoom) store.setBanner("Reconnecting…");
	scheduleReconnect();
}

function scheduleReconnect(): void {
	setTimeout(connect, backoff);
	backoff = Math.min(backoff * 2, BACKOFF_CEILING_MS);
}

// End our rendezvous registration when the tab goes away. The relay reclaims a
// dropped socket on its own (its idle ping/pong), so this is a courtesy close,
// not a correctness requirement; a browser is a rendezvous, not a mailbox.
globalThis.addEventListener("beforeunload", () => {
	rendezvous?.stop();
});
