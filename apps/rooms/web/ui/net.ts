// The rooms page's data layer, as a real OCapN peer in the browser. The page
// instantiates the pancake runtime over `@pancake/web` (the wasm Host, no dlopen),
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

import { init, serveRendezvous } from "@pancake/web";
import type { RendezvousHandle, WebRuntime } from "@pancake/web";
import {
	annotateSession,
	type Argument,
	currentSession,
	enableTrace,
	formatLocatorUri,
	formatPeerUri,
	Host,
	Ref,
	type Session,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_WEBRTC,
} from "@pancake/runtime";
import * as relay from "@pancake/relay";
import * as webrtc from "@pancake/webrtc";
import { publishViz, type VizPublisher } from "../../lib/viz_publish.ts";
import { directorySignalingAuthority, serveWebrtcSignaling, type WebrtcSignalingServer } from "../../lib/signaling.ts";
import {
	AUTO_IMAGE_BYTES,
	MAX_DIRECT_ATTACHMENT_BYTES,
	MAX_LINE,
	MAX_MESSAGE_FILES,
	MAX_NICK,
	TYPING_CLEAR_MS,
} from "../../lib/limits.ts";
import { fetchBlob, readAttachments, sendWithAttachments, validateAttachmentSource } from "../../lib/attachment.ts";
import type { Attachment, AttachmentSource } from "../../lib/attachment.ts";
import { DirectMessage, Directory, type PostedLine, Room } from "../../lib/room_client.ts";
import { type InboxOfferer, inboxOfferer } from "../../lib/dm_inbox.ts";
import { CAPTP_VERSION, CODEC, DM, TYPING } from "../../lib/protocol.ts";
import { enterOrOpen } from "../../lib/enter_room.ts";
import { dial, roomsLocator } from "../../lib/locator.ts";
import { BLOB_EXPIRED, NICK_TAKEN, PEER_OFFLINE, roomErrorOf } from "../../lib/errors.ts";
import {
	type DirId,
	dirId,
	type DmConv,
	type RoomConv,
	type RoomDestination,
	type SendState,
	type ViewerDirection,
} from "./types.ts";
import * as store from "./store.ts";
import * as prefs from "./prefs.ts";
import { maybeNotify } from "./notify.ts";
import { directoryName, lineCost, lineRoom, tooLong } from "./text.ts";
import { commandIn, type CommandPowers, notifiesYou } from "./commands.ts";

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
interface HeldFile {
	attachment: Attachment;
	fetch: (onProgress?: (got: number) => void) => Promise<Uint8Array>;
	release: () => void;
}

interface AttachmentProgress {
	/** Latest presentation state by conversation and file. File ids are unique,
	 * but retaining the conversation boundary lets one flush use the store's
	 * batch verb without rediscovering ownership. */
	pending: Map<string, Map<number, store.AttachmentFields>>;
	frame: number | null;
}

interface Live {
	/** Which directory this session is. Every table below belongs to it, and a
	 * captured session can ask whether it is still the live one for its own
	 * directory without knowing anything about the others. */
	readonly id: DirId;
	readonly dir: Directory;
	/** Whether this is the directory that served the page. Its locator is
	 * rediscovered after a disconnect because routing hints may have changed,
	 * while `id` below keeps the directory's authority stable. */
	readonly home: boolean;
	/** The directory peer this session actually reaches. It need not be the
	 * server that served the page. */
	readonly locator: string;
	/** Every room this session has us in, by conversation key. None of them is
	 * necessarily the one on screen, and there is no "current" one: a room is
	 * addressed by the conversation being acted on.
	 *
	 * The table hangs off the session because a room reference is only good on
	 * the connection that fetched it. Dropping the session drops every room with
	 * it, and a reconnect re-enters them all against the new one. */
	rooms: Map<string, Room>;
	/** Introduced direct lines, by conversation. One introduction each: the first
	 * send opens it, later sends reuse it, and a failed open is dropped so the
	 * next send retries. */
	lines: Map<string, Promise<DirectMessage>>;
	/** Reply routes a peer handed us with an incoming message, by conversation. */
	backChannels: Map<string, { session: Session; reply: Ref }>;
	/** Our own room lines painted and awaiting the room's echo. */
	echoes: { key: string; id: number; attachmentIds: number[]; text: string }[];
	/** The reference the room answered with for each of our own lines, by the id
	 * this window knows that line by. Holding one is the authority to change or
	 * withdraw that line, so this map is exactly what this tab may still act on —
	 * and it dies with the session, because a reference cannot outlive the
	 * connection it came over. */
	posted: Map<number, PostedLine>;
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
	/** How long to wait before the next attempt on *this* directory, doubling per
	 * failure. One directory being unreachable says nothing about the others, so a
	 * dead one cannot drag a healthy one's cadence with it. */
	backoff: number;
	/** Whether this directory has ever been reached, which is what tells a first
	 * attempt from a reconnection in everything the reader is told. */
	everConnected: boolean;
	/** Pending WebRTC offer bring-ups filed through this directory session. */
	signaling: WebrtcSignalingServer | null;
	/** This directory's inbox offerer, minted on the first offer it has to make.
	 * One per directory, because an inbox is offered *to* a nickname and a
	 * nickname is one directory's grant. */
	offerer: InboxOfferer | null;
	/** The blob capability behind each received file, by the file's id, with the
	 * fetch and release operations for the session it is reachable through.
	 * Capabilities live here rather than in the
	 * store for the same reason every other one does: the store holds what the
	 * page draws, and a reference is not something a page draws. */
	files: Map<number, HeldFile>;
	/** Object URLs this session minted, by the file that displays them.
	 * A retry replaces its URL; closing a conversation releases its files. */
	objectUrls: Map<number, string>;
	/** Network chunks coalesced to at most one immutable UI update per frame. */
	progress: AttachmentProgress;
	/** The files behind each of our own posts that has not been confirmed, by
	 * the message's id. Retrying a failed file message has to send the files again;
	 * without this it would re-post the caption alone and the room would show
	 * everyone a bare line while our own bubble still drew an attachment. */
	outgoing: Map<
		number,
		{
			key: string;
			attachmentIds: number[];
			files: File[];
			caption: string;
			/** Trips the bytes of this send, once they are going. Replaced on every
			 * attempt, so a retry after a stop is not stopped before it starts. */
			stop?: AbortController;
		}
	>;
}
/** Every directory this tab holds, by the authority its locator names.
 *
 * A directory is not a place you switch to. Holding one means a live session, a
 * nickname registered on it, and everything reachable through that nickname, so
 * opening a second takes nothing away from the first — the same rule rooms
 * follow, one level up.
 *
 * Insertion order is the order they were opened, which is the order the rail
 * lists them and the order a reconnect works through them. */
const dirs = new Map<DirId, Live>();
/** The freshest route known for each directory authority. A live session owns
 * its route, but Settings and reconnect still need it after that session has
 * been retired. */
const directoryLocators = new Map<DirId, string>();

/** The session for one directory, or null when this tab does not hold it. */
function dirSession(dir: DirId): Live | null {
	return dirs.get(dir) ?? null;
}

/** The session a conversation belongs to. Every conversation names its
 * directory, so this is the one route from anything on screen to the wire that
 * carries it. */
function convSession(key: string | null): Live | null {
	const conv = store.getConv(key);
	return conv === null ? null : dirSession(conv.dir);
}

/** Whether `session` is still the live one for its own directory. A session a
 * reconnect replaced, or whose directory has been left, is not — and the test
 * says so without asking what any other directory is doing. */
function isCurrent(session: Live): boolean {
	return dirs.get(session.id) === session;
}

/** Any directory this tab holds, for the questions that are about the tab
 * rather than about one of them. */
function anyLive(): Live | null {
	for (const session of dirs.values()) return session;
	return null;
}

/** The page's own directory, discovered from `/locator` and refreshed after its
 * live session ends. There is no companion holding whichever directory was
 * reached most recently: what a reader last typed into the join card belongs to
 * that card and is kept in its drafts, and nothing outside it has a use for a
 * "current" directory that is neither this page's nor the one a surface was
 * opened about. */
let homeDirectoryLocator: string | null = null;

/** Name a directory by authority, excluding mutable routing hints, or null when
 * the text is not a locator at all. The shared locator parser remains the grammar
 * authority; this application decides that one directory is one
 * transport/designator pair across address changes.
 *
 * Null rather than a throw, because every caller here is holding something a
 * person typed, and "that is not an address" is an answer to give them rather
 * than an exception to raise. It used to throw, and the throw reached the page:
 * a locator that merely pointed nowhere was refused politely, while one that was
 * not a locator took the whole interface down to the error screen — the two
 * halves of the same mistake, one of them tested. */
function directoryId(locator: string): DirId | null {
	try {
		const parsed = roomsLocator(locator);
		return dirId(formatPeerUri(parsed.transport, parsed.designator));
	} catch {
		return null;
	}
}

/** What a person is told when what they typed is not an address. One wording, so
 * the join card and the status line cannot describe the same mistake
 * differently. */
function notALocator(locator: string): string {
	return "That does not look like an address: " + locator.trim();
}

async function homeLocator(): Promise<string> {
	if (homeDirectoryLocator !== null) return homeDirectoryLocator;
	const locator = await prefs.directoryLocator();
	if (locator === null) throw new Error("rooms: locator not ready");
	homeDirectoryLocator = locator;
	return locator;
}

async function requestedLocator(locator: string): Promise<string> {
	return locator.trim() || await homeLocator();
}

/** The address of the directory this page came from, and only that one.
 *
 * Settings is the one thing that asks, and Settings is about *this* directory:
 * the one the page was served by, which a reader never chose and cannot leave.
 * It used to answer with whichever directory the conversation on screen happened
 * to be on, so opening Settings while reading a room somewhere else showed that
 * somewhere else's address under a heading saying "this directory" — two
 * different directories, one label, and no way to tell which you were looking
 * at. Every other directory is described by its own card, which is handed the
 * one it is about. */
export function directoryLocator(): string | null {
	const home = store.get().homeDir;
	return (home === null ? null : directoryLocators.get(home)) ?? homeDirectoryLocator;
}

/** The directory a control acts on when nothing else names one.
 *
 * The conversation on screen answers it, because that is what a reader means by
 * "here"; with the join card up and nothing open, the first directory this tab
 * holds does. A caller that already holds the session it is acting for takes the
 * directory from that session instead and never asks this. */
function actingDir(): DirId {
	const conv = store.activeConv();
	if (conv !== null) return conv.dir;
	for (const dir of store.get().dirs.keys()) return dir;
	return dirId("");
}

/** Keep transfer cadence out of React. Parallel files replace their own latest
 * byte count in a session-bounded map, then one animation frame publishes every
 * conversation's visible progress with one history copy apiece. */
function noteAttachmentProgress(session: Live, key: string, id: number, got: number): void {
	let updates = session.progress.pending.get(key);
	if (updates === undefined) {
		updates = new Map();
		session.progress.pending.set(key, updates);
	}
	updates.set(id, { got });
	if (session.progress.frame !== null) return;
	session.progress.frame = requestAnimationFrame(() => {
		session.progress.frame = null;
		const pending = session.progress.pending;
		session.progress.pending = new Map();
		if (!isCurrent(session)) return;
		for (const [conversation, fields] of pending) store.updateAttachments(conversation, fields);
	});
}

