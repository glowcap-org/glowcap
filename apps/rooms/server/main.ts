// The rooms chat server, written on pancake actors in native Deno.
//
// It hosts a *directory* of chat rooms and accepts any number of OCapN clients —
// in any language, over either transport. A client fetches the directory, then
// `open`s a new room or `enter`s an existing one; either call returns a live
// reference to that room. The client subscribes to the room with a nickname and
// a capability to its own inbox; the room keeps every subscriber's inbox
// capability and, when anyone posts, calls each one back with `notify`. The
// clients never poll: the room pushes to them because it holds a live capability
// to each.
//
// The directory is the server's one published bootstrap object; rooms are the
// references it hands back. A room exists only while someone is in it — when its
// last member leaves, the room is removed and its name frees up. The directory
// also answers `list` (the live rooms, as `[name, count]` pairs) and `watch`
// (hand it an inbox; it pushes a `notify(event, name, count)` delta on every
// open/close/count change), so a client can discover and follow rooms, not just
// open and enter them.
//
// The directory is published on the Host, which makes it fetchable by name and
// there before any connection is; the directory and room
// behaviors are plain functions of `(verb, args)`; a subscriber's inbox arrives
// as a `Ref` the room sends to. No peer, no vat, no manual flush, no hand-rolled
// serve loop — the capability model is the whole program.
//
// Transport is chosen by the `ROOMS_TRANSPORT` env var (or `--transport=iroh`):
// the default `tcp` listens on `127.0.0.1:<port>` (override with `ROOMS_BIND`);
// `iroh` binds an encrypted-QUIC endpoint. `ROOMS_REACHABILITY=discovery` puts the
// iroh endpoint on n0 relays + DNS/pkarr and announces a bare
// `ocapn://<nodeid>.iroh` URI (dial-by-id); the default `direct` announces
// `ocapn://…?direct-addresses=…` for hermetic same-host demos. On TCP,
// `ROOMS_ANNOUNCE_HOST` (when set) is the dialable hostname printed and
// advertised. Either way the announce line is
// `ROOMS-SERVER-LISTENING <locator>`, which the demo harness and web bridge read
// to point clients at the right place.
//
// Run it:  deno run --allow-ffi --allow-net --allow-read --allow-env server.ts 9099
//          ROOMS_TRANSPORT=iroh deno run -A --unstable-ffi server.ts
//          ROOMS_TRANSPORT=iroh ROOMS_REACHABILITY=discovery deno run -A --unstable-ffi server.ts

import {
	annotateSession,
	type Argument,
	type Behavior,
	currentSession,
	designatorHostPort,
	durableIdentityAuthenticated,
	enableTrace,
	formatPeerUri,
	type Host,
	parseLocator,
	Ref,
	type Session,
	TRANSPORT_IROH,
	TRANSPORT_TCP,
	TRANSPORT_WEBRTC,
} from "@pancake/runtime";
import { addressDesignator } from "@pancake/tcp";
import * as irohTransport from "@pancake/iroh";
import { isUriLocator, roomsHost, roomsListen } from "../lib/locator.ts";
import { startViz } from "./viz.ts";
import { attachmentArgs } from "../lib/attachment.ts";
import {
	ATTACHMENT_REFUSED,
	BAD_ATTACHMENT,
	BLOB_EXPIRED,
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_SUCH_ROOM,
	NOT_REGISTERED,
	NOT_YOUR_LOCATOR,
	PEER_OFFLINE,
	ROOM_EXISTS,
	ROOM_TOO_LONG,
	RoomError,
	UPLOAD_INCOMPLETE,
} from "../lib/errors.ts";
import {
	BLOB_CHUNK,
	MAX_ATTACHMENT_BYTES,
	MAX_AWAY,
	MAX_BLOB_READERS,
	MAX_DM_INBOXES,
	MAX_FILE_NAME,
	MAX_IMAGE_DIM,
	MAX_LINE,
	MAX_MESSAGE_FILES,
	MAX_MIME,
	MAX_NICK,
	MAX_ROOM,
	MAX_ROOM_ATTACHMENT_BYTES,
	MAX_ROOM_ATTACHMENTS,
	MAX_SERVER_ATTACHMENT_BYTES,
	MAX_SERVER_PENDING_BYTES,
	MAX_SIGNAL_EXCHANGES,
	MAX_TOPIC,
	SIGNAL_EXCHANGE_TIMEOUT_MS,
	UPLOAD_IDLE_MS,
} from "../lib/limits.ts";
import {
	ATTACH,
	AWAY,
	DIRECTORY,
	DISCARD,
	EDIT,
	EDITED,
	ENTER,
	INTRODUCE,
	LEAVE,
	LINE,
	LINK,
	LIST,
	NOTIFY,
	OFFER_INBOX,
	OFFER_SIGNALING,
	OPEN,
	POST,
	POST_FILES,
	READ,
	REGISTER,
	SET_TOPIC,
	SIG_ACCEPTED,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_OFFER,
	SIG_REJECT,
	SIGNAL_ANSWER,
	SIGNAL_CANDIDATE,
	SIGNAL_DONE,
	SIGNAL_OFFER,
	SUBSCRIBE,
	TOPIC,
	TYPING,
	WATCH,
	WITHDRAW,
	WITHDRAWN,
	WRITE,
} from "../lib/protocol.ts";
import { RoomLinks, RoomServerState } from "./state.ts";

// One stray async failure (a register fetch, a notify) must not take CapTP
// down. Deno exits on unhandled rejections unless prevented; `serve.ts` already
// has this backstop, and the CapTP child needs the same.
globalThis.addEventListener("unhandledrejection", (event) => {
	event.preventDefault();
	console.error("rooms: unhandled rejection (continuing):", event.reason);
});

/** One subscriber: the nickname it chose and the capability to call it back on,
 * plus the connection that capability lives on (a far ref is sent over the
 * connection that holds it). */
interface Member {
	nick: string;
	inbox: Ref;
	session: Session;
	/** The room's own hold on the references it answered this member's recent
	 * posts with, oldest first.
	 *
	 * Spawning one leaves the room holding a retain, so a member talking all day
	 * would leave the room holding one per line said until the connection went.
	 * Past `HELD_LINE_REFS` the oldest is handed back.
	 *
	 * Handing one back does not take the line away from the member: a released
	 * local capability stops being the room's to hold, while the member's own
	 * import keeps it alive and callable. That is the point rather than a
	 * caveat — the authority is the reference they hold, and the room could not
	 * revoke it by tidying its own bookkeeping even if it wanted to. */
	lines: Ref[];
	/** Why this member has stepped away, empty while they are here.
	 *
	 * Theirs to state rather than the room's to decide, so nothing is handed
	 * over for it: the room knows which membership is calling and writes the
	 * standing of that one. It lives on the membership because it is about a
	 * person being in a room, not about the connection, so leaving and coming
	 * back arrives present. */
	away: string;
	/** The room's own hold on the topic capability this membership was answered
	 * with. Superseded by a fresh one on every subscribe, so it is handed back
	 * whenever the membership record goes, silently or not. */
	topic: Ref;
}

/** How many line references one room keeps a hold of per member. Its own
 * bookkeeping only; see `Member.lines`. */
const HELD_LINE_REFS = 100;

/** A live room: its display name (the casing the opener chose), its roster, and
 * the connection that opened it. The room owns its members and its broadcast;
 * the directory owns the set of rooms. A room lives while it has members; an
 * `open`ed room with no members yet is reclaimed if its opener disconnects
 * before subscribing. */
interface RoomState {
	name: string;
	members: Member[];
	creator: Session;
	/** The files posted here, oldest first, and the bytes they add up to. The
	 * room hosts media so a picture outlives the tab that posted it; that
	 * makes storage the room's to bound, which is what `dropOldestFiles`
	 * enforces against `MAX_ROOM_ATTACHMENT_BYTES`. */
	files: PostedFile[];
	fileBytes: number;
	/** Uploads begun here and not yet posted, by the connection driving each.
	 * Nobody has seen these bytes, so an abandoned upload is pure cost and
	 * leaves with its connection. */
	uploads: Map<Session, Set<PendingUpload>>;
	/** Names the next line this room makes. Unique for as long as the room
	 * lives, which is as long as anything can refer to one: the room keeps no
	 * history, so an id means something only to the members who were here. */
	nextLine: number;
	/** What this room says it is about, empty until somebody sets it.
	 *
	 * Held by the room rather than by whoever set it, because it outlives them:
	 * a topic set by a member who then leaves is still what the room is about,
	 * and everyone arriving afterwards is told it. */
	topic: string;
}

function makeRoomState(name: string, creator: Session): RoomState {
	return {
		name,
		members: [],
		creator,
		nextLine: 1,
		topic: "",
		files: [],
		fileBytes: 0,
		uploads: new Map(),
	};
}

/** One file the room holds. `bytes` is null once it has been dropped to stay
 * under a ceiling; the capability members hold stays valid and breaks
 * `blob-expired` on read, which a reader can tell from an empty file.
 *
 * `room` is here because eviction is server-wide: the oldest file anywhere is
 * the one that goes, and dropping it has to find the room whose byte count it
 * was part of. */
