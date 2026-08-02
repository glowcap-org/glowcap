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
// `publish` makes the directory fetchable by name; the directory and room
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
// `ROOMS_ANNOUNCE_HOST` (when set) is the dialable hostname printed and used as
// the self-designator. Either way the announce line is
// `ROOMS-SERVER-LISTENING <locator>`, which the demo harness and web bridge read
// to point clients at the right place.
//
// Run it:  deno run --allow-ffi --allow-net --allow-read --allow-env server.ts 9099
//          ROOMS_TRANSPORT=iroh deno run -A --unstable-ffi server.ts
//          ROOMS_TRANSPORT=iroh ROOMS_REACHABILITY=discovery deno run -A --unstable-ffi server.ts

import {
	type Argument,
	designatorHostPort,
	durableIdentityAuthenticated,
	encodePeerLocator,
	formatPeerUri,
	HINT_DIRECT_ADDRESSES,
	Host,
	listen,
	parseLocator,
	Ref,
	type Session,
	socketAddrDesignator,
	TRANSPORT_IROH,
	TRANSPORT_TCP,
	TRANSPORT_WEBRTC,
} from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
import { isUriLocator } from "../lib/locator.ts";
import {
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_SUCH_ROOM,
	NOT_REGISTERED,
	NOT_YOUR_LOCATOR,
	PEER_OFFLINE,
	ROOM_EXISTS,
	RoomError,
} from "../lib/errors.ts";
import { MAX_DM_INBOXES, MAX_NICK, MAX_SIGNAL_EXCHANGES } from "../lib/limits.ts";
import {
	DIRECTORY,
	ENTER,
	INTRODUCE,
	LEAVE,
	LIST,
	NOTIFY,
	OFFER_INBOX,
	OFFER_SIGNALING,
	OPEN,
	POST,
	REGISTER,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_OFFER,
	SIGNAL_ANSWER,
	SIGNAL_CANDIDATE,
	SIGNAL_OFFER,
	SUBSCRIBE,
	TYPING,
	WATCH,
} from "../lib/protocol.ts";

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
}

/** A live room: its display name (the casing the opener chose), its roster, and
 * the connection that opened it. The room owns its members and its broadcast;
 * the directory owns the set of rooms. A room lives while it has members; an
 * `open`ed room with no members yet is reclaimed if its opener disconnects
 * before subscribing. */
interface RoomState {
	name: string;
	members: Member[];
	creator: Session;
}

const rooms = new Map<string, RoomState>();

/** One introducible member.
 *
 * `inboxes` is what `introduce` hands out: the capability this member offered for
 * each peer, keyed by that peer's nick, so a caller only ever gets the one minted
 * for them. `inbox` is the member's register inbox, where the directory asks for
 * an inbox it needs and tells a waiting caller one has arrived.
 *
 * The registered locator is stamped as the registrar session's exporter location
 * so redeem dials the member's listen endpoint, not its ephemeral room-dial
 * address. */
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
}

const signalExchanges = new Map<string, SignalExchange>();
const signalExchangeOrder: string[] = [];
let nextSignalExchange = 0;