/** A URL, completion, or error is terminal presentation state. Remove queued
 * byte counts for those files before publishing it synchronously, so a frame
 * already in flight cannot overwrite the terminal answer. */
function discardAttachmentProgress(session: Live, key: string, ids: Iterable<number>): void {
	const pending = session.progress.pending.get(key);
	if (pending !== undefined) {
		for (const id of ids) pending.delete(id);
		if (pending.size === 0) session.progress.pending.delete(key);
	}
	if (session.progress.pending.size === 0 && session.progress.frame !== null) {
		cancelAnimationFrame(session.progress.frame);
		session.progress.frame = null;
	}
}

function commitAttachmentUpdates(
	session: Live,
	key: string,
	updates: ReadonlyMap<number, store.AttachmentFields>,
): void {
	discardAttachmentProgress(session, key, updates.keys());
	store.updateAttachments(key, updates);
}

function commitAttachment(
	session: Live,
	key: string,
	id: number,
	fields: store.AttachmentFields,
): void {
	commitAttachmentUpdates(session, key, new Map([[id, fields]]));
}

let userPickedRoom = false; // set when the user taps a room, so entering switches to it
let runtimeReady: Promise<WebRuntime> | null = null;
const FIRST_BACKOFF_MS = 500;
// A session must survive this long before its handshake counts as a stable
// connection worth resetting the backoff to 500. Below it, a server that accepts
// then drops keeps the exponential backoff climbing instead of storming.
const BACKOFF_STABLE_MS = 10_000;
// The longest we wait between attempts. A room server being restarted is back in
// seconds, so a slower retry than this only makes the page look dead when it is
// not.
const BACKOFF_CEILING_MS = 5_000;

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
// Which transport this tab advertises for direct messages: a `webrtc`
// identity by default, so the DataChannel carries the DM directly and the
// room directory carries only the signaling (ADR-0089), or the relay
// rendezvous identity when Settings (or `?dm=relay`) chooses the relay.
const DM_TRANSPORT: typeof TRANSPORT_KEYED_RELAY | typeof TRANSPORT_WEBRTC = prefs.dmTransport() === "relay"
	? TRANSPORT_KEYED_RELAY
	: TRANSPORT_WEBRTC;
// The live timeline endpoint this tab publishes its own trace to. The page
// asks its own server for one (`/viz`, answered when the room was started with
// ROOMS_VIZ_PORT), and Settings / `?viz=ws://host:port/` overrides that
// for a run where the endpoint is somewhere else. Off by default: with no
// endpoint the tap is never installed and the host's emit sites are one null
// check.
//
// This is the only way a direct message becomes visible. A DM is a session
// between two members, held on the members' own hosts, so the room server sees
// none of it and must not start seeing it. What travels to the endpoint is
// telemetry on a one-way socket; the conversation stays direct.
const VIZ_OVERRIDE = prefs.vizOverride();
let inboxHost: Host | null = null;
let vizPublisher: VizPublisher | null = null;

// Ask the page's own server where the live timeline endpoint is. A run without
// one answers 404, and this tab then publishes nothing.
async function vizEndpoint(): Promise<string | null> {
	if (VIZ_OVERRIDE !== null) return VIZ_OVERRIDE;
	return await prefs.advertisedViz();
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
function inboxFor(home: Live, peer: string): (verb: string, args: unknown[]) => null {
	return (verb: string, args: unknown[]): null => {
		// The ephemeral sibling of a message: the peer's typing flag,
		// same auto-clear rule as a room's.
		if (verb === TYPING) {
			applyTyping(store.ensureDm(home.id, peer).key, peer, args[0] === true);
			return null;
		}
		if (verb !== DM) throw new Error(`dm inbox has no method ${verb}`);
		const text = typeof args[0] === "string" ? args[0] : "";
		const reply = args[1];
		const attachments = readAttachments(args as Argument[], reply instanceof Ref ? 2 : 1);
		// The arriving connection has to be read inside the turn; it is null once
		// the turn returns, and our reply sends on a later one.
		const key = store.ensureDm(home.id, peer).key;
		const session = currentSession();
		// Name the arriving direct connection for whoever is watching the live
		// timeline. The dialer names it too, from the other end; either end's
		// annotation is enough, and a watcher only ever hears the one whose
		// view of this wire it is being shown.
		if (session !== null) annotateSession(session, { label: peer });
		if (session !== null && reply instanceof Ref) {
			const held = home.backChannels.get(key);
			// A working route is not displaced: this peer may open a second
			// connection while the first still carries our replies.
			if (held === undefined || !held.session.sessionOpen) {
				home.backChannels.set(key, { session, reply });
			}
		}
		receiveDm(key, peer, text, attachments, session);
		return null;
	};
}

// Mint and offer one inbox per peer, on the inbox host so a redeem dial finds
// it. One offerer per directory: an inbox is offered *to* a nickname, and a
// nickname belongs to the directory that granted it, so two directories offering
// under the same name are offering to two different people.
function ensureOfferer(home: Live): InboxOfferer {
	if (home.offerer !== null) return home.offerer;
	const offerer = inboxOfferer({
		host: requireInbox(),
		dir: () => (isCurrent(home) ? home.dir : null),
		behaviorFor: (peer) => inboxFor(home, peer),
		skip: (peer) => peer.toLowerCase() === store.dirNick(home.id).toLowerCase(),
		onError: (peer, err) => console.error(`rooms: could not offer an inbox for ${peer}:`, reason(err)),
	});
	home.offerer = offerer;
	return offerer;
}

// Peers to offer an inbox to as soon as our own registration is acknowledged.
// The gate below is real — an offer sent before the directory has granted us a
// name is refused, and the giftable it published stays published for nothing —
// but dropping the request loses it: `mintInboxFor` dispatches synchronously
// inside the inbound feed while the acknowledgement lands on a microtask, so the
// first peer to ask arrives before the flag does.

function offerInboxFor(home: Live, peer: string): void {
	if (!home.registered) {
		home.deferredOffers.add(peer);
		return;
	}
	ensureOfferer(home).offer(peer);
}

function flushDeferredOffers(home: Live): void {
	const waiting = [...home.deferredOffers];
	home.deferredOffers.clear();
	for (const peer of waiting) offerInboxFor(home, peer);
}

// Create the inbox host once and start serving cold-dials against it. Idempotent
// across reconnects so our identity, held registrations, and open cold-dial
// lines survive a room-server respawn.
function requireInbox(): Host {
	if (inboxHost === null) throw new Error("rooms inbox Runtime is not open");
	return inboxHost;
}

function ensureInbox(runtime: WebRuntime): Host {
	if (inboxHost) return inboxHost;
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
	inboxHost = host;
	// Being reachable ourselves takes only the advertised transport's half: a
	// rendezvous registration holds sockets at the relay, a webrtc member
	// answers offers on the directory session instead (`advertisePresence`).
	if (DM_TRANSPORT === TRANSPORT_KEYED_RELAY) {
		rendezvous = serveRendezvous(host, DM_TRANSPORT, {
			registerUrl: relayRegisterUrl,
			relayUrl: pageSocketBase("/relay"),
		}, {
			onError: (err) => console.error("rooms: rendezvous registration error:", reason(err)),
		});
	}
	return host;
}

/** This window's direct-message locator, the URI a peer would redeem. */
export function selfLocator(): string | null {
	if (inboxHost === null) return null;
	return rendezvous === null
		? formatPeerUri(DM_TRANSPORT, inboxHost.designator())
		: formatLocatorUri(rendezvous.locator);
}

// Advertise our inbox host's direct-message locator to the directory so we appear
// in the DM-able roster and a peer can introduce+redeem us. Registered once per
// nick on the current directory session; a reconnect re-advertises because the
// new directory has no memory of the old introduction.
function advertisePresence(session: Live): void {
	const nick = store.dirNick(session.id);
	if (!inboxHost || !nick) return;
	if (session.advertised === nick) return;
	session.advertised = nick;
	const host = inboxHost;
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
					onError: (err) => console.error("rooms: webrtc signaling error:", reason(err)),
				}).then((signaling) => {
					if (isCurrent(session)) session.signaling = signaling;
					else void signaling.close();
				}).catch((err) => console.error("rooms: could not offer signaling:", reason(err)));
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
				console.error("rooms: could not advertise for direct messages:", reason(err));
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
const ADVERTISE_RETRY_LIMIT = 4;

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
const relayLocatorUrl = (locator: string) => pageSocketUrl("/relay", "target", locator);
// A `host:port` is just a tcp dial target: reuse the one endpoint spelling so a
// later rename touches one line, not two.
const relayWsUrl = (host: string, port: number) => relayLocatorUrl(`${host}:${port}`);
const relayRegisterUrl = (id: string) => pageSocketUrl("/register", "id", id);

function isConnected(): boolean {
	return anyLive() !== null;
}

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
function markSend(key: string, id: number, sendState: SendState | undefined): void {
	store.updateItem(key, id, { state: sendState });
}

// ── Sending ───────────────────────────────────────────────────────────────
/** What a slash command may reach.
 *
 * One table, named a verb at a time, rather than handing commands this module.
 * A command that wants something not here is a decision somebody makes on
 * purpose — which is the same argument this app makes about authority
 * everywhere else, turned on its own vocabulary. */
const NO_GRANTS: ReadonlySet<string> = new Set();

const POWERS: CommandPowers = {
	say(text) {
		store.deliverActive(store.sysItem(text));
	},
	joinRoom(name) {
		const conv = store.activeConv();
		const dir = conv?.dir ?? store.actingDir()?.id ?? null;
		if (dir === null) {
			store.deliverActive(store.sysItem("There is no directory to enter a room on yet."));
			return;
		}
		pickRoom(dir, name);
	},
	leaveHere() {
		endConversation();
	},
	directMessage(who) {
		startDm(who);
	},
	setTheme(theme) {
		store.setTheme(theme);
	},
	showRoster(shown) {
		store.showRoster(shown);
	},
	clearHere() {
		const key = store.get().activeKey;
		if (key !== null) store.clearHistory(key);
	},
	ignore(name) {
		store.ignore(name);
	},
	unignore(name) {
		return store.unignore(name);
	},
	ignored() {
		return [...store.get().ignored].sort();
	},
	editLast(text) {
		const key = store.get().activeKey;
		const last = key === null ? null : lastLineOfOurs(key);
		if (key === null || last === null) return false;
		editLine(key, last.id, text);
		return true;
	},
	withdrawLast() {
		const key = store.get().activeKey;
		const last = key === null ? null : lastLineOfOurs(key);
		if (key === null || last === null) return false;
		withdraw(key, last.id);
		return true;
	},
	setTopic(text) {
		const conv = store.activeConv();
		const room = conv === null ? undefined : convSession(conv.key)?.rooms.get(conv.key);
		if (conv?.type !== "room" || room === undefined || !room.canSetTopic) return false;
		// The room answers everybody with the change, this tab included, so there
		// is nothing to apply here: what is on screen comes back off the wire.
		room.setTopic(text).catch((error) => {
			store.deliverActive(store.sysItem(`Could not set the topic: ${reason(error)}`));
		});
		return true;
	},
	setAway(why) {
		const conv = store.activeConv();
		const room = conv === null ? undefined : convSession(conv.key)?.rooms.get(conv.key);
		if (conv?.type !== "room" || room === undefined) return false;
		// The room tells everybody, this tab included, so nothing is applied here:
		// what shows is the room's word rather than this tab's intention.
		room.away(why).catch((error) => {
			store.deliverActive(store.sysItem(`Could not say that: ${reason(error)}`));
		});
		return true;
	},
	granted() {
		const conv = store.activeConv();
		return conv?.type === "room" ? conv.grants : NO_GRANTS;
	},
	liveRooms() {
		return store.actingDir()?.liveRooms ?? new Map();
	},
	roster() {
		const conv = store.activeConv();
		if (conv?.type !== "room") return [];
		const reachable = store.actingDir()?.dmablePeers ?? new Set<string>();
		return [...conv.members].map(([name, standing]) => ({
			name,
			online: standing.online,
			away: standing.away,
			reachable: reachable.has(name.toLowerCase()),
		}));
	},
	quitDirectory() {
		const dir = store.activeConv()?.dir ?? store.actingDir()?.id ?? null;
		if (dir === null) {
			store.deliverActive(store.sysItem("There is no directory to give back."));
			return;
		}
		leaveDirectory(dir);
	},
};