interface PostedFile {
	room: RoomState;
	name: string;
	mime: string;
	size: number;
	width: number;
	height: number;
	bytes: Uint8Array | null;
	written: number;
	failure: string | null;
	waiters: Set<BlobWaiter>;
}

interface BlobWaiter {
	offset: number;
	maxLen: number;
	resolve: (chunk: Uint8Array) => void;
	reject: (reason: Error) => void;
}

/** One upload in flight: what was declared at `attach`, the bytes written so
 * far, and whether its `post` has spent it. */
interface PendingUpload {
	name: string;
	mime: string;
	size: number;
	width: number;
	height: number;
	file: PostedFile;
	posted: boolean;
	/** The capability `attach` answered with, so the room can give its own
	 * retain back when the upload is spent or abandoned. Null only between
	 * minting the row and spawning its object. */
	ref: Ref | null;
	/** Re-armed on every chunk. An upload holds a reservation against the size
	 * it declared, so one that goes quiet has to be reclaimed rather than
	 * waited on: see `UPLOAD_IDLE_MS`. */
	expires: ReturnType<typeof setTimeout> | null;
}

const rooms = new Map<string, RoomState>();

/** Every file the server holds, oldest first, and the bytes they add up to.
 * Eviction is server-wide because the resource is: a per-room budget times
 * unbounded rooms bounds nothing. */
const heldFiles: PostedFile[] = [];
let heldBytes = 0;

/** Bytes reserved by uploads that have been admitted and not yet posted.
 * Reserved at `attach` against the size declared there, because that is what
 * the member may write, and released when the upload is posted or dropped. */
let pendingBytes = 0;

/** Forget one held file's bytes wherever they are counted. The record and its
 * capability stay, so a member holding a dropped file's reference hears
 * `blob-expired` rather than an empty answer it could not tell from a real
 * empty file. */
function dropFileBytes(file: PostedFile): void {
	if (file.bytes === null) return;
	if (file.written === file.size && file.failure === null) {
		heldBytes -= file.bytes.length;
		file.room.fileBytes -= file.bytes.length;
	}
	file.bytes = null;
	wakeBlobWaiters(file);
}

/** Make room for one more file of `incoming` bytes in `state`, under the
 * server's ceilings and the room's own. The server's are the ones that hold
 * memory; the room's keep any single room from taking the lot. */
function dropOldestFiles(state: RoomState, incoming: number): void {
	// Server-wide first, oldest anywhere: a busy room should not be able to
	// push a quiet room's files out ahead of its own older ones.
	while (heldFiles.length > 0 && heldBytes + incoming > MAX_SERVER_ATTACHMENT_BYTES) {
		dropFileBytes(heldFiles[0]);
		forgetFile(heldFiles[0]);
	}
	// Then this room's own share.
	while (
		state.files.length > 0 &&
		(state.fileBytes + incoming > MAX_ROOM_ATTACHMENT_BYTES ||
			state.files.length >= MAX_ROOM_ATTACHMENTS)
	) {
		dropFileBytes(state.files[0]);
		forgetFile(state.files[0]);
	}
}

/** Let go of every file a closing room held. A room is deleted when its last
 * member leaves, and its files go with it: the server counts them, so leaving
 * them on the held list would charge the budget for rooms that no longer
 * exist and only reclaim them under eviction pressure. */
function dropRoomFiles(state: RoomState): void {
	for (const file of [...state.files]) {
		dropFileBytes(file);
		forgetFile(file);
	}
}

/** Drop one emptied file from both lists it sits in, so neither grows with
 * everything ever posted. */
function forgetFile(file: PostedFile): void {
	const held = heldFiles.indexOf(file);
	if (held >= 0) heldFiles.splice(held, 1);
	const own = file.room.files.indexOf(file);
	if (own >= 0) file.room.files.splice(own, 1);
}

/** Forget every upload `session` began here without posting. Called when a
 * member leaves, so bytes nobody has seen never outlive their uploader, and
 * the object each one was driven through goes back with them. */
function dropUploads(state: RoomState, session: Session): void {
	for (const upload of state.uploads.get(session) ?? []) dropUpload(state, session, upload);
	state.uploads.delete(session);
}

/** Reclaim one upload that will not be posted: release its reservation, drop
 * the bytes it collected, and hand its capability back. Idempotent, because
 * the idle timer and a departure can both reach the same upload. */
function dropUpload(state: RoomState, session: Session, upload: PendingUpload): void {
	if (upload.file.failure !== null || upload.file.written === upload.size) return;
	if (upload.expires !== null) clearTimeout(upload.expires);
	pendingBytes -= upload.size;
	upload.file.failure = upload.posted ? "the upload ended before this file arrived" : "the upload was discarded";
	upload.file.bytes = null;
	state.uploads.get(session)?.delete(upload);
	if (upload.ref !== null) handBack(session, upload.ref);
	wakeBlobWaiters(upload.file);
	if (!upload.posted) upload.posted = true;
}

function wakeBlobWaiters(file: PostedFile): void {
	for (const waiter of [...file.waiters]) {
		if (file.failure !== null || file.bytes === null) {
			file.waiters.delete(waiter);
			waiter.reject(new RoomError(BLOB_EXPIRED, file.failure ?? `"${file.name}" is no longer held by this room`));
		} else if (waiter.offset < file.written || file.written === file.size) {
			file.waiters.delete(waiter);
			const len = Math.min(waiter.maxLen, BLOB_CHUNK, file.written - waiter.offset);
			waiter.resolve(file.bytes.subarray(waiter.offset, waiter.offset + len));
		}
	}
}

function finishUpload(state: RoomState, session: Session, upload: PendingUpload): void {
	if (upload.expires !== null) clearTimeout(upload.expires);
	pendingBytes -= upload.size;
	state.uploads.get(session)?.delete(upload);
	if (state.uploads.get(session)?.size === 0) state.uploads.delete(session);
	dropOldestFiles(state, upload.size);
	state.files.push(upload.file);
	state.fileBytes += upload.size;
	heldFiles.push(upload.file);
	heldBytes += upload.size;
	if (upload.ref !== null) handBack(session, upload.ref);
	wakeBlobWaiters(upload.file);
}

/** Start this upload's idle clock over. Every chunk re-arms it, so the window
 * bounds silence rather than the whole upload. */
function armUploadTimer(state: RoomState, session: Session, upload: PendingUpload): void {
	if (upload.expires !== null) clearTimeout(upload.expires);
	upload.expires = setTimeout(() => dropUpload(state, session, upload), UPLOAD_IDLE_MS);
}

/** One introducible member.
 *
 * `inboxes` is what `introduce` hands out: the capability this member offered for
 * each peer, keyed by that peer's nick, so a caller only ever gets the one minted
 * for them. `inbox` is the member's register inbox, where the directory asks for
 * an inbox it needs and tells a waiting caller one has arrived.
 *
 * The registered locator is not what a redeem dials. A member's own hello already
 * claims where it is reachable, and that claim is what the gifter relays when it
 * introduces this member, so the locator here is the member's advertised address
 * for the directory's own use: refusing a registration it cannot tie to the
 * caller, and routing `webrtc` signaling by designator. */
interface Introduction {
	nick: string;
	inbox: Ref;
	inboxes: Map<string, Ref>;
	registrar: Session;
	/** The member's one WebRTC signaling inbox (`offerSignaling`), or null.
	 * The directory routes offers and candidates for the member's `webrtc`
	 * designator here; released with the introduction. */
	signaling: Ref | null;
}

/** Introducible members, by nick. */
const introductions = new Map<string, Introduction>();

/** Members reachable at a `webrtc` locator, by that locator's designator. A
 * `signalOffer` names the designator (that is all a `webrtc` locator carries),
 * so this is the index that finds whose signaling inbox carries the exchange.
 * A row lives exactly as long as its registration. */
const webrtcDesignators = new Map<string, string>();

/** One in-flight WebRTC signaling exchange: who started it (and the reply
 * capability their answer and candidates ride back on), and which member
 * answers it. Transient scratch for one channel bring-up, capped by
 * `MAX_SIGNAL_EXCHANGES` with oldest-first eviction. */
interface SignalExchange {
	originator: Session;
	reply: Ref;
	targetKey: string;
	expires: ReturnType<typeof setTimeout>;
}

const signalExchanges = new Map<string, SignalExchange>();
let nextSignalExchange = 0;

function dropSignalExchange(id: string, reason?: string): void {
	const exchange = signalExchanges.get(id);
	if (exchange === undefined) return;
	signalExchanges.delete(id);
	clearTimeout(exchange.expires);
	if (reason == null) {
		handBack(exchange.originator, exchange.reply);
		return;
	}
	// Queue the reject before releasing the remote import. Retirement is joined
	// to the send so a slow carrier cannot invert those two protocol effects.
	void exchange.originator.tell(exchange.reply, SIG_REJECT, [reason]).then(
		() => handBack(exchange.originator, exchange.reply),
		() => handBack(exchange.originator, exchange.reply),
	);
}

/** The exchange `session` originated toward `designator`, if one is live. A
 * scan, bounded by the exchange cap. */
function originatedExchange(session: Session, designator: string): string | null {
	const targetKey = webrtcDesignators.get(designator);
	if (targetKey === undefined) return null;
	for (const [id, exchange] of signalExchanges) {
		if (exchange.originator === session && exchange.targetKey === targetKey) return id;
	}
	return null;
}