function dropSignalExchange(id: string): void {
	const exchange = signalExchanges.get(id);
	if (exchange === undefined) return;
	signalExchanges.delete(id);
	giveBackInbox(exchange.originator, exchange.reply);
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
 * The directory repeats this locator to everyone it introduces, and they dial
 * it. One it cannot tie to the caller is therefore a dial aimed on their behalf
 * at an address the caller chose, worth closing wherever it can be closed.
 *
 * It can be closed exactly when the registering connection is keyed: the
 * handshake has verified the partner holds the key its designator names, so a
 * claim to be at that designator is checkable against it.
 *
 * It cannot be closed otherwise, and the reason is worth stating rather than
 * papering over. The transport a member reaches the *directory* over is not the
 * transport other members reach the *member* over. A browser peer talks to the
 * room through a relayed TCP socket while being reachable at a keyed-relay
 * designator of its own, so its connection here proves nothing about the address
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
	const claimed = isUriLocator(locator) ? parseLocator(locator).designator : socketAddrDesignator(
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
	// Stamp advertised locator: redeem must dial the listen endpoint, not the
	// member's outbound client address from the room dial. The verb refused any
	// locator this connection could not be tied to before getting here.
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		session.setExporterLocator(encodePeerLocator({
			transport: loc.transport,
			designator: loc.designator,
			directAddresses: loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "",
		}));
	} else {
		const { hostname, port } = designatorHostPort(locator);
		session.setExporterLocator(encodePeerLocator({
			transport: TRANSPORT_TCP,
			designator: socketAddrDesignator(hostname, port),
		}));
	}
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
	if (intro.signaling !== null) giveBackInbox(intro.registrar, intro.signaling);
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
function giveBackInbox(offerer: Session, ref: Ref): void {
	try {
		offerer.release(ref);
	} catch {
		// Nothing to give back: that connection's teardown reclaimed it.
	}
}

/** Hand back every inbox an introduction collected. */
function releaseInboxes(intro: Introduction): void {
	for (const ref of intro.inboxes.values()) giveBackInbox(intro.registrar, ref);
	intro.inboxes.clear();
}

/** Drop the inbox every other member offered for `key`, so an `introduce` naming
 * it is refused `introduction-pending` and the member mints a fresh one. */
function forgetOfferedInboxes(key: string): void {
	for (const intro of introductions.values()) {
		const ref = intro.inboxes.get(key);
		if (ref === undefined) continue;
		intro.inboxes.delete(key);
		giveBackInbox(intro.registrar, ref);
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
	...presence: string[]
): void {
	// A presence line carries structured trailing args after the display text — a
	// join/leave kind and the nick — so a member reads the change without parsing the
	// prose. A chat line passes none.
	for (const m of [...state.members]) {
		m.session.tell(m.inbox, NOTIFY, [from, text, ...presence]).catch(() => leaveAll(m.session));
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
		m.session.tell(m.inbox, NOTIFY, ["room", "", "typing", nick, on]).catch(() =>
			leaveAll(m.session)
		);
	}
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
	for (let i = state.members.length - 1; i >= 0; i -= 1) {
		if (state.members[i].session === session) {
			const member = state.members[i];
			state.members.splice(i, 1);
			removed = true;
			if (!silent) {
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
		rooms.delete(roomKey(state.name));
	}
	// A real departure changes the live room list: the room closed if it emptied,
	// else its count dropped. A silent resubscribe leaves the count unchanged.
	if (!silent && removed) {
		if (state.members.length === 0) notifyWatchers("closed", state.name, 0);
		else notifyWatchers("count", state.name, state.members.length);
	}
	return removed;
}

/** Drop a session from every room it is in, the cleanup when its socket
 * closes. Also reclaim any room this session opened but never subscribed to,
 * so an abandoned `open` does not leak an empty room. */
function leaveAll(session: Session): void {
	for (const state of [...rooms.values()]) {
		leaveRoom(state, session);
		if (state.members.length === 0 && state.creator === session) {
			rooms.delete(roomKey(state.name));
		}
	}
	dropWatchers(session);
	dropIntroductions(session);
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
			// A resubscribe (same connection re-claiming) nets no count change, so it
			// must not fire a discovery event; a fresh membership does.
			const wasMember = findBySession(state, session) !== null;
			if (wasMember) leaveRoom(state, session, true);
			state.members.push({ nick, inbox, session });
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
			]).catch(() => leaveAll(session));
			return null;
		}
		if (verb === POST) {
			const member = findBySession(state, session);
			if (member === null) {
				throw new Error("post needs a claimed room membership");
			}
			broadcast(state, member.nick, typeof args[0] === "string" ? args[0] : "");
			return null;
		}
		if (verb === TYPING) {
			// Ephemeral: only a claimed member can signal, and the signal reaches the
			// other members alone. An un-subscribed connection is a silent no-op — a
			// stale typing flag is never worth an error.
			const member = findBySession(state, session);
			if (member !== null) broadcastTyping(state, member.nick, args[0] === true, session);
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

/** The directory behavior for one connection. `open`/`enter` return a live
 * reference to a room — the per-connection room view spawned here — so the room
 * a client holds is bound to that client's connection. */
export function directoryBehavior(session: Session) {
	return (verb: string, args: Argument[]): Argument => {
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
			const holder = introductions.get(nickKey(nick));
			if (
				holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen
			) {
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
			if (prior !== undefined) giveBackInbox(session, prior);
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
			if (intro.signaling !== null) giveBackInbox(session, intro.signaling);
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
			if (prior !== null) dropSignalExchange(prior);
			const id = `x${nextSignalExchange++}`;
			signalExchanges.set(id, { originator: session, reply, targetKey: targetKey! });
			signalExchangeOrder.push(id);
			while (signalExchangeOrder.length > MAX_SIGNAL_EXCHANGES) {
				dropSignalExchange(signalExchangeOrder.shift()!);
			}
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
			// The offering side names the target's designator (it holds no exchange
			// id); the answering side names the exchange id it was offered. Resolve
			// by who is calling, so neither can inject into the other's exchange.
			const originated = originatedExchange(session, key);
			if (originated !== null) {
				const exchange = signalExchanges.get(originated)!;
				const target = introductions.get(exchange.targetKey);
				if (target === undefined || target.signaling === null) return null;
				target.registrar.tell(target.signaling, SIG_CANDIDATE, [originated, ice])
					.catch(() => {});
				return null;
			}
			const exchange = signalExchanges.get(key);
			if (exchange === undefined) return null; // evicted or settled: drop
			const target = introductions.get(exchange.targetKey);
			if (target === undefined || target.registrar !== session) return null;
			exchange.originator.tell(exchange.reply, SIG_CANDIDATE, [ice]).catch(() => {});
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
		if (verb === OPEN) {
			if (name.length === 0) throw new Error("open needs a room name");
			if (rooms.has(roomKey(name))) {
				throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
			}
			const state: RoomState = { name, members: [], creator: session };
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
function reachabilityArg(): typeof Reachability.Direct | typeof Reachability.Discovery {
	const choice = (optionalEnv("ROOMS_REACHABILITY") ?? "direct").toLowerCase();
	if (choice === "discovery") return Reachability.Discovery;
	if (choice === "direct") return Reachability.Direct;
	console.error(
		`server.ts: unknown reachability "${choice}" (expected direct or discovery)`,
	);
	Deno.exit(2);
}

/** Serve the directory on every connection `server` accepts until it closes. */
export async function serveDirectory(server: AsyncIterable<Session>): Promise<void> {
	for await (const session of server) {
		session.publish(DIRECTORY, directoryBehavior(session)); // fetchable by name
		session.serve().then(
			() => leaveAll(session),
			() => leaveAll(session),
		);
	}
}

// The top-level bootstrap runs only when this file is the program, so the demo
// orchestrator (and tests) can import the behaviors without binding a socket.
if (import.meta.main) {
	// Positional args are the port (TCP only); iroh has no port to pin.
	const positional = Deno.args.filter((a) => !a.startsWith("--"));
	const transport = transportArg();

	// The harness and the web bridge parse the announce line: a bare port is a TCP
	// locator (127.0.0.1:<port>), an ocapn:// URI is an iroh locator.
	if (transport === "iroh") {
		// One seed for the host identity AND the endpoint, so every accepted
		// session signs with the endpoint's own key.
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const host = new Host(seed);
		const reach = reachabilityArg();
		const iroh = listenIroh(reach, seed, host);
		const announce = reach === Reachability.Discovery
			? formatPeerUri(TRANSPORT_IROH, iroh.nodeId)
			: iroh.uri;
		console.log(`ROOMS-SERVER-LISTENING ${announce}`);
		await serveDirectory(iroh);
	} else {
		const bindHost = optionalEnv("ROOMS_BIND") ?? "127.0.0.1";
		const announceHost = optionalEnv("ROOMS_ANNOUNCE_HOST");
		const tcp = listen(bindHost, Number(positional[0] ?? "0"));
		const boundPort = await tcp.ready();
		if (announceHost) {
			const designator = socketAddrDesignator(announceHost, boundPort);
			tcp.host.setSelfDesignator(designator);
			console.log(`ROOMS-SERVER-LISTENING ${designator}`);
		} else {
			console.log(`ROOMS-SERVER-LISTENING ${boundPort}`);
		}
		await serveDirectory(tcp);
	}
}