/** Send whatever is in the composer to whatever is on screen. */
export function send(): void {
	const draft = store.activeDraft();
	const text = draft.text.trim();
	const files = [...draft.files];
	const conv = store.activeConv();
	if ((!text && files.length === 0) || !conv) return;
	if (!isConnected()) {
		store.deliverActive(store.sysItem("Not connected, your message was not sent"));
		return;
	}
	// Measured against what this room will carry, which may be less than this app
	// allows — a bridged room has to fit its lines into somebody else's protocol.
	// In bytes, because that is what the limit on the other side counts.
	const cap = lineRoom(conv, MAX_LINE);
	if (lineCost(text) > cap) {
		store.deliverActive(store.sysItem(tooLong("Message", cap)));
		return;
	}
	// Changing a line the reader pressed the pencil on. Taken before the command
	// reading below, because these words are the message being rewritten rather
	// than an instruction: somebody fixing a line that began with a slash is
	// still fixing a line.
	if (draft.changing !== undefined) {
		// Emptied only once the change is on its way. A refusal here keeps the
		// reader's words and the line they belong to, so the composer is still
		// where they left it rather than blank with an explanation above it.
		if (editLine(conv.key, draft.changing, text)) store.cancelChange();
		return;
	}
	// A slash command runs before anything is sent, and what it hands back is
	// what the ordinary path then carries — so a command cannot post something
	// this function would have refused, and there is still one place that decides
	// what reaches a room.
	const named = commandIn(text);
	let said = text;
	if (named !== null) {
		const outcome = named.command.run(named.rest, POWERS, conv);
		if (outcome.kind === "done") {
			store.setDraft("");
			store.clearDraftFiles();
			return;
		}
		if (outcome.kind === "refused") {
			store.deliverActive(store.sysItem(outcome.why));
			return;
		}
		if (outcome.kind === "action" && files.length > 0) {
			store.deliverActive(store.sysItem("An /me action cannot carry files; send them as a separate message."));
			return;
		}
		said = outcome.kind === "action" ? `/me ${outcome.text}` : outcome.text;
	}
	if (files.length > MAX_MESSAGE_FILES) {
		store.deliverActive(store.sysItem(`A message may carry at most ${MAX_MESSAGE_FILES} files.`));
		return;
	}
	if (conv.type === "dm" && files.reduce((sum, file) => sum + file.size, 0) > MAX_DIRECT_ATTACHMENT_BYTES) {
		store.deliverActive(
			store.sysItem(`A direct message may carry at most ${MAX_DIRECT_ATTACHMENT_BYTES / (1024 * 1024)} MB.`),
		);
		return;
	}
	try {
		for (const file of files) validateAttachmentSource(pickedSource(file));
	} catch (err) {
		store.deliverActive(store.sysItem(reason(err)));
		return;
	}
	// A room echoes every post back to every member, which is what confirms our
	// own line. A direct message has no echo, so it is confirmed by the send
	// settling instead.
	if (files.length > 0) {
		sendFiles(conv, files, said);
	} else if (conv.type === "room") sayLine(conv, said);
	else dmSay(conv, said);
	store.setDraft("");
	store.clearDraftFiles();
}

/** Attach picked, dropped, or pasted files to the conversation on screen.
 *
 * What fits is taken and the rest is refused here, at the gesture, rather than
 * at Send. A file the attachment contract refuses keeps its place in the
 * composer so a reader can correct it, and that only works while correcting is
 * something a person would do: dropping a folder of photos on a message that
 * carries eight is an ordinary gesture, and it used to build a row of chips the
 * reader then had to take apart one press at a time before anything could be
 * sent at all. */
export function addFiles(files: readonly File[]): void {
	if (files.length === 0) return;
	const room = MAX_MESSAGE_FILES - store.activeDraft().files.length;
	if (room <= 0) {
		store.deliverActive(
			store.sysItem(`This message already carries ${MAX_MESSAGE_FILES} files, which is as many as one can.`),
		);
		return;
	}
	store.addDraftFiles(files.slice(0, room));
	const over = files.length - room;
	if (over > 0) {
		store.deliverActive(store.sysItem(
			`A message may carry at most ${MAX_MESSAGE_FILES} files, so ${
				over === 1 ? "one file was" : over + " files were"
			} left out. ` +
				`Send this one and the rest can follow.`,
		));
	}
}

/** Put an @mention of `who` into the composer, from the toolbar on a message. */
export function mention(who: string): void {
	// The conversation on screen's own draft, which is the one the message this
	// came from is sitting in.
	const text = store.activeDraft().text;
	const gap = text && !/\s$/.test(text) ? " " : "";
	store.setDraft(text + gap + "@" + who + " ");
}

export function setDraft(text: string): void {
	store.setDraft(text);
}

/**
 * Say a line into `conv`'s room. We paint our own line at once as "sending"; the room
 * echoes it back to every member, which confirms it (see `pump`). A rejected post marks
 * the line failed with a retry control instead of vanishing.
 */
function sayLine(conv: RoomConv, text: string): void {
	const item = store.chatItem(store.dirNick(conv.dir), text, true, "sending");
	store.deliver(conv.key, item);
	convSession(conv.key)?.echoes.push({ key: conv.key, id: item.id, attachmentIds: [], text });
	postRoomLine(conv.key, item.id, text);
}

// Re-arm a failed line as "sending" and post it again. The line is already in the
// conversation, so this changes it in place rather than adding a fresh one.
function resendRoomLine(key: string, id: number, text: string): void {
	markSend(key, id, "sending");
	convSession(key)?.echoes.push({ key, id, attachmentIds: [], text });
	postRoomLine(key, id, text);
}

// Post a line to one room, marking it failed if we are not in that room or the post
// rejects. Success is silent: the room's echo confirms the line through `confirmRoomEcho`.
/** Said wherever this tab holds a room's conversation but no membership on the
 * live session behind it. Both ways back are named because which one applies
 * turns on something the reader cannot see: a connection part way back re-enters
 * every room it holds a moment later, while a re-entry that was refused waits for
 * them to ask for it. Without this the send looks like a broken control. */
const NOT_IN_THIS_ROOM =
	"Not in this room at the moment. It is re-entered when the connection returns, or press it in the room list to go back in now.";

function postRoomLine(key: string, id: number, text: string): void {
	const room = convSession(key)?.rooms.get(key);
	if (!room) {
		failRoomSend(key, id);
		store.deliver(key, store.sysItem(NOT_IN_THIS_ROOM));
		return;
	}
	room.say(text)
		.then((line) => {
			// A room that answers with a reference is one whose lines can be
			// changed; an older one answers with nothing and the line is simply
			// said. Either way the post succeeded, so the absence is remembered as
			// an absence rather than treated as a failure.
			if (line === null) return;
			convSession(key)?.posted.set(id, line);
			// Holding the reference is what the pencil and the close act on, so the
			// bubble is told: they are drawn from this rather than from authorship.
			store.holdLine(key, id);
		})
		.catch(() => failRoomSend(key, id));
}

/** Send files to the active room or direct conversation.
 *
 * The line is painted at once as sending. A room admits each file, publishes
 * their one message, then drives its uploads in parallel. A direct message
 * grants sender-hosted blob capabilities over the selected peer session.
 */
function sendFiles(conv: RoomConv | DmConv, files: File[], caption: string): void {
	// Being offline is answered first, because it is the case a reader can act
	// on. Only once there is a session does "we are not in that room" mean
	// anything, and that one stays silent: the composer is not reachable from a
	// room this tab has left.
	if (!isConnected()) {
		store.deliverActive(store.sysItem("Not connected, your files were not sent"));
		return;
	}
	// Held conversation, no membership behind it. This used to return without a
	// word, and the composer is cleared either way, so the files and their caption
	// were dropped in silence. Saying it and then going on is what keeps them: the
	// ordinary failure path paints the bubble, marks it unsent, and holds the
	// picked files for the retry that carries them when the room is back.
	if (conv.type === "room" && !convSession(conv.key)?.rooms.has(conv.key)) {
		store.deliver(conv.key, store.sysItem(NOT_IN_THIS_ROOM));
	}
	const attachments = files.map((file) =>
		store.attachmentView({
			name: file.name,
			mime: file.type || "application/octet-stream",
			size: file.size,
		})
	);
	const item = store.chatItem(
		store.dirNick(conv.dir),
		caption || files[0].name,
		true,
		"sending",
		attachments,
	);
	store.deliver(conv.key, item);
	// The session owns the picked files, the upload, and the stop that ends it. It
	// was here a moment ago, when this refused to run offline, and if it has gone
	// in between there is nothing to own this send: the bubble was already drawn
	// as going, and nothing left would ever settle it or answer its Stop.
	const owner = convSession(conv.key);
	if (owner === null) {
		markSend(conv.key, item.id, "refused");
		store.deliver(conv.key, store.sysItem("The connection went before these files could be sent."));
		return;
	}
	owner.outgoing.set(item.id, {
		key: conv.key,
		attachmentIds: attachments.map((file) => file.id),
		files,
		caption,
	});
	void uploadPickedFiles(conv.key, item.id);
}

/** Send one of our own file messages: the first attempt, and every retry. The
 * files are held on the session by message id, so a retry sends them together
 * rather than re-posting the caption on its own. */