/** Whether `locator` names the connection registering it — or, where that cannot
 * be known, whether the directory has any grounds to refuse.
 *
 * The directory shows this locator to other members and routes `webrtc`
 * signaling by its designator. One it cannot tie to the caller is therefore a
 * name claimed on somebody else's behalf, worth closing wherever it can be
 * closed. An introduction no longer dials it — the gifter relays what the
 * member's own hello claimed — so this is a claim about identity rather than the
 * dial target it once was.
 *
 * It can be closed exactly when the registering connection is keyed: the
 * handshake has verified the partner holds the key its designator names, so a
 * claim to be at that designator is checkable against it.
 *
 * It cannot be closed otherwise, and the reason is worth stating rather than
 * papering over. The transport a member reaches the *directory* over is not the
 * transport other members reach the *member* over. A browser peer talks to the
 * room through a relayed TCP socket while being reachable at a webrtc or
 * keyed-relay designator of its own, so its connection here proves nothing about the address
 * it advertises. Refusing that would refuse the app's headline feature; accepting
 * it is what the directory has always done. The honest statement is that an
 * unkeyed registration is a claim the directory passes on without vouching for,
 * and that keying the directory's own connections is what would close it — a
 * larger change than this function. */
function claimsOwnLocator(session: Session, locator: string): boolean {
	let identity;
	try {
		identity = session.partnerIdentity();
	} catch {
		// No verified partner key on this connection: nothing to check against.
		return true;
	}
	// Only a durable identity the partner actually proved is worth checking a
	// claim against (ADR-0097). An address designator names a socket the key
	// does not determine, so there is nothing here to hold the claim to.
	if (!durableIdentityAuthenticated(identity)) return true;
	const claimed = isUriLocator(locator) ? parseLocator(locator).designator : addressDesignator(
		designatorHostPort(locator).hostname,
		designatorHostPort(locator).port,
	);
	return claimed === identity.designator;
}

/** File the registration and tell the member its nick is introducible.
 *
 * Synchronous: the name is claimed and acknowledged in one turn, so no window
 * exists in which the registry has no holder for it. */
function registerMember(
	nick: string,
	locator: string,
	inbox: Ref,
	session: Session,
): void {
	const key = nickKey(nick);
	// No advertised-locator override here. A member's own hello already claims
	// where it is reachable — its listen address, or its key plus the dial
	// addresses a key-scheme netlayer publishes — so the gifter relays that claim
	// verbatim when it introduces this member. Stamping a locator built from the
	// `register` argument instead replaced a complete claim with a partial one,
	// and a recipient that matches an exporter location against what the exporter
	// itself said then finds two different documents.
	// A connection holds one name at a time, so `registeredNickOf` is a function
	// and not a guess at which row means "you". A nick change re-registers on the
	// live session, and a row left behind would keep answering with the name it
	// gave up: offers would file under the old name and the new one could never
	// collect an inbox.
	for (const [otherKey, other] of [...introductions]) {
		if (other.registrar !== session || otherKey === key) continue;
		withdrawIntroduction(otherKey, other);
	}
	// Only ever this member replacing its own registration: a live one held by
	// another connection was refused at the verb, and a dead one is theirs to
	// lose. The name frees when its holder's connection goes, and nothing else
	// can take it while that connection stands.
	const prior = introductions.get(key);
	if (prior !== undefined) withdrawIntroduction(key, prior);
	introductions.set(key, {
		nick,
		inbox,
		inboxes: new Map(),
		registrar: session,
		signaling: null,
	});
	// A `webrtc` locator is reached by signaling, not a socket, so index the
	// member under its designator for `signalOffer` routing.
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		if (loc.transport === TRANSPORT_WEBRTC) webrtcDesignators.set(loc.designator, key);
	}
	session.tell(inbox, NOTIFY, ["registered", nick]).catch(() => {});
	notifyWatchers("registered", nick, 1);
}

/** Take one registration out of the registry, announce it, and leave nothing
 * behind that still points at the name.
 *
 * A name outlives its holders, so the next one to claim it must start from
 * nothing: the inboxes this holder collected are released, and so is every inbox
 * *other* members offered for this name. Skipping that second sweep is what would
 * hand the next holder of "bob" the inbox Carol minted for the previous one, and
 * her interface would paint their messages as his with full confidence. */
function withdrawIntroduction(key: string, intro: Introduction): void {
	introductions.delete(key);
	releaseInboxes(intro);
	forgetOfferedInboxes(key);
	for (const [designator, owner] of [...webrtcDesignators]) {
		if (owner === key) webrtcDesignators.delete(designator);
	}
	if (intro.signaling !== null) handBack(intro.registrar, intro.signaling);
	for (const [id, exchange] of [...signalExchanges]) {
		if (exchange.targetKey === key || exchange.originator === intro.registrar) {
			dropSignalExchange(id);
		}
	}
	notifyWatchers("unregistered", intro.nick, 0);
}

/** Give one offered inbox back to the member that offered it, so it can drop the
 * export. A release on a connection already gone throws and is ignored: its
 * imports went with it. Every site that stops holding an inbox comes through
 * here. */
/** Give one capability back on the session it lives on. The room does this for
 * everything it holds and no longer needs — an offered inbox, a signaling
 * reply, a posted file's blob — so the object retires when its last holder
 * lets go rather than being pinned by a retain nobody is using. */
function handBack(session: Session, ref: Ref): void {
	try {
		session.release(ref);
	} catch {
		// Nothing to give back: that connection's teardown reclaimed it.
	}
}

/** Hand back every inbox an introduction collected. */
function releaseInboxes(intro: Introduction): void {
	for (const ref of intro.inboxes.values()) handBack(intro.registrar, ref);
	intro.inboxes.clear();
}

/** Drop the inbox every other member offered for `key`, so an `introduce` naming
 * it is refused `introduction-pending` and the member mints a fresh one. */
function forgetOfferedInboxes(key: string): void {
	for (const intro of introductions.values()) {
		const ref = intro.inboxes.get(key);
		if (ref === undefined) continue;
		intro.inboxes.delete(key);
		handBack(intro.registrar, ref);
	}
}

/** The nick this connection registered, or null when it registered none. The only
 * trustworthy source of a caller's own name is the registration the directory
 * granted, never an argument the caller passes. A scan, bounded by the members
 * present. */
function registeredNickOf(session: Session): string | null {
	for (const intro of introductions.values()) {
		if (intro.registrar === session) return intro.nick;
	}
	return null;
}

/** Whether another live connection holds `nick` for direct messages.
 *
 * A name has one holder here, and the holding lasts as long as the connection —
 * longer than any one room membership, because a member who leaves a room stays
 * reachable by direct message under the name they registered.
 *
 * That longer life is why both doors ask this. A room frees a nick the moment
 * its holder leaves the room, so without this the room would grant a name the
 * directory still answers for: the roster shows one person and an introduction
 * under that name reaches another, with nothing on either side saying so. One
 * name, one holder, one lifetime — the connection's. */
function registeredByAnother(session: Session, nick: string): boolean {
	const holder = introductions.get(nickKey(nick));
	return holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen;
}

/** Withdraw every introduction a closing connection registered. */
function dropIntroductions(session: Session): void {
	for (const [key, intro] of [...introductions]) {
		if (intro.registrar !== session) continue;
		withdrawIntroduction(key, intro);
	}
}

/** Directory-wide observers of the live room list. A `watch` registers its inbox
 * capability here; every membership transition pushes a delta to each one. They
 * are global because they watch the whole directory, not one room. */
const watchers: { observer: Ref; session: Session }[] = [];

/** The live rooms — those with at least one member — as `[name, count]` pairs.
 * A just-`open`ed room with no members yet is invisible until its first
 * subscriber, so discovery only ever shows rooms with people in them. Counts go
 * over the wire as `bigint`, the integer type (a plain `number` is a float). */
function snapshot(): Argument[] {
	const live: Argument[] = [];
	for (const state of rooms.values()) {
		if (state.members.length > 0) {
			live.push([state.name, BigInt(state.members.length)]);
		}
	}
	return live;
}

/** Push one room-list delta to every watcher: `notify(event, name, count)` with
 * `event` one of `opened` / `closed` / `count`. A watcher whose inbox can no
 * longer be reached (its connection died) is dropped. */
function notifyWatchers(event: string, name: string, count: number): void {
	for (const w of [...watchers]) {
		w.session.tell(w.observer, NOTIFY, [event, name, BigInt(count)]).catch(() => {
			const i = watchers.indexOf(w);
			if (i >= 0) watchers.splice(i, 1);
		});
	}
}

function dropWatchers(session: Session): void {
	for (let i = watchers.length - 1; i >= 0; i -= 1) {
		if (watchers[i].session === session) watchers.splice(i, 1);
	}
}

/** Room names are unique ignoring case, like nicknames: the directory grants one
 * room per name and frees it when the room empties. */
function roomKey(name: string): string {
	return name.toLowerCase();
}

function nickKey(nick: string): string {
	return nick.toLowerCase();
}

function findBySession(state: RoomState, session: Session): Member | null {
	return state.members.find((m) => m.session === session) ?? null;
}

