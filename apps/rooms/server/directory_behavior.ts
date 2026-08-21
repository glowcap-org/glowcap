// The directory behavior for one connection, and the inspect snapshot of it.
//
// `open`/`enter` return a live reference to a room bound to that client's
// connection. Callers still go through `main.ts`.

import {
	type Argument,
	type Behavior,
	currentSession,
	designatorHostPort,
	parseLocator,
	Ref,
	TRANSPORT_WEBRTC,
} from "@pancake/runtime";
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
	ROOM_TOO_LONG,
	RoomError,
} from "../lib/errors.ts";
import {
	MAX_DM_INBOXES,
	MAX_ROOM,
	MAX_SIGNAL_EXCHANGES,
	MAX_SIGNAL_SDP,
	nickRefusal,
	relayedSignalFits,
	SIGNAL_EXCHANGE_TIMEOUT_MS,
} from "../lib/limits.ts";
import {
	DIRECTORY,
	ENTER,
	INTRODUCE,
	LINK,
	LIST,
	NOTIFY,
	OFFER_INBOX,
	OFFER_SIGNALING,
	OPEN,
	REGISTER,
	SIG_ACCEPTED,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_OFFER,
	SIGNAL_ANSWER,
	SIGNAL_CANDIDATE,
	SIGNAL_DONE,
	SIGNAL_OFFER,
	SNAPSHOT,
	WATCH,
} from "../lib/protocol.ts";
import { RoomLinks } from "./state.ts";
import { roomBehavior } from "./room.ts";
import {
	claimsOwnLocator,
	dropSignalExchange,
	originatedExchange,
	registeredByAnother,
	registeredNickOf,
	registerMember,
} from "./introductions.ts";
import { snapshot } from "./presence.ts";
import { dropWatchers, watchers } from "./watchers.ts";
import {
	handBack,
	heldRoomLinks,
	introductions,
	makeRoomState,
	mintSignalExchangeId,
	nickKey,
	registerRoom,
	roomKey,
	rooms,
	signalExchanges,
	webrtcDesignators,
} from "./registry.ts";

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
			const unregisterable = nickRefusal(nick);
			if (unregisterable !== null) throw new RoomError(NICK_TOO_LONG, unregisterable);
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
			// A `webrtc` designator routes signaling, and an unkeyed connection's
			// claim to one cannot be verified (`claimsOwnLocator` says why, and
			// what full verification would take). What *can* be refused without any
			// keys is a claim to a designator another live registration already
			// routes by: accepting it overwrote the holder's row, and every DM
			// bring-up aimed at them landed in the claimant's signaling inbox.
			// First writer holds the designator while their connection stands.
			if (isUriLocator(locator)) {
				const claimed = parseLocator(locator);
				if (claimed.transport === TRANSPORT_WEBRTC) {
					const holderKey = webrtcDesignators.get(claimed.designator);
					const holder = holderKey === undefined ? undefined : introductions.get(holderKey);
					if (holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen) {
						throw new RoomError(
							NOT_YOUR_LOCATOR,
							`that webrtc designator is already registered to "${holder.nick}"`,
						);
					}
				}
			}
			// The reply is the name capability: the holding of the name, which is
			// what lets its holder be this member from another connection.
			return registerMember(nick, locator, inbox, session);
		}
		if (verb === OFFER_INBOX) {
			const forNick = typeof args[0] === "string" ? args[0] : "";
			const offered = args[1];
			if (!(offered instanceof Ref)) {
				throw new Error("offerInbox needs an inbox capability");
			}
			const unofferable = nickRefusal(forNick);
			if (unofferable !== null) throw new RoomError(NICK_TOO_LONG, unofferable);
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
			// The room carries this to the other member as it stands, so its size is
			// this room's to bound rather than the sender's to choose.
			if (!relayedSignalFits("description", toDesignator, sdp)) {
				throw new Error(
					`signalOffer needs a designator and an offer sdp of at most ${MAX_SIGNAL_SDP} bytes`,
				);
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
			const id = mintSignalExchangeId();
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
			if (!relayedSignalFits("description", id, sdp)) {
				throw new Error(`a signaling answer may be at most ${MAX_SIGNAL_SDP} bytes`);
			}
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
			// One candidate is a line of text. Dropped rather than refused, because a
			// candidate is best-effort on both sides and one lost costs a route, not
			// the bring-up.
			if (!relayedSignalFits("candidate", key, ice)) return null;
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
			// Private is asked for at the moment a room is made and never after:
			// a room that could be made private later would already have been
			// listed, and one that could be opened up would surprise the people
			// who were invited into it.
			const wantsPrivate = args[1] === true;
			// Only a public name is taken, because only a public name is a way in.
			// Two readers may each keep a private room called "notes", and neither
			// learns that the other has one — which is also why this cannot answer
			// "already exists" for a private name: that answer is itself the leak.
			if (!wantsPrivate && rooms.has(roomKey(name))) {
				throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
			}
			const state = makeRoomState(name, session, { private: wantsPrivate });
			registerRoom(state);
			return session.spawn(roomBehavior(state));
		}
		if (verb === ENTER) {
			const state = rooms.get(roomKey(name));
			if (state === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			return session.spawn(roomBehavior(state));
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

/** What the inspect capability can currently see of this directory.
 *
 * Rows are `[kind, name, note]`. Live room references are not handed out here:
 * holding inspect is the right to *see* the namespace, and entering a room is
 * still `enter` / `open` on the directory the caller already fetched. Durable
 * room links are listed by the swiss they answer to, which is the OCapN name. */
function diagnosticSnapshot(): Argument[] {
	const rows: Argument[] = [[
		"directory",
		DIRECTORY,
		"published bootstrap",
	]];
	for (const state of rooms.values()) {
		const place = state.private ? "private" : "public";
		rows.push([
			"room",
			state.name,
			`${place}, ${state.members.length} here`,
		]);
		for (const member of state.members) {
			rows.push(["occupant", member.nick, `in ${state.name}`]);
		}
	}
	for (const intro of introductions.values()) {
		rows.push([
			"registration",
			intro.nick,
			`${intro.inboxes.size} inboxes offered`,
		]);
	}
	const links = heldRoomLinks();
	if (links !== null) {
		for (const { name, swiss } of links.named()) {
			rows.push(["link", name, swiss]);
		}
	}
	return rows;
}

export function inspectBehavior(): Behavior {
	return (verb: string): ReturnType<Behavior> => {
		if (verb === SNAPSHOT) return diagnosticSnapshot();
		throw new Error(`diagnostics has no method ${verb}`);
	};
}