async function uploadPickedFiles(key: string, id: number): Promise<void> {
	// Both of these leave a bubble already drawn as going, so neither may return
	// in silence: nothing else settles a send whose owner is not there to fail.
	const owner = convSession(key);
	if (owner === null) {
		markSend(key, id, "refused");
		return;
	}
	const outgoing = owner.outgoing.get(id);
	if (outgoing === undefined) {
		markSend(key, id, "refused");
		return;
	}
	const { attachmentIds, files, caption } = outgoing;
	// A fresh one per attempt: a retry after a stop must not inherit the trip
	// that ended the last one.
	const stop = new AbortController();
	outgoing.stop = stop;
	try {
		const measured = await Promise.all(
			files.map((file) => measureImage(file, file.type || "application/octet-stream")),
		);
		// Measuring an image yields to the browser. Closing the conversation or
		// reconnecting during that yield removes this exact outgoing attempt; do
		// not recreate its URLs or send it after its owner has gone.
		const conv = store.getConv(key);
		if (!isCurrent(owner) || owner.outgoing.get(id) !== outgoing || conv === null) return;
		const item = conv.history.find((row) => row.id === id);
		const direct = conv.type === "dm";
		const sources = files.map((file, index) => {
			const mime = file.type || "application/octet-stream";
			const dimensions = measured[index];
			const attachment = item?.kind === "chat"
				? item.attachments?.find((candidate) => candidate.id === attachmentIds[index])
				: undefined;
			if (
				attachment !== undefined && attachment.url === undefined &&
				(direct || mime.startsWith("image/"))
			) {
				store.updateAttachment(key, attachmentIds[index], {
					url: keepObjectUrl(owner, attachmentIds[index], file),
					...dimensions,
				});
			} else store.updateAttachment(key, attachmentIds[index], dimensions);
			return {
				...pickedSource(file),
				...dimensions,
			};
		});
		if (conv?.type === "room") {
			// The room this message belongs to, not whichever one is on screen: a
			// reader may switch rooms while an upload runs, and the bytes still owe
			// their bubble.
			const room = owner.rooms.get(key);
			// Read by a person: this becomes the reason under each file in the
			// bubble, so it says the state rather than naming the table it failed
			// to find a row in.
			if (!room) throw new Error("not in this room at the moment");
			const uploads = await Promise.all(sources.map((source) => room.stage(source)));
			// Staging yields. Leaving the conversation or losing this session in
			// that window removes the outgoing owner; discard what was admitted
			// instead of publishing a message after its bubble was torn down.
			if (!isCurrent(owner) || owner.outgoing.get(id) !== outgoing || store.getConv(key) === null) {
				await Promise.allSettled(uploads.map((upload) => room.discard(upload)));
				return;
			}
			owner.echoes.push({ key, id, attachmentIds, text: caption || files[0].name });
			try {
				await room.postFiles(caption);
			} catch (error) {
				await Promise.allSettled(uploads.map((upload) => room.discard(upload)));
				throw error;
			}
			await Promise.all(
				uploads.map((upload, index) =>
					room.upload(
						upload,
						sources[index],
						(sent) => noteAttachmentProgress(owner, key, attachmentIds[index], sent),
						stop.signal,
					)
				),
			);
		} else if (conv?.type === "dm") {
			await deliverDm(conv, caption || files[0].name, sources);
			markSend(key, id, undefined);
			store.setDmLine(key, "live");
		} else throw new Error("conversation closed");
		commitAttachmentUpdates(
			owner,
			key,
			new Map(attachmentIds.map((fileId) => [fileId, { got: undefined, error: undefined }])),
		);
		owner.outgoing.delete(id);
		// Everything this message carries is on the room now. The echo may have
		// come and gone while the bytes were going up, in which case it left the
		// bubble sending for this to clear.
		if (!owner.echoes.some((row) => row.id === id)) markSend(key, id, undefined);
	} catch (err) {
		const conv = store.getConv(key);
		if (conv?.type === "room") failRoomSend(key, id, owner);
		else markSend(key, id, "failed");
		// The bytes never reached the room, so there is nothing for a file row to
		// fetch: the failed message's own retry is what sends them, and it clears
		// these when it does. Two controls for one failure, one of which cannot
		// work, is worse than the one that can.
		const why = reason(err);
		commitAttachmentUpdates(
			owner,
			key,
			new Map(attachmentIds.map((fileId) => [fileId, { got: undefined, error: why, lost: true }])),
		);
	}
}

/** Stop a send whose bytes are still going.
 *
 * The message is already posted by the time its files are being filled — that
 * order is what lets a bubble appear before its pictures do — so this cannot
 * un-say it. What it does is give back the rest of the reader's bandwidth and
 * leave the send where a stopped one belongs: not sent, with the retry the
 * interface already offers on anything that did not arrive. Stopping and
 * retrying are the same pair the failure path already has, so a reader who
 * picked the wrong sixty-megabyte file has somewhere to go that is not waiting.
 *
 * Only the bytes are tripped. Everything after is the ordinary failure path,
 * which already marks the message and records why against each file. */
export function stopSend(key: string, id: number): void {
	convSession(key)?.outgoing.get(id)?.stop?.abort();
}

/** Withdraw a line already posted, by the reference the room answered with. */
export function withdraw(key: string, id: number): void {
	const line = convSession(key)?.posted.get(id);
	if (line === undefined) {
		// No reference means no authority, and the two reasons a reader can be in
		// that position are worth telling apart: a line somebody else posted was
		// never theirs to take back, and a line from before this connection was
		// lost with the session that carried it.
		store.deliverActive(store.sysItem("That line cannot be taken back from here."));
		return;
	}
	line.withdraw().catch((error) => {
		store.deliverActive(store.sysItem(`Could not take that line back: ${reason(error)}`));
	});
}

/** Change a line already posted, by the reference the room answered with. */
export function editLine(key: string, id: number, text: string): boolean {
	const line = convSession(key)?.posted.get(id);
	if (line === undefined) {
		store.deliverActive(store.sysItem("That line cannot be changed from here."));
		return false;
	}
	line.edit(text).catch((error) => {
		store.deliverActive(store.sysItem(`Could not change that line: ${reason(error)}`));
		// The rewrite lives nowhere else. The log still shows the words the line
		// was posted with, because a change is drawn when the room confirms it,
		// and the composer was emptied when this was dispatched — so a failure
		// here used to take the rewrite with it. Put it back where the reader left
		// it, unless they have started something else there or the line has since
		// stopped being ours to change.
		const draft = store.activeDraft();
		if (
			store.activeConv()?.key === key && draft.text === "" && draft.files.length === 0 &&
			draft.changing === undefined && convSession(key)?.posted.has(id) === true
		) {
			store.startChange(id, text);
		}
	});
	return true;
}

/** The most recent line of our own in this conversation that can still be
 * changed, which is what `/edit` and `/delete` act on when nobody names one.
 *
 * The last one is what somebody typing `/edit` means: they have just said
 * something and seen it come out wrong. Anything older is reached by pressing
 * the line itself, where there is no guessing to do. */
export function lastLineOfOurs(key: string): { id: number; text: string } | null {
	const owner = convSession(key);
	const conv = store.getConv(key);
	if (owner === null || conv === null) return null;
	for (let at = conv.history.length - 1; at >= 0; at--) {
		const item = conv.history[at];
		if (item.kind !== "chat" || !item.mine || item.withdrawn) continue;
		if (owner.posted.has(item.id)) return { id: item.id, text: item.text };
	}
	return null;
}

/** Re-send a failed file message: every file, not just its caption. */
function resendFile(key: string, id: number): void {
	const outgoing = convSession(key)?.outgoing.get(id);
	if (outgoing === undefined) return;
	markSend(key, id, "sending");
	for (const fileId of outgoing.attachmentIds) {
		store.updateAttachment(key, fileId, { error: undefined, lost: undefined });
	}
	void uploadPickedFiles(key, id);
}

/** A picture's own pixel size, or nothing when it is not one or the browser
 * will not decode it. Sent with the file so every reader can leave the right
 * space before the bytes arrive, which is what keeps a log of images from
 * jumping as each one lands. */
async function measureImage(
	file: File,
	mime: string,
): Promise<{ width?: number; height?: number }> {
	if (!mime.startsWith("image/")) return {};
	try {
		const bitmap = await createImageBitmap(file);
		const size = { width: bitmap.width, height: bitmap.height };
		bitmap.close();
		return size;
	} catch {
		// An image this browser cannot decode still posts; it just arrives
		// without a shape to reserve.
		return {};
	}
}

/** Said wherever this window finds it no longer holds a file's reference. It
 * reads as a fact about this window rather than about the room, because the
 * room may well still have the bytes: what ended was the connection they were
 * offered over. */
const FILE_GONE_WITH_ITS_CONNECTION = "this file came over an earlier connection and cannot be fetched again";

/** Fetch a posted file's bytes and hand it an object URL to draw or download
 * from. Idempotent: a file already holding its bytes, or already
 * fetching them, is left alone. */
export function openAttachment(key: string, id: number): void {
	const conv = store.getConv(key);
	const item = conv?.history.find((line) => line.kind === "chat" && line.attachments?.some((file) => file.id === id));
	const attachment = item?.kind === "chat" ? item.attachments?.find((file) => file.id === id) : undefined;
	if (attachment === undefined) return;
	if (attachment.url !== undefined || attachment.got !== undefined) return;
	// Nothing left to try for this one: it says why, and its row has already
	// dropped the control that would ask. Checked here because the viewer steps
	// through pictures by asking for them, so it reaches this without a press.
	if (attachment.lost === true) return;
	// A file reference is only good on the connection it arrived over, and this
	// window holds none for this one. Pressing again would land here again, so
	// the row says what happened and stops offering.
	const owner = convSession(key);
	const row = owner?.files.get(id);
	if (owner === null || row === undefined) {
		store.updateAttachment(key, id, { error: FILE_GONE_WITH_ITS_CONNECTION, lost: true });
		return;
	}
	commitAttachment(owner, key, id, { got: 0, error: undefined });
	row.fetch((got) => {
		if (isCurrent(owner) && owner.files.get(id) === row) noteAttachmentProgress(owner, key, id, got);
	})
		.then((bytes) => {
			// Conversation teardown releases and removes the held capability. A
			// fetch that settled at the same time must not mint a URL after that
			// cleanup, or attach its bytes to a later session.
			if (!isCurrent(owner) || owner.files.get(id) !== row) return;
			row.release();
			owner.files.delete(id);
			commitAttachment(owner, key, id, {
				got: undefined,
				url: keepObjectUrl(owner, id, blobOf(bytes, row.attachment.mime)),
			});
		})
		.catch((err) => {
			if (!isCurrent(owner) || owner.files.get(id) !== row) return;
			// A room drops its oldest files to stay under its media ceiling, and
			// keeps saying so on every later read. Nothing brings that one back,
			// so the row must not go on inviting a press.
			const evicted = roomErrorOf(err)?.code === BLOB_EXPIRED;
			commitAttachment(owner, key, id, { got: undefined, error: reason(err), lost: evicted ? true : undefined });
		});
}

/** Move the viewer through this conversation's images, fetching the next one
 * on demand through the same transfer path as an explicit press in the log. */
export function stepViewer(direction: ViewerDirection): void {
	const key = store.get().viewing?.key;
	const file = store.stepViewer(direction);
	if (key !== undefined && file !== null && file.url === undefined) openAttachment(key, file.id);
}

function holdRoomFile(room: Room, attachment: Attachment): HeldFile {
	return {
		attachment,
		fetch: (onProgress) => room.fetch(attachment, onProgress),
		release: () => {
			try {
				room.release(attachment);
			} catch {
				// The room session already reclaimed it.
			}
		},
	};
}