function claimedByAnother(
	state: RoomState,
	session: Session,
	nick: string,
): boolean {
	const key = nickKey(nick);
	return state.members.some((m) => m.session !== session && nickKey(m.nick) === key);
}

/** Push `from: text` to every subscriber of `state` by calling the inbox
 * capability it gave us. `tell` is the fire-and-forget eventual-send: a notify
 * wants no reply, so it costs one deliver with no answer round-trip. A member
 * whose socket has died is dropped from every room it joined. */
function broadcast(
	state: RoomState,
	from: string,
	text: string,
	...trailing: Argument[]
): void {
	// Structured trailing args ride after the display text: a presence line
	// carries a join/leave kind and the nick, an attachment post its validated
	// `file` record. A plain chat line passes none. An attachment's blob
	// reference is homed on the poster's connection, so relaying it here trips
	// the transparent gifter: each member gets a give, never a room-proxied
	// byte.
	for (const m of [...state.members]) {
		m.session.tell(m.inbox, NOTIFY, [from, text, ...trailing]).catch((e) => {
			// Membership retirement is owned by the session lifecycle hook below.
			// A failed notify is therefore always diagnostic; it is never used as
			// an opportunistic liveness probe or as authority to mutate presence.
			console.error(`[room] notify to ${m.nick} failed: ${e}`);
		});
	}
}

/** Push an ephemeral typing flag to every *other* member of `state`. Typing is
 * best-effort presence, not a line: it carries no text, is never stored, and is
 * never echoed to the typer (`exceptSession`). It rides the same `notify` inbox as
 * a room line, tagged `"typing"` at the third argument so any subscriber that
 * does not care skips it. A member whose socket has died is dropped. */
function broadcastTyping(
	state: RoomState,
	nick: string,
	on: boolean,
	exceptSession: Session,
): void {
	for (const m of [...state.members]) {
		if (m.session === exceptSession) continue;
		m.session.tell(m.inbox, NOTIFY, ["room", "", "typing", nick, on]).catch((error) => {
			console.error(`[room] typing notify to ${m.nick} failed: ${error}`);
		});
	}
}

/** The nick this connection is in a room under, or null when it is in none.
 * One authority for what the room server calls a connection: a membership is
 * a presence, and presence is the fact a timeline viewer wants. A DM
 * registration is a directory entry rather than a presence, and naming a
 * connection by one would keep calling a member present after it left. */
function membershipNick(session: Session): string | null {
	for (const state of rooms.values()) {
		const member = findBySession(state, session);
		if (member !== null) return member.nick;
	}
	return null;
}

/** State this connection's room presence on the live trace, or withdraw the
 * claim when it holds none. A claim, not identity — the viewer only displays
 * it — and stating it here means a member joining, changing rooms, or leaving
 * is one visible change in the picture rather than a name frozen at whatever
 * was said first. */
function statePresence(session: Session): void {
	annotateSession(session, { label: membershipNick(session) });
}

/** Remove `session`'s membership from one room, announcing its departure, and
 * delete the room if that emptied it. The `silent` path is for resubscribe,
 * which drops the prior membership and immediately adds a new one, so it must
 * neither announce a spurious leave nor garbage-collect a room it is about to
 * reuse. */
function leaveRoom(
	state: RoomState,
	session: Session,
	silent = false,
): boolean {
	let removed = false;
	// A silent leave is the same connection re-claiming its place, so its
	// uploads are still that member's; only a real departure drops them.
	if (!silent) dropUploads(state, session);
	for (let i = state.members.length - 1; i >= 0; i -= 1) {
		if (state.members[i].session === session) {
			const member = state.members[i];
			state.members.splice(i, 1);
			removed = true;
			// Every membership is answered with a topic capability of its own, so
			// this record's is finished either way: a resubscribe is about to mint
			// another, and a departure ends the membership that held it.
			handBack(session, member.topic);
			if (!silent) {
				// Leaving gives back the authority over what was said here. The
				// connection may stay, so this cannot wait for its teardown.
				for (const line of member.lines) handBack(session, line);
				member.lines.length = 0;
				broadcast(
					state,
					"room",
					`${member.nick} left (${state.members.length} here)`,
					"leave",
					member.nick,
				);
			}
		}
	}
	if (!silent && removed && state.members.length === 0) {
		dropRoomFiles(state);
		rooms.delete(roomKey(state.name));
	}
	// A real departure also changes what this connection IS: the member is
	// gone but the connection stays, which is exactly the moment the room
	// stops knowing it by that name.
	if (!silent && removed) statePresence(session);
	// A real departure changes the live room list: the room closed if it emptied,
	// else its count dropped. A silent resubscribe leaves the count unchanged.
	if (!silent && removed) {
		if (state.members.length === 0) notifyWatchers("closed", state.name, 0);
		else notifyWatchers("count", state.name, state.members.length);
	}
	return removed;
}

// Transport events arrive in loop-drain batches. Retire every connection from
// such a batch before announcing any departure, so one member's leave cannot
// be sent to a sibling whose native session is already condemned but whose
// lifecycle callback was next in the same batch.
const disconnectedSessions = new Set<Session>();
let disconnectFlushQueued = false;

function scheduleDisconnect(session: Session): void {
	disconnectedSessions.add(session);
	if (disconnectFlushQueued) return;
	disconnectFlushQueued = true;
	queueMicrotask(flushDisconnects);
}

function flushDisconnects(): void {
	disconnectFlushQueued = false;
	const departing = new Set(disconnectedSessions);
	disconnectedSessions.clear();
	if (departing.size === 0) return;

	for (const state of [...rooms.values()]) {
		const removed = state.members.filter((member) => departing.has(member.session));
		if (removed.length !== 0) {
			for (const session of new Set(removed.map((member) => member.session))) dropUploads(state, session);
			state.members = state.members.filter((member) => !departing.has(member.session));

			// Presence mutation is now complete for the whole batch. Only live
			// survivors receive leave records; no failed tell is used as liveness
			// authority.
			for (const member of removed) {
				broadcast(
					state,
					"room",
					`${member.nick} left (${state.members.length} here)`,
					"leave",
					member.nick,
				);
			}

			if (state.members.length === 0) {
				dropRoomFiles(state);
				rooms.delete(roomKey(state.name));
				notifyWatchers("closed", state.name, 0);
			} else {
				notifyWatchers("count", state.name, state.members.length);
			}
		} else if (state.members.length === 0 && departing.has(state.creator)) {
			dropRoomFiles(state);
			rooms.delete(roomKey(state.name));
		}
	}

	for (const session of departing) {
		dropWatchers(session);
		dropIntroductions(session);
	}
	// A disconnect may have landed while this flush ran.
	if (disconnectedSessions.size !== 0 && !disconnectFlushQueued) {
		disconnectFlushQueued = true;
		queueMicrotask(flushDisconnects);
	}
}

/** The upload capability `attach` answers with: one file being staged into a
 * message, spent when that message is posted or the file is discarded.
 *
 * Holding it is the whole authority — the room minted it in reply to that
 * member's `attach` on this connection, so `write` and `discard` ask no
 * questions about who is calling. What `write` checks is the file: bytes past
 * the declared size are refused rather than truncated.
 */
/** What holding a line's reference lets somebody do to it.
 *
 * Nothing here asks who is calling, and that is the whole design rather than an
 * omission: the reference went to the member whose `post` made the line, and a
 * member without it cannot form either request. Ownership is not checked
 * because it is not a question — possession already answered it.
 *
 * Which is also what makes the authority passable. Whoever holds this can hand
 * it on, so a member can let somebody else take their line down and a room can
 * keep a copy to give whoever it wants moderating, and neither party has to
 * learn what a moderator is.
 *
 * A withdrawn line is gone for good. Editing one afterwards would put text back
 * on screen that its author had taken down, so the reference stops answering
 * rather than pretending, and says which of the two happened. */
function lineBehavior(state: RoomState, from: string, id: number) {
	let withdrawn = false;
	return (verb: string, args: Argument[]): Argument => {
		if (verb === EDIT) {
			if (withdrawn) throw new Error("that line was withdrawn");
			const text = typeof args[0] === "string" ? args[0] : "";
			if (text.length > MAX_LINE) {
				throw new Error(`a line may be at most ${MAX_LINE} characters`);
			}
			broadcast(state, from, text, EDITED, BigInt(id));
			return null;
		}
		if (verb === WITHDRAW) {
			// Saying so twice is not an error. The line is gone either way, and a
			// second attempt is somebody making sure rather than doing something
			// wrong.
			if (!withdrawn) {
				withdrawn = true;
				broadcast(state, from, "", WITHDRAWN, BigInt(id));
			}
			return null;
		}
		throw new Error(`a line has no method ${verb}`);
	};
}

/** What this room is about, as a capability.
 *
 * `subscribe` answers with one of these, so every member holds the authority to
 * say what the room is for. That is the room having no ranks rather than an
 * oversight: there is no operator to be, and a reference is a thing you can
 * pass on, so a member can hand this to a bot that keeps the topic without the
 * room ever learning what a bot is.
 *
 * The change is announced as a plain room line carrying the `topic` tag, so a
 * client that has never heard of topics still shows the sentence saying it
 * moved. Nobody is named as having set it: the caller is whoever holds the
 * reference, which may not be the member it was handed to, and a room that
 * cannot know who acted should not claim to. */
function topicBehavior(state: RoomState) {
	return (verb: string, args: Argument[]): Argument => {
		if (verb !== SET_TOPIC) throw new Error(`a topic has no method ${verb}`);
		const said = typeof args[0] === "string" ? args[0] : "";
		if (said.length > MAX_TOPIC) {
			throw new Error(`a topic may be at most ${MAX_TOPIC} characters`);
		}
		if (said === state.topic) return null;
		state.topic = said;
		broadcast(
			state,
			"room",
			said === "" ? "the topic was taken down" : `the topic is now: ${said}`,
			TOPIC,
			said,
		);
		return null;
	};
}

function uploadBehavior(state: RoomState, session: Session, upload: PendingUpload) {
	return (verb: string, args: Argument[]): Argument => {
		if (upload.file.failure !== null || upload.file.written === upload.size) {
			throw new RoomError(UPLOAD_INCOMPLETE, "this upload is spent; attach again");
		}
		if (verb === WRITE) {
			if (!upload.posted) {
				throw new RoomError(UPLOAD_INCOMPLETE, "publish this upload before writing its bytes");
			}
			const chunk = args[0];
			if (!(chunk instanceof Uint8Array)) throw new Error("write needs a byte chunk");
			if (chunk.length > BLOB_CHUNK) {
				throw new RoomError(UPLOAD_INCOMPLETE, `a chunk may be at most ${BLOB_CHUNK} bytes`);
			}
			if (upload.file.written + chunk.length > upload.size) {
				throw new RoomError(UPLOAD_INCOMPLETE, `write runs past the declared ${upload.size} bytes`);
			}
			upload.file.bytes?.set(chunk, upload.file.written);
			upload.file.written += chunk.length;
			wakeBlobWaiters(upload.file);
			if (upload.file.written === upload.size) finishUpload(state, session, upload);
			else armUploadTimer(state, session, upload);
			return null;
		}
		if (verb === DISCARD) {
			dropUpload(state, session, upload);
			return null;
		}
		throw new Error(`upload has no method ${verb}`);
	};
}

/** Publish this connection's staged set as one line, before their bytes arrive.
 * Each returned upload capability then advances its own file independently. */
function postStagedFiles(state: RoomState, session: Session, caption: string): void {
	const member = findBySession(state, session);
	if (member === null) throw new Error("postFiles needs a claimed room membership");
	const staged = [...state.uploads.get(session) ?? []].filter((upload) => !upload.posted);
	if (staged.length === 0) throw new RoomError(UPLOAD_INCOMPLETE, "no files are staged");
	const files: PostedFile[] = [];
	for (const upload of staged) {
		upload.posted = true;
		files.push(upload.file);
		if (upload.size === 0) finishUpload(state, session, upload);
	}
	broadcastFiles(state, member.nick, caption || files[0].name, files);
}

/** Push one message's posted files to every subscriber. Each member gets one
 * blob reference per record, minted on that member's session, so no capability
 * crosses a connection it was not made on and the room relays nothing it does
 * not host.
 *
 * The room gives its own retain back as soon as the line is out. What keeps a
 * blob alive after that is the member holding it, which is the right owner:
 * the file's bytes are already bounded by the room's ceiling, and its object
 * retires when the last member that can name it lets go. Holding the retain
 * here instead would pin one object per file per member for the life of the
 * room, whatever anybody did with them. */
function broadcastFiles(state: RoomState, from: string, caption: string, files: PostedFile[]): void {
	for (const m of [...state.members]) {
		const blobs = files.map((file) => m.session.spawn(blobBehavior(file)));
		const records = files.flatMap((file, index) =>
			attachmentArgs({
				name: file.name,
				mime: file.mime,
				size: file.size,
				blob: blobs[index],
				width: file.width,
				height: file.height,
			})
		);
		m.session.tell(m.inbox, NOTIFY, [
			from,
			caption,
			...records,
		]).then(
			() => blobs.forEach((blob) => handBack(m.session, blob)),
			(error) => {
				blobs.forEach((blob) => handBack(m.session, blob));
				console.error(`[room] file notify to ${m.nick} failed: ${error}`);
			},
		);
	}
}

/** The blob capability members read a posted file through: `read(offset,
 * maxLen)` answers at most `BLOB_CHUNK` bytes, and an empty slice at the end.
 * A file the room has dropped to stay under its ceiling breaks `blob-expired`
 * rather than answering empty, which a reader could not tell from a real
 * empty file. */
function blobBehavior(file: PostedFile) {
	return (verb: string, args: Argument[]): Argument | Promise<Uint8Array> => {
		if (verb !== READ) throw new Error(`blob has no method ${verb}`);
		if (file.bytes === null) {
			throw new RoomError(BLOB_EXPIRED, `"${file.name}" is no longer held by this room`);
		}
		const offset = args[0];
		const maxLen = args[1];
		if (typeof offset !== "bigint" || offset < 0n) throw new Error("read needs offset >= 0");
		if (typeof maxLen !== "bigint" || maxLen <= 0n) throw new Error("read needs maxLen > 0");
		const start = Number(offset > BigInt(file.size) ? BigInt(file.size) : offset);
		const wanted = Math.min(Number(maxLen), BLOB_CHUNK);
		if (start < file.written || file.written === file.size) {
			const len = Math.min(wanted, file.written - start);
			return file.bytes.subarray(start, start + len);
		}
		if (file.waiters.size >= MAX_BLOB_READERS) {
			throw new RoomError(
				ATTACHMENT_REFUSED,
				`"${file.name}" already has ${MAX_BLOB_READERS} readers waiting on the bytes it has not received yet`,
			);
		}
		return new Promise((resolve, reject) => {
			file.waiters.add({ offset: start, maxLen: wanted, resolve, reject });
		});
	};
}

/** The room behavior for one connection. The room grants at most one live
 * membership to the connection, so `post` needs no "from" argument — the
 * capability the post arrives on is the authority to speak in this room. */