function holdDirectFile(
	session: Session,
	attachment: Attachment,
): HeldFile {
	return {
		attachment,
		fetch: (onProgress) => fetchBlob(session, attachment, onProgress),
		release: () => {
			try {
				session.release(attachment.blob);
			} catch {
				// The direct session already reclaimed it.
			}
		},
	};
}

/** A Blob over exactly these bytes. Copied into an array of its own because a
 * `Uint8Array` may be a view into a larger buffer, and because `BlobPart`
 * admits an `ArrayBuffer` but not the `SharedArrayBuffer` a view's type
 * allows. */
function blobOf(bytes: Uint8Array, mime: string): Blob {
	const own = new Uint8Array(bytes.byteLength);
	own.set(bytes);
	return new Blob([own.buffer], { type: mime });
}

/** One browser file as the shared attachment layer reads it. The description
 * is also validated before Send clears the composer, so refusal preserves the
 * reader's draft and attached chips. */
function pickedSource(file: File): AttachmentSource {
	return {
		name: file.name,
		mime: file.type || "application/octet-stream",
		size: file.size,
		read: async (offset: number, length: number) =>
			new Uint8Array(await file.slice(offset, offset + length).arrayBuffer()),
	};
}

/** Mint the object URL one file owns, replacing any retry's prior URL. The
 * session is the one whose capability produced the bytes, and it is what the URL
 * is released with when that directory goes. */
function keepObjectUrl(owner: Live, id: number, blob: Blob): string {
	const url = URL.createObjectURL(blob);
	const old = owner.objectUrls.get(id);
	if (old !== undefined) URL.revokeObjectURL(old);
	owner.objectUrls.set(id, url);
	return url;
}

/** Release every object URL and blob capability this session minted. */
function releaseFiles(session: Live): void {
	if (session.progress.frame !== null) cancelAnimationFrame(session.progress.frame);
	session.progress.frame = null;
	session.progress.pending.clear();
	for (const url of session.objectUrls.values()) URL.revokeObjectURL(url);
	session.objectUrls.clear();
	for (const row of session.files.values()) row.release();
	session.files.clear();
	session.outgoing.clear();
	// A fetch still running has just lost the reference it was reading from, and
	// nothing will settle it now. Its row is drawn as loading, and a row that is
	// loading is one `openAttachment` refuses to restart, so left alone it
	// shimmers at nothing for the life of the tab, with no control to press.
	for (const conv of store.get().convs.values()) {
		if (conv.dir !== session.id) continue;
		const stalled = new Map<number, store.AttachmentFields>();
		for (const item of conv.history) {
			if (item.kind !== "chat") continue;
			for (const file of item.attachments ?? []) {
				if (file.got === undefined) continue;
				stalled.set(file.id, { got: undefined, error: FILE_GONE_WITH_ITS_CONNECTION, lost: true });
			}
		}
		store.updateAttachments(conv.key, stalled);
	}
}

/** Release media whose conversation history is about to disappear. */
function releaseConversationFiles(session: Live, conv: RoomConv | DmConv): void {
	const fileIds: number[] = [];
	for (const item of conv.history) {
		if (item.kind !== "chat") continue;
		for (const attachment of item.attachments ?? []) {
			fileIds.push(attachment.id);
			const held = session.files.get(attachment.id);
			if (held !== undefined) held.release();
			session.files.delete(attachment.id);
			const url = session.objectUrls.get(attachment.id);
			if (url !== undefined) URL.revokeObjectURL(url);
			session.objectUrls.delete(attachment.id);
		}
		session.outgoing.delete(item.id);
	}
	discardAttachmentProgress(session, conv.key, fileIds);
}

// A room line that cannot be confirmed: drop it from the echo queue and tint it failed.
function failRoomSend(key: string, id: number, session: Live | null = convSession(key)): void {
	if (session === null) {
		// No session is no echo queue, and so nothing this line could be waiting
		// on: mark it. Returning here instead left a retry pressed while the
		// directory was away drawn as still going, for good — the optimistic tint
		// says the room has it, and nothing was ever coming to say otherwise.
		markSend(key, id, "failed");
		return;
	}
	const at = session.echoes.findIndex((row) => row.id === id);
	// Already off the queue means the room echoed this line back and
	// `confirmRoomEcho` cleared it. A `say` that rejects afterwards is reporting
	// on a line the room demonstrably received, so tinting it failed here would
	// contradict the echo the user can see.
	if (at < 0) return;
	const [row] = session.echoes.splice(at, 1);
	markSend(row.key, row.id, "failed");
}

// A room echoed a line back to us. If it matches an optimistic send still in
// flight *in that room*, confirm that message in place (clear its "sending"
// tint) and return its attachment ids, so `pump` does not paint a second copy
// and can attach the room's blob capabilities to the bubble already on screen.
// Null means this is not our echo.
//
// The conversation is half the match, not a detail: the same text may be in
// flight in two rooms at once, and matching on text alone would confirm the
// wrong bubble and leave the right one tinted for good.
function confirmRoomEcho(key: string, text: string): Live["echoes"][number] | null {
	const owner = convSession(key);
	if (owner === null) return null;
	const at = owner.echoes.findIndex((row) => row.key === key && row.text === text);
	if (at < 0) return null;
	const [row] = owner.echoes.splice(at, 1);
	// A room echoes a line the moment it is posted, and a file message's bytes go
	// up after that. Such a message is not delivered until they have: a reader who
	// presses it in that window waits on the room, and a session lost there leaves
	// everyone a file with nothing behind it. So whichever of the echo and the
	// last byte lands second is the one that clears the flag.
	if (!owner.outgoing.has(row.id)) markSend(row.key, row.id, undefined);
	return row;
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
	if (conv == null) return;
	convSession(conv.key)?.rooms.get(conv.key)?.setTyping(on).catch(() => {});
}

/** A typing flag rides only a route that already exists — the reply
 * capability the peer handed us, or an introduced line already open
 * (or opening). An ephemeral signal must never cause a dial. */
function sendDmTyping(key: string, on: boolean): void {
	const session = convSession(key);
	if (session === null) return;
	const back = session.backChannels.get(key);
	if (back !== undefined && back.session.sessionOpen) {
		back.session.tell(back.reply, TYPING, [on]).catch(() => {});
		return;
	}
	session.lines.get(key)?.then((line) => line.typing(on)).catch(() => {});
}

// ── Rooms: picking, creating, joining ─────────────────────────────────────
/** Tapping a room in the rail: show it if we are in it, otherwise enter it.
 *
 * Entering is additive, so picking a second room does not give up the first.
 * That is the whole difference multi-room makes here, and it is why this asks
 * whether we hold *that* room rather than whether we hold any. */
export function pickRoom(dir: DirId, name: string): void {
	const s = store.get();
	const key = store.roomKey(dir, name);
	// Whether pressing this room means asking to be back in it. Being in a room is
	// holding a membership on the live session, and a conversation on screen is not
	// that: a re-entry refused after a reconnect, or a message stream that broke
	// under a live one, leaves the history here and the membership gone. This is
	// the way back, and short of leaving a room they can still read it is the only
	// one. A session that is away keeps the ordinary behaviour, because its own
	// reconnect re-enters every room it holds.
	const held = dirSession(dir);
	const named = (store.dirNick(dir) || s.draftNick) !== "";
	const backIn = held !== null && named && store.isJoinedRoom(dir, name) && !held.rooms.has(key);
	// Pressing the room being read is how a reader puts the rail away, unless it
	// is the room that has stopped working, in which case they are asking for the
	// one thing that would fix it.
	if (key === s.activeKey && !backIn) {
		store.showRail(false);
		return;
	}
	if (backIn) {
		enterPickedRoom(dir, name);
		return;
	}
	// Being in a room is something this tab knows, not something the connection
	// has to confirm: the conversation and its history are already here. So a room
	// already open is shown whatever its directory is doing — including while that
	// directory is reconnecting, which is exactly when a reader goes looking for
	// what was said. Gating this on a live session meant a directory dropping
	// turned every room on it into a join card: the reader was put in front of a
	// form asking them to enter a room they were already in, with the history they
	// wanted sitting behind it. The composer says what the directory is doing, so
	// nothing here has to pretend the room can be written to.
	if (store.isJoinedRoom(dir, name)) {
		store.switchTo(key);
		return;
	}
	// Entering one is different: that does need a session and a name on it.
	if (named && held !== null) {
		enterPickedRoom(dir, name);
		return;
	}
	// No name granted yet, so this is a request to join that one. Fill the card in
	// and put it up: it used to only set the field, which worked while the card
	// happened to be showing and stranded a reader who had a direct message open,
	// because the field it filled was behind it.
	store.setDrafts({ draftRoom: name });
	store.showJoinCard();
}

/** Show the join card so a reader can name a room in a directory this tab does not
 * hold yet.
 *
 * Nothing is left and nothing is closed: the card is the conversation column
 * standing empty, and every room and direct line is still there behind it. That
 * is what makes this the step up from the rail's own field rather than a way
 * out of where you are. */
export function addDirectory(room: string, locator = ""): void {
	store.setDrafts({ draftRoom: room, draftLocator: locator });
	// The card is all that opens. On a phone `showJoinCard` already steps back
	// from the list screen to the conversation column the card fills; on a wide
	// layout the rail is a column beside it and closing it would take the rooms
	// away at the moment the reader most wants to see which ones they have.
	store.showJoinCard();
}

/** Say what is known about one directory.
 *
 * The page's own directory opens Settings, because Settings is already about
 * this directory and nothing else — a second surface repeating its locator and
 * its connection would be two authorities for one set of facts. Every other
 * directory opens a card, which is what keeps Settings from ever having to say
 * *which* directory it is describing.
 *
 * Null closes whichever card is open. */
export function aboutDirectory(dir: DirId | null): void {
	if (dir === null) {
		store.showAboutDir(null);
		return;
	}
	if (dir === store.get().homeDir) {
		store.openSettings();
		return;
	}
	store.showAboutDir(dir);
}