function roomBehavior(state: RoomState, session: Session) {
	return (verb: string, args: Argument[]): Argument => {
		if (verb === SUBSCRIBE) {
			const nick = typeof args[0] === "string" ? args[0] : "anon";
			const inbox = args[1];
			if (!(inbox instanceof Ref)) {
				throw new Error("subscribe needs an inbox capability");
			}
			if (claimedByAnother(state, session, nick)) {
				throw new RoomError(NICK_TAKEN, `name "${nick}" is already claimed`);
			}
			// The room is not the only holder of a name. Someone who left this room
			// but stayed connected still answers to theirs for direct messages, so
			// granting it here would put one name on two people: the roster would
			// show the newcomer while an introduction under that name reached the
			// member who left.
			if (registeredByAnother(session, nick)) {
				throw new RoomError(
					NICK_TAKEN,
					`name "${nick}" is held for direct messages by a member who is still connected`,
				);
			}
			// A resubscribe (same connection re-claiming) nets no count change, so it
			// must not fire a discovery event; a fresh membership does.
			const already = findBySession(state, session);
			const wasMember = already !== null;
			// The references to this connection's recent lines outlive the record
			// holding them: re-claiming a place is not saying anything, and a
			// member who can no longer fix what they said a moment ago would have
			// been robbed by bookkeeping.
			const lines = already?.lines ?? [];
			if (wasMember) leaveRoom(state, session, true);
			// Held by the room only so it can be handed back; the member's own
			// import is what keeps it callable.
			const topic = session.spawn(topicBehavior(state));
			state.members.push({ nick, inbox, session, lines, topic, away: "" });
			// The one moment this process KNOWS which member a session
			// carries: state it for the trace, so a viewer can name the peer
			// instead of showing its claimed address.
			statePresence(session);
			broadcast(state, "room", `${nick} joined (${state.members.length} here)`, "join", nick);
			if (!wasMember) {
				notifyWatchers(
					state.members.length === 1 ? "opened" : "count",
					state.name,
					state.members.length,
				);
			}
			// The new member's welcome names everyone present and carries the roster as
			// structured trailing args ("roster" then each nick), so it learns who
			// arrived before it without parsing the text. It goes to the new member
			// alone; `subscribe` itself returns a bare ack — success is the resolution, a
			// claimed nick is the rejection above.
			const names = state.members.map((m) => m.nick);
			session.tell(inbox, NOTIFY, [
				"room",
				`welcome ${nick} — ${names.length} in the room: ${names.join(", ")}`,
				"roster",
				...names,
			]).catch((error) => {
				console.error(`[room] welcome notify to ${nick} failed: ${error}`);
			});
			// Who is already away. One line each rather than a field on the roster,
			// because that is the same line every later change arrives on: a client
			// learns the state and the change through one path instead of two that
			// have to agree. Bounded by the roster, which the room already bounds.
			for (const m of state.members) {
				if (m.away === "" || m.nick === nick) continue;
				session.tell(inbox, NOTIFY, ["room", `${m.nick} is away: ${m.away}`, AWAY, m.nick, m.away]).catch(
					(error) => {
						console.error(`[room] away notify to ${nick} failed: ${error}`);
					},
				);
			}
			// What the room is about, if it is about anything. Sent only when there
			// is one, because "no topic" is the absence of this line rather than a
			// line saying nothing — a room that announced an empty topic to every
			// arrival would be telling each of them it had just been taken down.
			if (state.topic !== "") {
				session.tell(inbox, NOTIFY, ["room", `the topic is: ${state.topic}`, TOPIC, state.topic]).catch(
					(error) => {
						console.error(`[room] topic notify to ${nick} failed: ${error}`);
					},
				);
			}
			// Answering with the topic capability is how a member comes to hold it.
			// An older client ignores the answer and simply has no topic to set.
			return topic;
		}
		if (verb === POST) {
			const member = findBySession(state, session);
			if (member === null) {
				throw new Error("post needs a claimed room membership");
			}
			// What rides after a line's text is the room's own vocabulary —
			// members read presence, typing, and file records there as the room's
			// word — so a post that supplies its own is refused rather than
			// relayed. A file goes out through `attach`, which is the one path
			// that puts a record on the wire.
			if (args.length > 1) {
				throw new RoomError(BAD_ATTACHMENT, "post carries trailing args; attach a file with attach()");
			}
			// The line goes out named, and the reference that governs it comes
			// back. Holding it is the authority to change or withdraw that one
			// line, so the verbs on it ask nobody who is calling — the same shape
			// `attach` uses, and the reason neither needs a membership check of
			// its own.
			const id = state.nextLine++;
			broadcast(state, member.nick, typeof args[0] === "string" ? args[0] : "", LINE, BigInt(id));
			// Past the bound the oldest goes back, so a member talking all day
			// costs the room a fixed number of exports rather than one per line.
			// Oldest first, because what a member wants to fix is what they just
			// said.
			const line = session.spawn(lineBehavior(state, member.nick, id));
			member.lines.push(line);
			while (member.lines.length > HELD_LINE_REFS) handBack(session, member.lines.shift()!);
			return line;
		}
		if (verb === POST_FILES) {
			if (args.length > 1 || (args[0] !== undefined && typeof args[0] !== "string")) {
				throw new RoomError(BAD_ATTACHMENT, "postFiles needs one caption");
			}
			postStagedFiles(state, session, typeof args[0] === "string" ? args[0] : "");
			return null;
		}
		if (verb === ATTACH) {
			// Begin one upload and answer with the capability that drives it.
			// Holding that capability is the authority to fill or discard this one
			// file, so those verbs need no membership check of their own —
			// only the member this reply reaches can call them.
			const member = findBySession(state, session);
			if (member === null) {
				throw new Error("attach needs a claimed room membership");
			}
			const name = typeof args[0] === "string" ? args[0] : "";
			const mime = typeof args[1] === "string" ? args[1] : "";
			const size = typeof args[2] === "bigint" ? Number(args[2]) : -1;
			const pixelCount = (value: Argument | undefined): number =>
				typeof value === "bigint" && value > 0n && value <= BigInt(MAX_IMAGE_DIM) ? Number(value) : 0;
			const width = pixelCount(args[3]);
			const height = pixelCount(args[4]);
			if (name.length === 0 || name.length > MAX_FILE_NAME) {
				throw new RoomError(ATTACHMENT_REFUSED, `a file name may be 1 to ${MAX_FILE_NAME} characters`);
			}
			if (mime.length > MAX_MIME) {
				throw new RoomError(ATTACHMENT_REFUSED, `a media type may be at most ${MAX_MIME} characters`);
			}
			if (size < 0 || size > MAX_ATTACHMENT_BYTES) {
				throw new RoomError(ATTACHMENT_REFUSED, `a file may be at most ${MAX_ATTACHMENT_BYTES} bytes`);
			}
			let pending = state.uploads.get(session);
			if (pending === undefined) {
				pending = new Set();
				state.uploads.set(session, pending);
			}
			if ([...pending].filter((upload) => !upload.posted).length >= MAX_MESSAGE_FILES) {
				throw new RoomError(
					ATTACHMENT_REFUSED,
					`post or abandon an upload first; ${MAX_MESSAGE_FILES} are already open`,
				);
			}
			// Held media can be evicted; bytes nobody has seen cannot, because
			// there is no owner to tell. So an upload that would not fit is
			// refused here, against the size it declares, before a byte moves.
			if (pendingBytes + size > MAX_SERVER_PENDING_BYTES) {
				throw new RoomError(
					ATTACHMENT_REFUSED,
					"the server is holding all the uploads it can; try again shortly",
				);
			}
			pendingBytes += size;
			const file: PostedFile = {
				room: state,
				name,
				mime,
				size,
				width,
				height,
				bytes: new Uint8Array(size),
				written: 0,
				failure: null,
				waiters: new Set(),
			};
			const upload: PendingUpload = {
				name,
				mime,
				size,
				width,
				height,
				file,
				posted: false,
				ref: null,
				expires: null,
			};
			pending.add(upload);
			armUploadTimer(state, session, upload);
			upload.ref = session.spawn(uploadBehavior(state, session, upload));
			return upload.ref;
		}
		if (verb === TYPING) {
			// Ephemeral: only a claimed member can signal, and the signal reaches the
			// other members alone. An un-subscribed connection is a silent no-op — a
			// stale typing flag is never worth an error.
			const member = findBySession(state, session);
			if (member !== null) broadcastTyping(state, member.nick, args[0] === true, session);
			return null;
		}
		if (verb === AWAY) {
			const member = findBySession(state, session);
			if (member === null) throw new Error("away needs a claimed room membership");
			const why = typeof args[0] === "string" ? args[0].slice(0, MAX_AWAY) : "";
			// Cut rather than refused: a reason is a courtesy, and losing the tail
			// of one is a smaller wrong than refusing to mark somebody away.
			if (why === member.away) return null;
			member.away = why;
			broadcast(
				state,
				"room",
				why === "" ? `${member.nick} is back` : `${member.nick} is away: ${why}`,
				AWAY,
				member.nick,
				why,
			);
			return null;
		}
		if (verb === LEAVE) {
			// Drop just this membership, keeping the connection open so the client can
			// enter another room. Idempotent: leaving a room you are not in is a no-op.
			leaveRoom(state, session);
			return null;
		}
		throw new Error(`room has no method ${verb}`);
	};
}

/** A room sturdyref is stable across sessions, while membership stays
 * connection-local. The room behind a link is the same room the directory
 * hands out, so this projects the same semantics; an empty linked room is
 * reconstituted on its first subscribe, whether it emptied earlier or the
 * process has just restarted.
 *
 * The room is published once for the whole Host rather than onto each accepted
 * session, because a link is redeemed by whoever holds it — including a peer
 * whose session opened long after the mint, and who asks the directory nothing.
 * A Host-wide object belongs to no one session, so the caller is the session
 * whose turn is running, which is what `currentSession` answers. */
function linkedRoomBehavior(name: string): Behavior {
	return (verb, args) => {
		const session = currentSession();
		if (session === null) throw new Error("a room link is reachable only over a session");
		let state = rooms.get(roomKey(name));
		if (state === undefined) {
			if (verb !== SUBSCRIBE) throw new Error("subscribe to this room before using it");
			state = makeRoomState(name, session);
			rooms.set(roomKey(name), state);
		}
		return roomBehavior(state, session)(verb, args);
	};
}

/** The directory behavior for one connection. `open`/`enter` return a live
 * reference to a room — the per-connection room view spawned here — so the room
 * a client holds is bound to that client's connection. */
export function directoryBehavior(links?: RoomLinks): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		// The directory belongs to the Host rather than to any one connection, so
		// the caller is the session whose turn is running. Everything below keys
		// on that: a registration, an introduction and a signaling exchange are
		// all facts about a connection.
		const session = currentSession();
		if (session === null) throw new Error("the directory is reachable only over a session");
		if (verb === REGISTER) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const locator = typeof args[1] === "string" ? args[1] : "";
			const inbox = args[2];
			if (nick.length === 0 || locator.length === 0) {
				throw new Error("register needs a nick and a locator");
			}
			if (!(inbox instanceof Ref)) {
				throw new Error("register needs an inbox capability");
			}
			// Only the directory can hold this: every member it introduces files an
			// inbox under this name and keeps it for good, so a name granted here
			// without a ceiling is an allocation the caller spends in somebody
			// else's process.
			if (nick.length > MAX_NICK) {
				throw new RoomError(
					NICK_TOO_LONG,
					`a name may be at most ${MAX_NICK} characters`,
				);
			}
			if (!isUriLocator(locator)) {
				try {
					designatorHostPort(locator);
				} catch {
					throw new Error("register locator must be hostname:port or an ocapn:// URI");
				}
			}
			if (!claimsOwnLocator(session, locator)) {
				throw new RoomError(
					NOT_YOUR_LOCATOR,
					`the locator "${locator}" does not name the connection registering it`,
				);
			}
			if (registeredByAnother(session, nick)) {
				throw new RoomError(
					NICK_TAKEN,
					`"${nick}" is registered by another member; it frees when they disconnect`,
				);
			}
			registerMember(nick, locator, inbox, session);
			return null;
		}
		if (verb === OFFER_INBOX) {
			const forNick = typeof args[0] === "string" ? args[0] : "";
			const offered = args[1];
			if (forNick.length === 0) throw new Error("offerInbox needs a peer nick");
			if (!(offered instanceof Ref)) {
				throw new Error("offerInbox needs an inbox capability");
			}
			if (forNick.length > MAX_NICK) {
				throw new RoomError(
					NICK_TOO_LONG,
					`a name may be at most ${MAX_NICK} characters`,
				);
			}
			// A member may only decide who reaches *it*, so the offer is filed under
			// the offering connection's own registration. An unregistered caller has
			// no record to file it under, which is the refusal.
			const ownNick = registeredNickOf(session);
			if (ownNick === null) {
				throw new RoomError(NOT_REGISTERED, "offerInbox needs a registered name");
			}
			const intro = introductions.get(nickKey(ownNick));
			if (intro === undefined) throw new Error("offerInbox found no registration");
			const key = nickKey(forNick);
			// The row is one per peer the member has offered for, and the member
			// chooses the peers, so the directory holds the same ceiling its members
			// do rather than growing a map on their word.
			if (!intro.inboxes.has(key) && intro.inboxes.size >= MAX_DM_INBOXES) {
				throw new Error(`a member may offer at most ${MAX_DM_INBOXES} inboxes`);
			}
			// The Host identity is already valid across this host's sessions; storing
			// it preserves exactly the capability the member offered.
			const token = offered;
			const prior = intro.inboxes.get(key);
			intro.inboxes.set(key, token);
			if (prior !== undefined) handBack(session, prior);
			// Whoever was told to wait can ask again now.
			const waiting = introductions.get(key);
			if (waiting !== undefined) {
				waiting.registrar.tell(waiting.inbox, NOTIFY, ["introducible", ownNick])
					.catch(() => {});
			}
			return null;
		}
		if (verb === OFFER_SIGNALING) {
			const offered = args[0];
			if (!(offered instanceof Ref)) {
				throw new Error("offerSignaling needs an inbox capability");
			}
			// One signaling inbox per member, filed under the caller's own
			// registration exactly as `offerInbox` files a DM inbox.
			const ownNick = registeredNickOf(session);
			if (ownNick === null) {
				throw new RoomError(NOT_REGISTERED, "offerSignaling needs a registered name");
			}
			const intro = introductions.get(nickKey(ownNick));
			if (intro === undefined) throw new Error("offerSignaling found no registration");
			if (intro.signaling !== null) handBack(session, intro.signaling);
			intro.signaling = offered;
			return null;
		}
		if (verb === SIGNAL_OFFER) {
			const toDesignator = typeof args[0] === "string" ? args[0] : "";
			const sdp = typeof args[1] === "string" ? args[1] : "";
			const reply = args[2];
			if (toDesignator.length === 0 || sdp.length === 0) {
				throw new Error("signalOffer needs a designator and an offer sdp");
			}
			if (!(reply instanceof Ref)) {
				throw new Error("signalOffer needs a reply capability");
			}
			if (registeredNickOf(session) === null) {
				throw new RoomError(NOT_REGISTERED, "signalOffer needs a registered name");
			}
			const targetKey = webrtcDesignators.get(toDesignator);
			const target = targetKey === undefined ? undefined : introductions.get(targetKey);
			if (target === undefined || target.signaling === null) {
				throw new RoomError(PEER_OFFLINE, "no signaling inbox for that designator");
			}
			// One live exchange per (caller, target): a repeat offer replaces the
			// prior bring-up attempt, so a retry cannot strand rows.
			const prior = originatedExchange(session, toDesignator);
			if (prior !== null) dropSignalExchange(prior, "signaling exchange was replaced");
			const id = `x${nextSignalExchange++}`;
			const expires = setTimeout(
				() => dropSignalExchange(id, "signaling exchange timed out"),
				SIGNAL_EXCHANGE_TIMEOUT_MS,
			);
			signalExchanges.set(id, {
				originator: session,
				reply,
				targetKey: targetKey!,
				expires,
			});
			while (signalExchanges.size > MAX_SIGNAL_EXCHANGES) {
				// Map iteration is insertion ordered and contains only live rows. Using
				// it directly keeps active exchange ownership and eviction order one fact.
				const oldest = signalExchanges.keys().next();
				if (oldest.done) throw new Error("signal exchange cap accounting drift");
				dropSignalExchange(oldest.value, "signaling exchange was evicted");
			}
			// Admission is explicit because the minted id is the stable identity for
			// candidates and retirement. A designator can name a later exchange.
			session.tell(reply, SIG_ACCEPTED, [id]).catch(() => {});
			target.registrar.tell(target.signaling, SIG_OFFER, [id, sdp]).catch(() => {});
			return null;
		}
		if (verb === SIGNAL_ANSWER) {
			const id = typeof args[0] === "string" ? args[0] : "";
			const sdp = typeof args[1] === "string" ? args[1] : "";
			const exchange = signalExchanges.get(id);
			if (exchange === undefined) return null; // evicted or settled: drop
			// Only the exchange's target may answer it: the caller's session must be
			// the registrar holding the target registration.
			const target = introductions.get(exchange.targetKey);
			if (target === undefined || target.registrar !== session) {
				throw new Error("signalAnswer from a session that does not answer this exchange");
			}
			exchange.originator.tell(exchange.reply, SIG_ANSWER, [sdp]).catch(() => {});
			return null;
		}
		if (verb === SIGNAL_CANDIDATE) {
			const key = typeof args[0] === "string" ? args[0] : "";
			const ice = typeof args[1] === "string" ? args[1] : "";
			if (key.length === 0 || ice.length === 0) return null;
			// Both sides name the exact exchange. Session ownership decides the
			// direction, so neither side can inject into another exchange.
			const exchange = signalExchanges.get(key);
			if (exchange === undefined) return null; // evicted or settled: drop
			if (exchange.originator === session) {
				const target = introductions.get(exchange.targetKey);
				if (target === undefined || target.signaling === null) return null;
				target.registrar.tell(target.signaling, SIG_CANDIDATE, [key, ice])
					.catch(() => {});
				return null;
			}
			const target = introductions.get(exchange.targetKey);
			if (target === undefined || target.registrar !== session) return null;
			exchange.originator.tell(exchange.reply, SIG_CANDIDATE, [ice]).catch(() => {});
			return null;
		}
		if (verb === SIGNAL_DONE) {
			const id = typeof args[0] === "string" ? args[0] : "";
			const exchange = signalExchanges.get(id);
			if (exchange !== undefined && exchange.originator === session) {
				dropSignalExchange(id);
			}
			return null;
		}
		if (verb === INTRODUCE) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const intro = introductions.get(nickKey(nick));
			// The same liveness `register` reads: a holder whose connection has gone
			// but whose close callback has not run yet is nobody to be introduced to.
			if (intro === undefined || !intro.registrar.sessionOpen) {
				throw new RoomError(PEER_OFFLINE, `no member named "${nick}" is registered`);
			}
			// The caller's registered nick is the key the member filed their inbox
			// under, so an unregistered caller has no name one could have been minted
			// for and no inbox the directory could ask for one on.
			const callerNick = registeredNickOf(session);
			if (callerNick === null) {
				throw new RoomError(NOT_REGISTERED, "introduce needs a registered name");
			}
			const inbox = intro.inboxes.get(nickKey(callerNick));
			if (inbox === undefined) {
				// Genuine first contact. Ask the member for an inbox for this caller
				// and tell the caller to come back.
				intro.registrar.tell(intro.inbox, NOTIFY, ["mintInboxFor", callerNick])
					.catch(() => {});
				throw new RoomError(
					INTRODUCTION_PENDING,
					`"${nick}" has been asked for an inbox for "${callerNick}"; try again`,
				);
			}
			// Returning a reference whose home is the directory-to-member connection
			// trips the transparent gifter: the caller gets a give, not a relay.
			return inbox;
		}
		const name = typeof args[0] === "string" ? args[0] : "";
		if (verb === LINK) {
			if (links === undefined) throw new Error("this directory does not publish room links");
			const state = rooms.get(roomKey(name));
			if (state === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			return links.link(state.name);
		}
		if (verb === OPEN) {
			if (name.length === 0) throw new Error("open needs a room name");
			if (name.length > MAX_ROOM) {
				throw new RoomError(
					ROOM_TOO_LONG,
					`a room name may be at most ${MAX_ROOM} characters`,
				);
			}
			if (rooms.has(roomKey(name))) {
				throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
			}
			const state = makeRoomState(name, session);
			rooms.set(roomKey(name), state);
			return session.spawn(roomBehavior(state, session));
		}
		if (verb === ENTER) {
			const state = rooms.get(roomKey(name));
			if (state === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			return session.spawn(roomBehavior(state, session));
		}
		if (verb === LIST) return snapshot();
		if (verb === WATCH) {
			const observer = args[0];
			if (!(observer instanceof Ref)) {
				throw new Error("watch needs an inbox capability");
			}
			// One live view of the directory per connection. Every room event walks
			// this list, so a connection able to add rows to it without limit would
			// make each join and departure anywhere on this server do its work again
			// for every row that connection had asked for. Watching again replaces,
			// the same way a connection re-claiming its place in a room replaces its
			// membership rather than being seated twice.
			dropWatchers(session);
			watchers.push({ observer, session });
			// Replay the members already introducible for direct messages, so a
			// fresh watcher (a browser tab, say) starts with the same DM-able set
			// everyone else already knows. The room-list baseline is the return
			// value; these arrive as ordinary deltas on the inbox.
			for (const intro of introductions.values()) {
				session.tell(observer, NOTIFY, ["registered", intro.nick, 1n]).catch(() => {});
			}
			return snapshot(); // a baseline; deltas follow on the inbox
		}
		throw new Error(`directory has no method ${verb}`);
	};
}