function enterPickedRoom(dir: DirId, name: string): void {
	userPickedRoom = true;
	store.setStatus("entering #" + name + "…");
	void enterRoom(dir, name, store.dirNick(dir) || store.get().draftNick);
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
 * A directory that is merely unreachable does not settle it as a refusal and then
 * forget: the request stays staged and the next session that opens replays it. */
export async function joinRoom(destination: RoomDestination, nick: string): Promise<string> {
	const room = destination.room;
	let locator: string;
	try {
		locator = await requestedLocator(destination.locator);
	} catch (err) {
		return reason(err);
	}
	store.setPreferredNick(nick);
	store.setDrafts({ draftRoom: room, draftLocator: destination.locator });

	// Changing directories is changing peers, not changing a field on the live
	// room capability. Stage the intent, close the old directory session, and let
	// the ordinary reconnect spine establish the selected peer before it replays
	// the join. This path is only exposed on the join card, after leaving a room,
	// so no live membership is sacrificed to probe an address.
	// A room somewhere else is a directory this tab does not hold yet, so open it
	// beside the ones it does. Nothing is closed and nothing is given up: the
	// rooms already entered keep delivering while this one is being reached, and
	// an address that turns out to be wrong costs a failed dial rather than a
	// membership.
	const wanted = directoryId(locator);
	if (wanted === null) return notALocator(locator);
	if (locator !== "" && !store.get().dirs.has(wanted)) {
		store.setStatus("reaching " + locator + "…");
		const opened = await openDirectory(locator, FIRST_BACKOFF_MS);
		if (opened !== "") return opened;
	}
	if (!isConnected()) {
		// One join is staged at a time, so anything still waiting is superseded by
		// this one and is let go rather than left pending on a card that has moved
		// on.
		settleStaged("");
		staged = { room, nick };
		store.setStatus("reaching the room directory…");
		return new Promise<string>((resolve) => {
			stagedSettle = resolve;
		});
	}
	store.setStatus("entering #" + room + "…");
	const entering = directoryId(locator);
	if (entering === null) return notALocator(locator);
	return enterRoom(entering, room, nick);
}

/** Leave one room, keeping every other room and direct line.
 *
 * A room is a capability and leaving it is telling the room so: the membership
 * is released, everyone else sees the departure, and the name frees up if we
 * were the last one in. The directory session stays up, so the live room list
 * keeps arriving and rejoining is one click.
 *
 * Where the reader lands afterwards depends on what they were looking at. Only
 * someone reading the room being left needs moving at all, and they go to
 * whatever else is open rather than back to the card — leaving one of three
 * rooms is not leaving the application. The card comes back only when nothing
 * is left to show, which is the one way back to it in a window with no reload:
 * a kiosk, an installed app, a browser someone handed you.
 */
export function leaveRoom(key: string): void {
	const owner = convSession(key);
	const room = owner?.rooms.get(key) ?? null;
	owner?.rooms.delete(key);
	// Read what is on screen before anything is cleared: every other conversation
	// stands on its own, so leaving this room should leave a reader where they
	// are unless this room *is* where they are.
	const wasReading = store.get().activeKey === key;
	const conv = store.getConv(key);
	if (owner && conv?.type === "room") releaseConversationFiles(owner, conv);
	store.forgetConv(key);
	if (wasReading) {
		const next = [...store.get().convs.keys()][0];
		if (next === undefined) store.showJoinCard();
		else store.switchTo(next);
	}
	store.setStatus(roomStatus());
	// A leave that fails leaves the room still holding the nick, which the next
	// join will discover as a name already taken. Nothing here can fix it, but a
	// silent version of it is very hard to recognise later.
	if (room) {
		void room.leave().catch((err) => console.error("rooms: could not leave the room:", reason(err)));
	}
}

/** The line under the rail: who we are and how much of the room list we are in.
 *
 * It names the room while there is one to name, because that is the question it
 * exists to answer and a direct message fills the conversation column without
 * answering it. Past one room a list would outgrow the line, so it counts. */
function roomStatus(): string {
	if (anyLive() === null) return "not connected";
	const rooms = store.joinedRooms();
	if (rooms.length === 0) return "pick a room";
	if (rooms.length === 1) return "in #" + rooms[0].id + " as " + store.dirNick(rooms[0].dir);
	// A name is one directory's grant, so across rooms on several directories
	// there may be no single answer to "as who". Saying the first room's name for
	// all of them is the kind of wrong that reads as right: it is a real name, on
	// a real directory, and it is not the one the other rooms know you by.
	const names = new Set(rooms.map((room) => store.dirNick(room.dir)));
	const only = names.size === 1 ? [...names][0] : "";
	return "in " + rooms.length + " rooms" + (only === "" ? "" : " as " + only);
}

/** The title's mark ends whatever it names: a room is left, a direct line is
 * closed. One control, because from the reader's side it is one gesture. */
export function endConversation(): void {
	const conv = store.activeConv();
	if (conv === null) return;
	if (conv.type === "dm") closeDm(conv);
	else leaveRoom(conv.key);
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
	const owner = dirSession(conv.dir);
	if (owner) releaseConversationFiles(owner, conv);
	store.forgetConv(key);
	// Hand the line's own connection back. A redeemed introduction holds one open
	// to the member for as long as the line lives, so forgetting the line here
	// without closing it would leave the connection and the reply inbox on it
	// standing with nothing on this side referring to them.
	if (owner) dropLine(owner, key);
	// The back-channel is the other direction: a connection the member opened to
	// us, captured as it arrived. It carries this conversation and nothing else
	// (a cold dial is per-peer), so closing the conversation closes it. Dropping
	// only the map entry left the session up with nothing on this side referring
	// to it, and the far end holding a line to a conversation that no longer
	// exists here.
	const back = owner?.backChannels.get(key);
	owner?.backChannels.delete(key);
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
	const next = [...store.get().convs.keys()][0];
	if (next === undefined) store.showJoinCard();
	else store.switchTo(next);
}

// Enter `name` as `nick`: subscribe to the room, which is a capability, and keep
// it beside every other room this session holds. Resolves with "" once we are
// in, or with the reason a reader needs to act on.
//
// Entering takes nothing away. A room already held is re-subscribed rather than
// duplicated, which the room reads as the same connection re-claiming its place
// and answers without telling the other members anything happened.
async function enterRoom(dir: DirId, name: string, nick: string, attempt = 0): Promise<string> {
	const session = dirSession(dir);
	if (session === null) {
		// Never silently: a caller that reaches here with no session has a live
		// "Joining…" button waiting on an answer that will not come.
		return "not connected to the room directory yet";
	}
	const key = store.roomKey(dir, name);
	try {
		const ref = await enterOrOpen(session.dir, name);
		const next = await Room.subscribe(
			session.dir.session,
			ref,
			nick,
			(from, on) => setRoomTyping(key, from, on),
		);
		if (!isCurrent(session)) {
			// The session was replaced while we were subscribing, so this room is
			// already unreachable. Drop it rather than filing it under a table the
			// reconnect has moved on from.
			void next.leave().catch(() => {});
			return "";
		}
		const prev = session.rooms.get(key);
		session.rooms.set(key, next);
		// A membership held on this same session has just been replaced by the
		// subscribe above, which the room treats as this connection re-claiming its
		// place. Only the old stream is ours to end: telling the room we are
		// leaving would take back the place we just re-took, because a departure is
		// keyed by connection and there is only one of those here.
		prev?.replaced();
		// Commit the nick we actually claimed. Two tabs of one browser share the
		// persisted nick, so a collision may have suffixed it below; reflect the
		// real name in the store so a member never sees a stale one.
		store.setDirNick(dir, nick);
		// Now that we hold a nick in a room, advertise our direct-message locator
		// (`webrtc` by default, the relay rendezvous from Settings / `?dm=relay`) so others
		// can introduce+redeem us for direct messages.
		advertisePresence(session);
		enteredRoom(dir, name);
		// What this membership was handed. Recorded after the conversation exists
		// and from the membership that answered, so a reader's command list is the
		// room's answer rather than this file's opinion of what rooms offer.
		store.setGrants(key, next.canSetTopic ? new Set(["topic"]) : new Set());
		void pump(dir, key, name, next);
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
			return await enterRoom(dir, name, candidate, attempt + 1);
		}
		if (re?.code === NICK_TAKEN) {
			store.showJoinCard();
			store.setStatus("pick another name");
			return re.detail;
		}
		if (store.joinedRooms().length === 0) {
			store.setStatus("could not join");
			return reason(err);
		}
		// Whoever asked for this set the foot to "entering #x…" or "rejoining N
		// rooms…". It speaks for the whole tab, nothing else refreshes it when an
		// attempt ends this way, and a run where every room refused left it
		// announcing an attempt that was over for the life of the session.
		store.setDirStatus(dir, roomStatus());
		// A room already on screen is one this is about, so it is where this goes,
		// named. A reconnect re-enters every room at once and a reader is reading
		// one of them: a bare reason in whichever conversation happened to be open
		// says nothing about which room stopped working, and the failed one goes on
		// sitting in the rail looking healthy.
		//
		// With no conversation for it yet, the reader is somewhere else with one in
		// front of them, so it goes there rather than sending them back to the card
		// and taking away the rooms that are working.
		if (store.getConv(key) !== null) {
			store.deliver(key, store.sysItem(`Could not re-enter #${name}: ${reason(err)}`));
		} else if (store.activeConv()) store.deliverActive(store.sysItem(reason(err)));
		else store.setBanner({ kind: "error", text: reason(err) });
		return "";
	}
}