/** Read an optional env var when permission is granted; otherwise undefined. */
function optionalEnv(name: string): string | undefined {
	const allowed = Deno.permissions.querySync({ name: "env", variable: name }).state ===
		"granted";
	if (!allowed) return undefined;
	const value = Deno.env.get(name)?.trim();
	return value && value.length > 0 ? value : undefined;
}

// The live timeline endpoint (ocapnviz Live mode): set ROOMS_VIZ_PORT to serve
// it on that port. Opt-in and read only when env access is granted, like
// ROOMS_TRANSPORT beside it; without it the tap stays cold and every emit site
// is one null check. `0` takes an ephemeral port, the way the room's own
// positional port argument does; either way the port it actually bound is the
// one it announces.
//
// The room's own trace goes in through the same door every other peer's does,
// so a member's direct messages — sessions the room never carries — appear on
// the same timeline. Each session's `a` endpoint is this host's own key
// designator, the name a partner knows it by and so the one name two producers
// can agree on; "rooms" rides beside it as what a reader should see.
function maybeStartViz(): void {
	const raw = optionalEnv("ROOMS_VIZ_PORT");
	if (!raw) return;
	const port = Number(raw);
	if (!Number.isInteger(port) || port < 0) {
		console.error(`server.ts: ROOMS_VIZ_PORT is not a port: "${raw}"`);
		Deno.exit(2);
	}
	const viz = startViz(port);
	enableTrace(viz.sink, { selfLabel: "rooms" });
}

function transportArg(): "tcp" | "iroh" {
	const flag = Deno.args.find((a) => a.startsWith("--transport="));
	// ROOMS_TRANSPORT is a convenience for manual runs; only read it when env
	// access is granted so the default (TCP) permission set never trips.
	const choice = (flag ? flag.slice("--transport=".length) : optionalEnv("ROOMS_TRANSPORT")) ??
		"tcp";
	if (choice !== "tcp" && choice !== "iroh") {
		console.error(
			`server.ts: unknown transport "${choice}" (expected tcp or iroh)`,
		);
		Deno.exit(2);
	}
	return choice;
}

/** iroh dial posture: `direct` (default, hermetic) or `discovery` (n0 + pkarr). */
function reachabilityArg():
	| typeof irohTransport.Reachability.Direct
	| typeof irohTransport.Reachability.Discovery {
	const choice = (optionalEnv("ROOMS_REACHABILITY") ?? "direct").toLowerCase();
	if (choice === "discovery") return irohTransport.Reachability.Discovery;
	if (choice === "direct") return irohTransport.Reachability.Direct;
	console.error(
		`server.ts: unknown reachability "${choice}" (expected direct or discovery)`,
	);
	Deno.exit(2);
}

/** Serve the directory on every connection `server` accepts until it closes. */
export async function serveDirectory(
	host: Host,
	server: AsyncIterable<Session>,
	links?: RoomLinks,
): Promise<void> {
	// Published on the Host before the first session is taken, and not onto each
	// one as it arrives. A loop-backed listener dispatches an accepted session's
	// first message as it steps, which can be before this loop's body has run at
	// all: publishing per session left a dial that fetched immediately racing the
	// accept, and losing it was answered `unknown swissnum`. A Host-wide object
	// exists before any connection does, so there is no window to lose.
	host.publishGiftable(DIRECTORY, directoryBehavior(links));
	for await (const session of server) {
		// Presence is indexed by connection, so retire it at the transport's own
		// terminal boundary. Learning this from a later failed notify leaves stale
		// membership between closure and the next broadcast.
		const stopClose = session.onClose(() => scheduleDisconnect(session));
		// When the member's connection ends, the membership cleanup runs and
		// then the session itself is retired. Without the close, the native
		// session shell outlives its dead transport: the host accumulates one
		// shell per departed member, and the live timeline never hears this
		// side of the wire end, so a vanished member's session lingers on the
		// picture until the room server restarts.
		session.serve().catch((error) => {
			console.error(`[room] session failed: ${error}`);
		}).finally(() => {
			stopClose();
			scheduleDisconnect(session); // pre-transport serve refusal joins the same cleanup batch
			session.close().catch((error) => {
				console.error(`[room] session retirement failed: ${error}`);
			});
		});
	}
}

// The top-level bootstrap runs only when this file is the program, so the demo
// orchestrator (and tests) can import the behaviors without binding a socket.
/** Everything between "this process was asked to be a room server" and "it is
 * listening". Named so its failures have somewhere to land: the backstop above
 * keeps one stray notify from taking CapTP down, and it was catching these too
 * — a server that could not start printed a stack trace, went on running with
 * nothing listening, and exited 0, which tells whatever supervises it that all
 * is well. */
async function start(): Promise<void> {
	// Positional args are the port (TCP only); iroh has no port to pin.
	const positional = Deno.args.filter((a) => !a.startsWith("--"));
	maybeStartViz();
	const transport = transportArg();
	const state = await RoomServerState.open(optionalEnv("ROOMS_STATE"));
	const host = roomsHost(state.identitySeed);
	const links = await RoomLinks.restore(
		state,
		(name, entropy) => host.publishDurable(linkedRoomBehavior(name), entropy),
	);

	// The harness and the web bridge parse the announce line: a bare port is a TCP
	// locator (127.0.0.1:<port>), an ocapn:// URI is an iroh locator.
	if (transport === "iroh") {
		// One seed for the host identity AND the endpoint, so every accepted
		// session signs with the endpoint's own key.
		const reach = reachabilityArg();
		// A room reads a live session as presence: a member holds its nickname
		// for exactly as long as its connection is open. Over TCP a member that
		// is killed is gone at once, because the operating system sends a FIN
		// as the process dies. UDP has no equivalent, so here the connection
		// ends only when QUIC gives up on a peer that stopped answering, and
		// until then the room still holds the nickname of somebody who left.
		// Eight seconds is the room's answer to how long that may take.
		const iroh = await irohTransport.listen(
			{ reachability: reach, idleTimeoutMs: 8_000 },
			{ host },
		);
		const announce = reach === irohTransport.Reachability.Discovery
			? formatPeerUri(TRANSPORT_IROH, iroh.nodeId)
			: iroh.uri;
		console.log(`ROOMS-SERVER-LISTENING ${announce}`);
		await serveDirectory(host, iroh, links);
	} else {
		const bindHost = optionalEnv("ROOMS_BIND") ?? "127.0.0.1";
		const announceHost = optionalEnv("ROOMS_ANNOUNCE_HOST");
		const asked = Number(positional[0] ?? "0");
		// A pancake listener asks for a reusable address, which on Linux lets a
		// second one hold the same address rather than refusing it: both bind,
		// both announce, and the kernel hands each arriving connection to
		// whichever it likes. Two servers with different identities then answer
		// one address, and in a room that looks like two members joining the same
		// name and never seeing each other, with nothing said on either side.
		//
		// So ask first, with a socket that does not share: `Deno.listen` sets no
		// such option, so it is refused by exactly the listener this needs to find
		// and by nothing else. Only for a port that was named — asking for an
		// ephemeral one is asking for whichever is free.
		if (asked !== 0) {
			try {
				Deno.listen({ hostname: bindHost, port: asked }).close();
			} catch {
				throw new Error(
					`${bindHost}:${asked} is already in use, most likely by another rooms server. ` +
						"Two of them can hold one address without either being told, so this one is " +
						"stopping rather than splitting members between rooms they cannot see across. " +
						"Stop the other server, or give this one a different port.",
				);
			}
		}
		// The host is minted here rather than left to `listen`'s default,
		// so this branch names the rooms codec exactly as the iroh branch
		// above does. A default host would speak the Syrup interop floor
		// and refuse every rooms peer's frames.
		const tcp = await roomsListen(bindHost, asked, host);
		const boundPort = tcp.port;
		if (announceHost) {
			const designator = addressDesignator(announceHost, boundPort);
			tcp.host.setAdvertisedLocator({
				transport: TRANSPORT_TCP,
				designator,
				hints: new Map(),
				hintWireForm: "map",
			});
			console.log(`ROOMS-SERVER-LISTENING ${designator}`);
		} else {
			console.log(`ROOMS-SERVER-LISTENING ${boundPort}`);
		}
		await serveDirectory(host, tcp, links);
	}
}

if (import.meta.main) {
	try {
		await start();
	} catch (err) {
		// Said as a sentence an operator can act on, and exited non-zero so a
		// supervisor learns the same thing. The state file is named because it is
		// the one input here a person can repair by hand.
		const said = err instanceof Error ? err.message : String(err);
		console.error(`rooms: could not start: ${said}`);
		const state = optionalEnv("ROOMS_STATE");
		if (state !== undefined && /rooms state/.test(said)) {
			console.error(
				`rooms: ${state}/rooms.json holds this server's identity and its durable room links. ` +
					"Repair it, or move it aside to start fresh — the links it names will not come back.",
			);
		}
		Deno.exit(1);
	}
}