// The room confirmed us. Make its conversation if this is the first entry, and
// show it only if the reader asked for it or has nothing else in front of them.
//
// Entering a room no longer replaces one, so it no longer takes the screen by
// default: a reconnect re-entering three rooms must not drag a reader through
// all three, and a room entered from the rail while reading another should not
// interrupt the one being read unless that is what the tap meant.
function enteredRoom(dir: DirId, name: string): void {
	store.rememberRoom(name);
	const conv = store.ensureRoom(dir, name);
	store.clearMembers(conv.key);
	// The foot answers "where am I" for the whole tab. It is the one line always
	// on screen whatever is open, which is why it carries this rather than the
	// conversation column: a direct message fills that column and used to leave
	// the question unanswered anywhere.
	//
	// Written against the directory the room is on, not against whichever one is
	// acting. Those are the same directory until the room being entered is on a
	// different one from the room being read — and then the line lands on the
	// directory being left and is read from the directory being entered, which
	// still holds whatever it last said. Entering the first room on a directory
	// reached from the join card left the foot reading "pick a room" for good.
	store.setDirStatus(dir, roomStatus());
	if (userPickedRoom || store.activeConv() === null) store.switchTo(conv.key);
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
async function pump(dir: DirId, key: string, name: string, room: Room): Promise<void> {
	const reader = room.messages.getReader();
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) return;
			if (dirSession(dir)?.rooms.get(key) !== room) {
				// This membership has been replaced or left, so a newer pump owns the
				// conversation. Drop this stream rather than leave it locked and
				// half-read; `for await` used to do this on return.
				//
				// The test is this room's own identity rather than a global "newest
				// pump" counter: rooms run side by side now, so entering a second one
				// must not silence the first.
				await reader.cancel().catch(() => {});
				return;
			}
			const { from, text, system, presence, facts, attachments, lineId, change } = value;
			const conv = store.ensureRoom(dir, name);
			if (presence) store.applyPresence(conv.key, presence);
			// A line the room says something *about* rather than a line being said.
			// Applied before anything else and then done with: an edit is not a new
			// message, so it must not be delivered, counted unread, or notified —
			// somebody fixing a typo should not light the tab up again.
			if (change === "edited" && lineId !== undefined) {
				store.applyLineChange(conv.key, lineId, { text, edited: true });
				continue;
			}
			if (change === "withdrawn" && lineId !== undefined) {
				store.applyLineChange(conv.key, lineId, { withdrawn: true });
				continue;
			}
			// What the room says about itself, which arrives the same way a
			// membership change does and is applied before the line is drawn: a
			// welcome that carries a topic should have set it by the time anything
			// under it is read.
			if (facts?.topic !== undefined) store.setTopic(conv.key, facts.topic);
			if (facts?.lineBytes !== undefined) store.setLineBytes(conv.key, facts.lineBytes);
			if (system) store.deliver(conv.key, store.sysItem(text));
			else {
				const nick = store.dirNick(dir);
				const mine = from === nick;
				// Our own line was painted optimistically; its echo confirms it in
				// place rather than painting a duplicate. A file we posted keeps the
				// local URL it is already showing, so its echo costs no download.
				const echoed = mine ? confirmRoomEcho(conv.key, text) : null;
				if (echoed !== null) {
					// The line was painted before the room had named it. Learning the
					// name here is what lets a later edit find it.
					if (lineId !== undefined) store.nameLine(conv.key, echoed.id, lineId);
					for (const [index, attachment] of attachments.entries()) {
						const id = echoed.attachmentIds[index];
						if (id !== undefined) dirSession(dir)?.files.set(id, holdRoomFile(room, attachment));
					}
				}
				if (echoed === null) {
					const views = attachments.map((attachment) =>
						store.attachmentView({
							name: attachment.name,
							mime: attachment.mime,
							size: attachment.size,
							width: attachment.width,
							height: attachment.height,
						})
					);
					const item = store.chatItem(from, text, mine, undefined, views.length > 0 ? views : undefined);
					store.deliver(conv.key, lineId === undefined ? item : { ...item, lineId });
					for (const [index, attachment] of attachments.entries()) {
						const view = views[index];
						dirSession(dir)?.files.set(view.id, holdRoomFile(room, attachment));
						// A picture appears rather than waiting behind a button, the way
						// it does in every chat client; anything larger is asked for.
						if (attachment.mime.startsWith("image/") && attachment.size <= AUTO_IMAGE_BYTES) {
							openAttachment(conv.key, view.id);
						}
					}
				}
				if (!mine && notifiesYou(text, nick)) {
					maybeNotify("#" + name + " · " + from, text);
				}
			}
		}
	} catch (err) {
		// Leaving a room ends the stream cleanly, which arrives as `done` above,
		// not here. Reaching this means something actually broke, and silence is
		// what made the missing-iterator failure take so long to find: the room
		// simply never spoke. Say so in the room it happened to, which is not
		// necessarily the one being read.
		if (dirSession(dir)?.rooms.get(key) === room) {
			// With the way back in the same breath. The connection is still up and
			// the room takes a re-claim on it, keeping this member's place and the
			// references to what they have already said, so there is something to
			// do here rather than a dead conversation and a reason for it.
			store.deliver(
				key,
				store.sysItem(
					`This room stopped delivering messages: ${reason(err)}. Type /join ${name} to re-enter it.`,
				),
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
	const here = actingDir();
	const nick = store.dirNick(here);
	if (nick && peer.toLowerCase() === nick.toLowerCase()) {
		store.deliverActive(store.sysItem("You can't start a direct message with yourself."));
		return;
	}
	store.switchTo(store.ensureDm(here, peer).key);
}

// Send a direct message to `peer`, opening the introduced line on first use. A
// DM has no echo, so paint our own line at once; a dial that can't land (a member
// reachable only over TCP, or one who has left) says so in the thread.
function dmSay(conv: DmConv, text: string): void {
	// The conversation, not the name. Resolving by name here would find whichever
	// conversation currently answers to it — which after the member left is a
	// different one, so a message typed into the thread on screen would land in
	// another, or open a line to whoever holds the name now.
	const item = store.chatItem(store.dirNick(conv.dir), text, true, "sending");
	store.deliver(conv.key, item);
	sendDm(conv.key, item.id, text);
}

// Open the introduced line (lazily on first use) and deliver one line to the peer,
// tracking the bubble's send state honestly. On success the bubble clears to confirmed;
// on failure it tints failed and offers retry, and a friendly note names why. A retry
// runs this again with the same bubble.
function sendDm(key: string, id: number, text: string): void {
	const conv = store.getConv(key);
	if (conv?.type !== "dm") return;
	const peer = conv.id;
	// A conversation whose member left is closed for good. The room has their
	// name back, so reaching for it now would find whoever holds it next — which
	// is the one thing this conversation must never quietly do.
	if (conv.line === "closed") {
		// Refused rather than failed: this one can never go, so it is drawn
		// without the retry that every other unsent line carries.
		markSend(key, id, "refused");
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
	deliverDm(conv, text)
		.then(() => {
			markSend(key, id, undefined);
			store.setDmLine(key, "live");
		})
		.catch((err) => {
			// The reader gets the friendly line; the devtools console gets what
			// actually happened. A direct message crosses a redeem, a dial, and a
			// carrier of its own, and every one of those failures reads as
			// "couldn't reach them" up here, so dropping the cause leaves nobody
			// anything to work from.
			console.error(`rooms: could not deliver a direct message to ${peer}:`, err);
			markSend(key, id, "failed");
			store.deliver(key, store.sysItem(dmFailureText(peer, err)));
		});
}

/** Deliver through whichever direct route this conversation owns. Text and
 * files make the same choice: an arriving reply capability first, otherwise an
 * introduced line. The attachment helper only sees the resulting Session, so
 * WebRTC, iroh, relay, and every other carrier stay below this boundary. */
async function deliverDm(
	conv: DmConv,
	text: string,
	sources: AttachmentSource[] = [],
): Promise<void> {
	const key = conv.key;
	const session = dirSession(conv.dir);
	if (session === null) throw new Error("not connected");
	let cached = session.backChannels.get(key);
	if (cached && !cached.session.sessionOpen) {
		session.backChannels.delete(key);
		cached = undefined;
	}
	const back = cached;
	try {
		if (back) {
			if (sources.length > 0) {
				await sendWithAttachments(back.session, back.reply, DM, [text], sources);
			} else await back.session.send(back.reply, DM, [text]);
			return;
		}
		const line = await openDm(conv);
		if (sources.length > 0) await line.sendFiles(sources, text);
		else await line.say(text);
	} catch (err) {
		// Let the dead line go so the next send retries: a stale back-channel
		// falls back to a fresh introduction, a stale introduction re-redeems.
		if (back) session.backChannels.delete(key);
		else dropLine(session, key);
		throw err;
	}
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
// opens the direct connection over the member's advertised transport. The
// line hosts a reply inbox on that connection, so a member's reply lands here and
// paints in the peer's DM thread — the member never dials us.
function openDm(conv: DmConv): Promise<DirectMessage> {
	const peer = conv.id;
	const key = conv.key;
	const session = dirSession(conv.dir);
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
	const line = DirectMessage.open(
		session.dir,
		peer,
		(text, attachments, via) => receiveDm(key, peer, text, attachments, via),
	);
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
function receiveDm(
	key: string,
	peer: string,
	text: string,
	attachments: Attachment[] = [],
	via: Session | null = null,
): void {
	store.setDmLine(key, "live");
	const views = attachments.map((attachment) =>
		store.attachmentView({
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
		})
	);
	const item = store.chatItem(peer, text, false, undefined, views.length > 0 ? views : undefined);
	store.deliver(key, item);
	if (via) {
		for (const [index, attachment] of attachments.entries()) {
			const view = views[index];
			convSession(key)?.files.set(view.id, holdDirectFile(via, attachment));
			if (attachment.mime.startsWith("image/") && attachment.size <= AUTO_IMAGE_BYTES) {
				openAttachment(key, view.id);
			}
		}
	}
	if (store.get().activeKey !== key) maybeNotify(peer, text || attachments[0]?.name || "sent a file");
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

// A room's typing signal, routed to the room that raised it. The key comes from
// the subscribe that installed this callback, because the signal arrives as a
// bare (nick, flag) pair with nothing on it to say which room it came from.
function setRoomTyping(key: string, from: string, on: boolean): void {
	const conv = store.getConv(key);
	if (conv === null || from === store.dirNick(conv.dir)) return;
	applyTyping(key, from, on);
}

/** Turn desktop notifications on or off, asking the browser the first time.
 * Returns a reason the reader should see when it cannot turn on, or null. */
export async function toggleNotify(): Promise<string | null> {
	const { notifyOn } = store.get();
	if (notifyOn) {
		store.setNotify(false);
		return null;
	}
	if (!("Notification" in globalThis)) {
		return "This browser can't show desktop notifications";
	}
	let permitted = Notification.permission;
	if (permitted === "default") permitted = await Notification.requestPermission();
	if (permitted !== "granted") {
		return "Notifications are blocked in your browser settings";
	}
	store.setNotify(true);
	return null;
}

function reason(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

// ── Connection ────────────────────────────────────────────────────────────
/** What a reader is told when an attempt to reach the room directory did not get
 * there. Two surfaces say it — the join card, which was waiting on a join, and
 * the status line, which is waiting on nothing — and they say the same thing
 * because it is one fact. */
const UNREACHABLE = "could not reach the room directory; retrying…";

/** Open the directory this page came from. The one directory a tab starts with;
 * every other one is added deliberately. */
export function connect(): void {
	void openDirectory(null, FIRST_BACKOFF_MS);
}

/** Hold one directory: open a session to `locator`, register there, and keep it
 * beside every other directory this tab holds.
 *
 * Opening takes nothing away. A directory already held is answered without
 * dialling a second time, so asking for one twice is not a way to lose the
 * rooms on it.
 *
 * `locator` of null means the directory that served this page. */
export async function openDirectory(locator: string | null, backoff: number): Promise<string> {
	try {
		// Install tracing before `init` creates the page's long-lived Runtime Host.
		await ensureVizPublisher();
		// Instantiate the wasm peer once; its adapter injection lets the runtime's
		// `connect` (which `Directory.connect` rides) dial over the relay. Cache
		// only a *resolved* init: `/pancake_host.wasm` answers 503 until the
		// module is built, so a first attempt can lose that race — a rejected
		// promise left cached would make every reconnect re-await the same failure
		// forever instead of retrying once the asset is live.
		if (runtimeReady === null) {
			const attempt = init({
				wasm: fetch("/pancake_host.wasm"),
				wsUrl: relayWsUrl,
				relayUrl: relayLocatorUrl,
				codec: CODEC,
				captpVersion: CAPTP_VERSION,
				connectors: [
					relay.connector(),
					webrtc.connector(directorySignalingAuthority(() => anyLive()?.dir ?? null)),
				],
			});
			attempt.catch(() => {
				if (runtimeReady === attempt) runtimeReady = null;
			});
			runtimeReady = attempt;
		}
		const runtime = await runtimeReady;
		// The inbox host both dials the directory and accepts cold-dials, so start
		// it before the dial: the directory session must be present in the same
		// host's live-session directory when a later cold-dial withdraws from that
		// session's gift table.
		ensureInbox(runtime);
		const target = locator ?? await homeLocator();
		const id = directoryId(target);
		if (id === null) return notALocator(target);
		directoryLocators.set(id, target);
		const held = dirs.get(id);
		if (held !== undefined) return "";
		// The one open with no locator of its own is the page's own server, and it
		// is the only one that can say so.
		if (locator === null) store.setHomeDir(id);
		store.openDir(id);
		store.setDirSession(id, "connecting");
		// Dial transport-neutrally, the same as every terminal client: the rooms
		// `dial` normalises a bare `host:port` into a `tcp` locator and passes an
		// `ocapn://…iroh` URI through, both routed over the relay by the injected
		// browser adapter. The runtime's default `connect` would reject the bare
		// designator `/locator` serves.
		const next = await Directory.connect(target, (address) => dial(address, runtime));
		// Everything this session will hold, minted with it. Nothing below adds a
		// field to module scope, so nothing below can outlive the session by
		// being forgotten at the other end.
		const session: Live = {
			id,
			dir: next,
			home: locator === null,
			locator: target,
			backoff: FIRST_BACKOFF_MS,
			everConnected: held !== undefined,
			offerer: null,
			rooms: new Map(),
			posted: new Map(),
			backChannels: new Map(),
			echoes: [],
			lines: new Map(),
			advertised: null,
			advertiseRetries: ADVERTISE_RETRY_LIMIT,
			registered: false,
			deferredOffers: new Set(),
			stable: null,
			signaling: null,
			files: new Map(),
			objectUrls: new Map(),
			progress: { pending: new Map(), frame: null },
			outgoing: new Map(),
		};
		dirs.set(id, session);
		const seen = await next.watch((event) => {
			switch (event.kind) {
				case "closed":
					store.dropLiveRoom(id, event.name);
					break;
				case "registered":
					store.setDmable(id, event.name, true);
					// Offer a member who arrives after us an inbox straight away, so their
					// first message costs no extra round trip. One already on the roster
					// before we had a name is covered by the directory asking on demand.
					offerInboxFor(session, event.name);
					break;
				case "unregistered":
					store.setDmable(id, event.name, false);
					// The member left, so the room has their name back and may grant
					// it to someone else. Close what we have with them and hand the
					// lines back; a later introduction under the same name opens a
					// new conversation, because it may well be a new person.
					// Their reply route goes with them: it reached that connection,
					// and the next holder of the name is not on it.
					for (const key of store.closeDmsWith(id, event.name)) {
						dropLine(session, key);
						session.backChannels.delete(key);
					}
					// The next holder of this name is a different person and gets an
					// inbox of their own. An offer still queued for them is dropped
					// rather than spending a permanent name on someone who has left.
					for (const p of session.deferredOffers) {
						if (p.toLowerCase() === event.name.toLowerCase()) {
							session.deferredOffers.delete(p);
						}
					}
					ensureOfferer(session).forget(event.name);
					break;
				default:
					store.setLiveRoom(id, event.name, event.count);
					break;
			}
		});
		store.resetLiveRooms(id, seen.map((room) => [room.name, room.count] as const));
		announceDirectory();
		store.markDirReached(id);
		store.setDirSession(id, "connected");

		store.setBanner(null);
		if (session.everConnected && store.joinedRooms(id).length > 0) {
			store.deliverActive(store.sysItem("Reconnected"));
		}

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
			session.backoff = FIRST_BACKOFF_MS;
			session.stable = null;
		}, BACKOFF_STABLE_MS);

		// Re-enter every room we were in, not just one: the conversations are all
		// still on screen, and a reconnect that restored only one would leave the
		// rest looking healthy while silently delivering nothing. They go back in
		// the order they were first entered, so a partial recovery keeps the
		// oldest rooms rather than an arbitrary subset. Otherwise honour a join
		// the user asked for while this session was still opening, and only then
		// wait.
		const rejoining = store.joinedRooms(id);
		const nick = store.dirNick(id) || store.get().draftNick;
		if (rejoining.length > 0 && nick) {
			store.setStatus(
				rejoining.length === 1
					? "rejoining #" + rejoining[0].id + "…"
					: "rejoining " + rejoining.length + " rooms…",
			);
			for (const conv of rejoining) void enterRoom(conv.dir, conv.id, nick);
		} else if (staged) {
			const wanted = staged;
			staged = null;
			store.setStatus("entering #" + wanted.room + "…");
			settleStaged(await enterRoom(id, wanted.room, wanted.nick));
		} else store.setDirStatus(id, "pick a room");
		return "";
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
		//
		// Open the row before reporting on it. Everything above this line can
		// throw before the server was ever recorded — the wasm module answers 503
		// until it is built, and a page loaded offline never learns its own
		// locator — and a report about a server the store has never heard of is
		// dropped on the floor. That silence is the whole failure: the opening
		// screen waits for *some* server to have answered either way, so a first
		// attempt that failed this early left the page on "Opening a peer in your
		// browser…" for good, retrying behind a screen that never lifted.
		const failedLocator = locator ?? homeDirectoryLocator ?? "";
		// An unparseable locator has no identity to file the failure under, so it
		// stands in as the empty one: the report still reaches the status line and
		// the join card, and no row is opened for an address that cannot exist.
		const failed = failedLocator === "" ? dirId("") : directoryId(failedLocator) ?? dirId("");
		// The server this page came from is retried for as long as the tab is open:
		// there is no address to correct, so giving up would leave a reader with a
		// dead page and nothing to do about it.
		const home = locator === null || failedLocator === (homeDirectoryLocator ?? "");
		// A server somebody typed and that has never once answered is most likely a
		// typo, and retrying a typo forever is how one mistyped locator became a
		// permanent row dialling every few seconds for the life of the tab with no
		// way to remove it. Let it go instead; the address is still in the card's
		// field, so correcting it is an edit rather than a retype.
		if (!home && !store.dirReached(failed)) {
			store.forgetDir(failed);
			directoryLocators.delete(failed);
			// The line that announced this attempt has to stop announcing it. It was
			// written before the dial and belongs to whichever server the reader is
			// on, so leaving it saying "reaching …" reports an attempt that ended,
			// on a server that was never even involved.
			store.setStatus(roomStatus());
			return UNREACHABLE;
		}
		store.openDir(failed);
		store.setDirSession(failed, "disconnected");
		store.setDirStatus(failed, UNREACHABLE);
		if (home) homeDirectoryLocator = null;
		scheduleReconnect(home ? null : failedLocator, Math.min(backoff * 2, BACKOFF_CEILING_MS));
		return UNREACHABLE;
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
	if (!releaseSession(which)) return;
	store.setDirSession(which.id, "reconnecting");
	store.setDirStatus(which.id, "reconnecting…");
	if (store.joinedRooms(which.id).length > 0) {
		// Named while this tab holds more than one. "Reconnecting…" is the whole
		// message when there is only one thing it could be about, and a riddle the
		// moment there are two: the rooms on the other directory are still live,
		// and a reader watching one of those go quiet has no way to tell whether
		// this is about them.
		const held = store.get().dirs.size;
		const name = directoryName(which.id, store.get().homeDir);
		store.setBanner({
			kind: "working",
			text: held > 1 ? "Reconnecting to " + name + "…" : "Reconnecting…",
		});
	}
	if (which.home) homeDirectoryLocator = null;
	scheduleReconnect(which.home ? null : which.locator, Math.min(which.backoff * 2, BACKOFF_CEILING_MS));
}

/** Give back everything this session holds, and say whether there was anything
 * to give back.
 *
 * The half of ending a session that is the same however it ends. A session that
 * dropped is coming back, and one whose directory a reader left is not, but
 * neither may keep an object URL, an exported inbox, or a timer — so what
 * differs between them is only what happens *after* this, and that is the whole
 * reason this is not folded into its caller. */
function releaseSession(which: Live): boolean {
	if (!isCurrent(which)) return false; // already replaced by a newer session
	dirs.delete(which.id);
	// The serve promise tells us the directory wire is gone, but reconnect is a
	// separate timer. Retire the session shell explicitly before that timer can
	// dial the same durable peer again; this is idempotent when the pump already
	// completed its EOF teardown.
	void which.dir.session.closeTransport().catch((err) =>
		console.error("rooms: could not retire the dead directory session:", reason(err))
	);
	if (which.stable !== null) clearTimeout(which.stable);
	void which.signaling?.close().catch((err) => console.error("rooms: WebRTC signaling would not stop:", reason(err)));
	// A redeemed introduction holds a connection open and an inbox exported on
	// it, so these are handed back rather than merely forgotten.
	for (const key of [...which.lines.keys()]) dropLine(which, key);
	// A file send can still be measuring media or staging room uploads before it
	// has an echo to await. It belongs to this session all the same, and the
	// browser Files it was reading from go with it, so the bubble says unsent
	// and offers nothing, rather than a retry with nothing left to send.
	for (const [id, outgoing] of which.outgoing) {
		markSend(outgoing.key, id, "refused");
		commitAttachmentUpdates(
			which,
			outgoing.key,
			new Map(
				outgoing.attachmentIds.map((fileId) => [fileId, {
					got: undefined,
					error: "the connection ended before these files were sent",
					lost: true,
				}]),
			),
		);
	}
	// Every picture this session showed is an object URL the browser keeps
	// until it is told otherwise, and every posted file is a capability that
	// only meant anything on this session's room.
	releaseFiles(which);
	// Our own room lines still awaiting an echo will never get one now, so mark
	// them failed with a retry action rather than leaving them dimmed forever.
	for (const row of which.echoes.splice(0)) {
		markSend(row.key, row.id, "failed");
	}
	// The references governing our own lines came over this connection and cannot
	// outlive it. What was said is still what was said; what can be done to it is
	// what changes, so the pencil and the close go rather than staying to refuse.
	which.posted.clear();
	for (const key of store.dropHeldLines(which.id)) {
		store.deliver(
			key,
			store.sysItem(
				"That line can no longer be changed. Your words are still in the box, to say again if you want them said.",
			),
		);
	}
	// The new session's `watch` replays who is reachable, and re-advertises us,
	// so the page goes back to knowing neither.
	// The next session's `watch` replays who is reachable there and re-advertises
	// us, so this directory goes back to knowing neither. Another directory's
	// peers are none of this one's business.
	store.clearDmable(which.id);
	store.unreadyDms();
	return true;
}

/** Stop holding a directory: leave its rooms, close its direct lines, give back
 * its session, and forget it.
 *
 * The other end of `openDirectory`. Holding one is a live session, a name
 * registered on it, and everything reachable through that name, so letting it go
 * has to be all of that and not merely a row removed from a list — a directory
 * dropped from the rail while its session went on running would keep dialling,
 * keep its object URLs, and keep answering for a name nobody could see any more.
 *
 * Not the directory this page came from. There is no address to correct there
 * and nothing to fall back to, so leaving it would leave a reader on a page with
 * no directory and no way to name one; the card that offers this is only ever
 * opened for another directory, and this refuses it in its own terms rather than
 * trusting that.
 *
 * Each room is left through the room's own verb, so the wire is told and the
 * reader is moved off it exactly as if they had left it by hand. The session is
 * released *after* those, because a room can only say goodbye over the session
 * that carried it. */
export function leaveDirectory(dir: DirId): void {
	if (dir === store.get().homeDir) return;
	const live = dirs.get(dir);
	for (const conv of store.convsOn(dir)) {
		if (conv.type === "dm") closeDm(conv);
		else leaveRoom(conv.key);
	}
	if (live !== undefined) releaseSession(live);
	store.forgetDir(dir);
	store.showAboutDir(null);
	store.setStatus(roomStatus());
}

/** Try this directory again, later each time it fails. The delay belongs to the
 * directory, so a server that is down backs off on its own schedule while every
 * other directory this tab holds carries on. */
function scheduleReconnect(locator: string | null, backoff: number): void {
	setTimeout(() => void openDirectory(locator, backoff), backoff);
}

// End our rendezvous registration when the tab goes away. The relay reclaims a
// dropped socket on its own (its idle ping/pong), so this is a courtesy close,
// not a correctness requirement; a browser is a rendezvous, not a mailbox.
globalThis.addEventListener("beforeunload", () => {
	rendezvous?.stop();
});
