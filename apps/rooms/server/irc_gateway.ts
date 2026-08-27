// The IRC gateway: channels bridged into this directory on an operator's say.
//
// The standalone bridge (`irc/main.ts`) serves one argv-chosen channel as its
// own directory. This is the same machinery made dynamic and folded into the
// main directory: holding the gateway capability, an operator joins a channel
// and it stands beside the native rooms — entered, listed, and watched like
// any of them — then parts it and it is gone. One shared IRC connection per
// bridged channel is the read feed, exactly the standalone bridge's posture,
// which is what keeps `irc/client.ts` untouched.
//
// Members are IRC citizens, not ventriloquists: each member seated in a
// bridged room gets their own reader connection carrying their nick — joined
// when they sit down, speaking only when they post, gone when they leave.
// A post reaches IRC as the member or does not happen: failing the post
// closed beats showing the room a line the channel never carried. A dropped
// reader connection is not respun in the dark; the seat shows the failure,
// and the next post opens a fresh one — a retry a person can see. Registered
// account credentials are accepted only over TLS and live only beside this
// seat's connection.

import { type Argument, type Behavior, currentSession, type Session } from "@pancake/runtime";
import { IrcBridgeRoom } from "../irc/bridge.ts";
import { IrcChannelRelay } from "../irc/outbound.ts";
import { openReaderConnection, type ReaderLink } from "../irc/reader_connection.ts";
import { ircFold } from "../irc/protocol.ts";
import { type SaslPlainCredentials, validateIrcNick, validateSaslPlain } from "../irc/registration.ts";
import { automaticIrcNick, ircNickRenameRefusal } from "../irc/identity.ts";
import { AWAY, IRC_DISCONNECT, IRC_IDENTITY, type IrcSeatPhase, LEAVE, POST, SUBSCRIBE } from "../lib/protocol.ts";
import { forgetBridgeRoom, registerBridgeRoom } from "./registry.ts";
import { notifyPublicRoom } from "./discovery.ts";
import { noteTrouble } from "./journal.ts";
import { noteOperatorChange } from "./operator/revision.ts";
import type { IrcBridgeIntent, RoomServerOperationsState } from "./operations_state.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import { driveIrcBridge } from "./irc_gateway/driver.ts";

interface ReaderSeat {
	ircNick: string;
	/** The nick this seat actually wears on the network right now: the
	 * chosen one until the wire says otherwise — a held-name retry suffixes
	 * an automatic projection. Any other wire-selected name fails the link
	 * rather than silently replacing the Rooms name. The feed's echo suppression and the
	 * member's own room both follow this, not the wish. */
	liveNick: string;
	phase: IrcSeatPhase;
	/** Automatic projection names may take the one collision suffix. Once the
	 * reader chooses an identity, landing on any other nick is a refusal. */
	identityChosen: boolean;
	/** False after an explicit disconnect. A Rooms-only member must not be
	 * silently reconnected by their next post. */
	enabled: boolean;
	/** The member's own registered account, handed over once through the room
	 * and held only here, beside the connections it authenticates: never
	 * persisted, never answered back, gone with the seat. */
	sasl?: SaslPlainCredentials;
	link: ReaderLink | null;
	opening: Promise<ReaderLink> | null;
	openingAbort: AbortController | null;
	/** Unregister the transport-close listener when leave or part retires the
	 * membership explicitly, so a later rejoin owns exactly one callback. */
	stopClose: () => void;
}

class SeatSuperseded extends Error {}

interface BridgedChannel {
	readonly network: string;
	readonly channel: string;
	readonly roomName: string;
	readonly host: string;
	readonly port: number;
	readonly tls: boolean;
	readonly nick: string;
	/** The shared feed's registered account. It is absent from snapshot rows and
	 * trouble output. A stateful server restores it only from the protected
	 * operator-managed configuration document. */
	readonly sasl?: SaslPlainCredentials;
	entryId: string;
	readonly room: IrcBridgeRoom;
	readonly seats: Map<Session, ReaderSeat>;
	status: "connecting" | "up" | "backoff";
	stopped: boolean;
	conn: Deno.Conn | null;
	forgetIntent(): Promise<void>;
}

const bridged = new Map<string, BridgedChannel>();

function retireBridge(key: string, held: BridgedChannel, notify: boolean): string {
	bridged.delete(key);
	held.stopped = true;
	for (const session of [...held.seats.keys()]) retireSeat(held, session);
	try {
		held.conn?.close();
	} catch {
		/* tolerant: the connection may already be down */
	}
	const removed = forgetBridgeRoom(held.entryId);
	if (notify && removed !== null) notifyPublicRoom(removed, "closed", null);
	return held.roomName;
}

async function partBridge(key: string, held: BridgedChannel): Promise<string> {
	await held.forgetIntent();
	return retireBridge(key, held, true);
}

/** Part one exact bridge publication through the gateway owner. */
export async function operatorPartBridge(entryId: string): Promise<boolean> {
	for (const [key, held] of bridged) {
		if (held.entryId !== entryId) continue;
		await partBridge(key, held);
		return true;
	}
	return false;
}

export function operatorBridgeMembers(
	entryId: string,
): ReadonlyArray<{ nick: string; session: Session; state: string }> {
	for (const held of bridged.values()) {
		if (held.entryId !== entryId) continue;
		return [...held.seats].map(([session, seat]) => ({
			nick: seat.liveNick,
			session,
			state: seat.enabled ? seat.phase : "rooms-only",
		}));
	}
	return [];
}

/** How many members one bridged channel seats on IRC at once. Past it a
 * member still reads; their posts are refused with the reason. */
export const MAX_READERS_PER_CHANNEL = 32;

function channelKey(network: string, channel: string): string {
	return `${network}/${channel}`.toLowerCase();
}

function retireSeat(held: BridgedChannel, session: Session): void {
	const seat = held.seats.get(session);
	if (seat == null) return;
	held.seats.delete(session);
	noteOperatorChange();
	settleCapabilityCleanup("IRC seat close observer cleanup failed", () => seat.stopClose());
	seat.enabled = false;
	seat.openingAbort?.abort();
	seat.opening = null;
	seat.openingAbort = null;
	const link = seat.link;
	seat.link = null;
	link?.close();
	// The gateway owns the bridge room's membership lifecycle as well as the
	// IRC socket. Retiring only the socket leaves a ghost nick and inbox behind.
	held.room.retire(session);
}

function seatReader(held: BridgedChannel, session: Session, nick: string): void {
	if (held.seats.has(session)) return;
	const ircNick = automaticIrcNick(nick);
	const seat: ReaderSeat = {
		ircNick,
		liveNick: ircNick,
		phase: "rooms",
		identityChosen: false,
		enabled: true,
		link: null,
		opening: null,
		openingAbort: null,
		stopClose: () => {},
	};
	held.seats.set(session, seat);
	noteOperatorChange();
	seat.stopClose = session.onClose(() => retireSeat(held, session));
	// The room subscribed before the gateway could create this projection. Say
	// the explicit Rooms-only baseline now; a full IRC seat list can refuse the
	// following open without a phase change, and the member must still retain
	// the manage action that can retry it later.
	held.room.seatChanged(session);
	// The subscribe note promises presence, so the seat opens now rather than
	// on the first word: sitting in the room is joining the channel. A failed
	// open files trouble; the next post retries it where a person can see.
	void seatLink(held, session).catch((error) => {
		if (error instanceof SeatSuperseded) return;
		noteTrouble(`${held.roomName}: could not seat ${nick} on IRC`, error);
	});
}

function showSeat(
	held: BridgedChannel,
	session: Session,
	seat: ReaderSeat,
	phase: IrcSeatPhase,
	nick: string = seat.liveNick,
): void {
	if (seat.phase === phase && seat.liveNick === nick) return;
	seat.phase = phase;
	seat.liveNick = nick;
	noteOperatorChange();
	held.room.seatChanged(session);
}

function cancelSeatOpening(seat: ReaderSeat): void {
	seat.openingAbort?.abort();
	seat.opening = null;
	seat.openingAbort = null;
}

interface SeatIdentity {
	readonly nick: string;
	readonly sasl?: SaslPlainCredentials;
}

/** Start exactly one bounded IRC connection attempt and install it only if it
 * is still this seat's current attempt. `commitIdentity` keeps replacement
 * credentials provisional until registration and JOIN both succeed. */
function openSeat(
	held: BridgedChannel,
	session: Session,
	seat: ReaderSeat,
	identity: SeatIdentity,
	commitIdentity: boolean,
	suggestAlternative: boolean,
): Promise<ReaderLink> {
	if (!seat.enabled) throw new Error("link your IRC identity before posting to this bridged room");
	let occupied = 0;
	for (const other of held.seats.values()) {
		if (other !== seat && (other.phase === "connecting" || other.phase === "linked")) occupied++;
	}
	if (occupied >= MAX_READERS_PER_CHANNEL) {
		showSeat(held, session, seat, "rooms", identity.nick);
		throw new Error(`this room seats at most ${MAX_READERS_PER_CHANNEL} IRC speakers; the seat list is full`);
	}

	const controller = new AbortController();
	let observedNick = identity.nick;
	let installed: ReaderLink | null = null;
	const renamed = (nick: string) => {
		if (controller.signal.aborted) return;
		observedNick = nick;
		if (installed !== null && seat.link === installed) {
			const refusal = ircNickRenameRefusal(identity.nick, nick);
			if (refusal != null) {
				installed.close(refusal);
				return;
			}
			showSeat(held, session, seat, "linked", nick);
			held.room.noteTo(session, `on IRC you are now <${nick}>`);
		}
	};
	const endpoint = {
		hostname: held.host,
		port: held.port,
		tls: held.tls,
		nick: identity.nick,
		signal: controller.signal,
	};
	const opening = (use: string) => {
		observedNick = use;
		showSeat(held, session, seat, "connecting", use);
		return openReaderConnection({ ...endpoint, nick: use }, use, held.channel, identity.sasl, renamed)
			.catch((error) => {
				if (controller.signal.aborted) throw new SeatSuperseded();
				throw error;
			});
	};
	const attempt: Promise<ReaderLink> = opening(identity.nick)
		.catch((error) => {
			if (!suggestAlternative || !(error instanceof Error) || !error.message.includes("already in use")) {
				throw error;
			}
			throw new Error(`${error.message}. Try "${identity.nick.slice(0, 26)}-r" instead.`);
		})
		.then((link) => {
			installed = link;
			if (held.seats.get(session) !== seat || seat.opening !== attempt || controller.signal.aborted) {
				link.close();
				throw new SeatSuperseded();
			}
			const renamedBeforeInstall = ircNickRenameRefusal(identity.nick, observedNick);
			if (renamedBeforeInstall != null) {
				link.close(renamedBeforeInstall);
				throw new Error(renamedBeforeInstall);
			}
			if (commitIdentity) {
				seat.ircNick = identity.nick;
				seat.sasl = identity.sasl;
				seat.identityChosen = true;
			}
			seat.link = link;
			showSeat(held, session, seat, "linked", observedNick);
			void link.down.then((reason) => {
				if (seat.link !== link) return;
				seat.link = null;
				showSeat(held, session, seat, "failed");
				if (!held.stopped) {
					noteTrouble(`${held.roomName}: a reader's IRC connection ended`, reason);
					held.room.noteTo(session, `your IRC seat ended: ${reason} — your next message reopens it`);
				}
			});
			return link;
		})
		.catch((error) => {
			if (error instanceof SeatSuperseded) throw error;
			if (held.seats.get(session) === seat && seat.opening === attempt) {
				showSeat(held, session, seat, "failed", observedNick);
			}
			throw error;
		})
		.finally(() => {
			if (seat.opening === attempt) {
				seat.opening = null;
				seat.openingAbort = null;
			}
		});
	seat.opening = attempt;
	seat.openingAbort = controller;
	return attempt;
}

/** The seat's live link, opened on subscribe and retried by a later post. */
async function seatLink(held: BridgedChannel, session: Session): Promise<ReaderLink> {
	const seat = held.seats.get(session);
	if (seat == null) throw new Error("post needs a live IRC bridge membership");
	if (!seat.enabled) throw new Error("link your IRC identity before posting to this bridged room");
	if (seat.link !== null) return seat.link;
	if (seat.opening === null) {
		return await openSeat(
			held,
			session,
			seat,
			{ nick: seat.ircNick, sasl: seat.sasl },
			false,
			!seat.identityChosen,
		);
	}
	return await seat.opening;
}

/** Replace a seat's IRC identity transactionally. The old connection must be
 * closed before a same-nick login can register, but its configuration stays
 * authoritative until the candidate joins; a refusal then reopens the old
 * seat rather than making rejected credentials the next post's retry. */
async function replaceSeatIdentity(
	held: BridgedChannel,
	session: Session,
	seat: ReaderSeat,
	identity: SeatIdentity,
): Promise<ReaderLink> {
	const old: SeatIdentity = seat.sasl == null ? { nick: seat.ircNick } : { nick: seat.ircNick, sasl: seat.sasl };
	const oldPhase = seat.phase;
	const oldLiveNick = seat.liveNick;
	const oldEnabled = seat.enabled;
	const oldChosen = seat.identityChosen;
	const hadLink = seat.link !== null;

	cancelSeatOpening(seat);
	const prior = seat.link;
	seat.link = null;
	prior?.close();
	seat.enabled = true;
	noteOperatorChange();
	try {
		return await openSeat(held, session, seat, identity, true, false);
	} catch (error) {
		if (error instanceof SeatSuperseded) throw error;
		if (held.seats.get(session) !== seat || !seat.enabled) throw error;

		seat.ircNick = old.nick;
		seat.sasl = old.sasl;
		seat.enabled = oldEnabled;
		noteOperatorChange();
		seat.identityChosen = oldChosen;
		if (oldEnabled && (hadLink || oldPhase === "connecting")) {
			try {
				await openSeat(held, session, seat, old, false, !oldChosen);
			} catch (rollbackError) {
				if (!(rollbackError instanceof SeatSuperseded)) {
					noteTrouble(`${held.roomName}: could not restore the prior IRC identity`, rollbackError);
				}
			}
		} else {
			showSeat(held, session, seat, oldPhase, oldLiveNick);
		}
		throw error;
	}
}

function disconnectSeat(held: BridgedChannel, session: Session, seat: ReaderSeat): void {
	cancelSeatOpening(seat);
	const link = seat.link;
	seat.link = null;
	link?.close();
	seat.enabled = false;
	noteOperatorChange();
	seat.sasl = undefined;
	showSeat(held, session, seat, "rooms", seat.ircNick);
}

/** The bridge room with reader citizenship on top: subscribing seats the
 * member on IRC, a post speaks as them there before the room echoes it, and
 * leaving takes their nick off the channel. */
function readerAwareRoom(held: BridgedChannel): { roomBehavior(): Behavior } {
	return {
		roomBehavior: (): Behavior => {
			const inner = held.room.roomBehavior();
			return (verb: string, args: Argument[]): ReturnType<Behavior> => {
				const session = currentSession();
				if (session == null) throw new Error("an IRC gateway room is reachable only during a session turn");
				if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
					throwAfterReleasingCapabilities(
						session,
						args,
						new Error(`IRC bridge room ${verb} does not take capability arguments`),
					);
				}
				// Part revokes the dynamic bridge, including room capabilities that
				// were handed out before it left discovery. Letting one subscribe
				// again would recreate a seat behind the operator's completed act.
				if (held.stopped) {
					if (verb === LEAVE) return inner(verb, args);
					throw new Error("this IRC bridge has been parted");
				}
				if (verb === SUBSCRIBE) {
					const answer = inner(verb, args);
					const nick = typeof args[0] === "string" ? args[0] : "";
					seatReader(held, session, nick);
					return answer;
				}
				if (verb === POST) {
					const post = held.room.preparePost(session, args);
					// IRC first, the room after: a line the channel never carried
					// must not stand in the room claiming it did. A `/me` is the
					// same line IRC spells as a CTCP ACTION.
					return seatLink(held, session)
						.then((link) =>
							post.text.startsWith("/me ") ? link.action(post.text.slice(4)) : link.say(post.text)
						)
						.then(() => held.room.commitPost(post)) as ReturnType<Behavior>;
				}
				if (verb === AWAY) {
					// The room's word first; the channel hears it as a courtesy,
					// through a live seat only — away is not worth opening a
					// connection for, and never worth refusing over.
					const answer = inner(verb, args);
					const reason = typeof args[0] === "string" ? args[0] : "";
					const seat = held.seats.get(session);
					if (seat != null && seat.link !== null) {
						void seat.link.away(reason).catch(() => {
							// tolerant: a dropped seat already files its own trouble
						});
					}
					return answer;
				}
				if (verb === IRC_IDENTITY) {
					const seat = held.seats.get(session);
					if (seat == null) throw new Error("choose an IRC identity from a room you are seated in");
					if (
						args.length !== 3 || typeof args[0] !== "string" || typeof args[1] !== "string" ||
						typeof args[2] !== "string"
					) throw new Error("ircIdentity needs a nick, account, and password");
					const [nick, account, password] = args;
					validateIrcNick(nick);
					let identity: SeatIdentity = { nick };
					if (account !== "" || password !== "") {
						if (!held.tls) {
							throw new Error(
								"this bridge runs without TLS; a registered account needs an encrypted path",
							);
						}
						const sasl = { account, password };
						validateSaslPlain(sasl);
						identity = { nick, sasl };
					}
					return replaceSeatIdentity(held, session, seat, identity).then(() =>
						account === ""
							? `you now speak on IRC as <${nick}>`
							: account === nick
							? `you now speak on IRC as <${nick}>, logged in`
							: `you now speak on IRC as <${nick}>, logged into ${account}`
					) as ReturnType<Behavior>;
				}
				if (verb === IRC_DISCONNECT) {
					if (args.length !== 0) throw new Error("ircDisconnect takes no arguments");
					const seat = held.seats.get(session);
					if (seat == null) throw new Error("disconnect IRC from a room you are seated in");
					disconnectSeat(held, session, seat);
					return "you now appear in this room only";
				}
				if (verb === LEAVE) {
					const answer = inner(verb, args);
					retireSeat(held, session);
					return answer;
				}
				return inner(verb, args);
			};
		},
	};
}

export async function joinIrcBridge(
	intent: IrcBridgeIntent,
	state: RoomServerOperationsState | null,
	remember: boolean,
): Promise<string> {
	const { network, channel, host, port, tls, nick, sasl } = intent;
	const key = channelKey(network, channel);
	if (bridged.has(key)) throw new Error(`${network}/${channel} is already bridged`);
	const relay = new IrcChannelRelay(channel, nick);
	const room = new IrcBridgeRoom(network, channel, relay, {
		ownOutbound: true,
		seatNick: (ircNick) => {
			const folded = ircFold(ircNick);
			for (const seat of held.seats.values()) {
				if (
					(seat.phase === "connecting" || seat.phase === "linked") &&
					(ircFold(seat.liveNick) === folded || ircFold(seat.ircNick) === folded)
				) return true;
			}
			return false;
		},
		seatView: (session) => {
			const seat = held.seats.get(session);
			return seat == null ? null : { phase: seat.phase, nick: seat.liveNick };
		},
		onTrouble: noteTrouble,
		subscribeNote: () =>
			`this room bridges to ${channel}; your member row shows whether your IRC identity is connected`,
	});
	const held: BridgedChannel = {
		network,
		channel,
		roomName: room.roomName,
		host,
		port,
		tls,
		nick,
		sasl,
		entryId: "",
		room,
		seats: new Map(),
		status: "connecting",
		stopped: false,
		conn: null,
		forgetIntent: () => state?.forgetIrcBridge(network, channel) ?? Promise.resolve(),
	};
	const entry = registerBridgeRoom(room.roomName, `${host}:${port}`, readerAwareRoom(held));
	held.entryId = entry.id;
	bridged.set(key, held);
	try {
		if (remember) await state?.rememberIrcBridge(intent);
	} catch (error) {
		retireBridge(key, held, false);
		throw error;
	}
	notifyPublicRoom(entry, "opened", null);
	void driveIrcBridge(held, relay);
	return room.roomName;
}

export async function restoreIrcBridges(state: RoomServerOperationsState): Promise<void> {
	for (const intent of state.ircBridges()) {
		try {
			await joinIrcBridge(intent, state, false);
		} catch (error) {
			noteTrouble(`could not restore the ${intent.network}/${intent.channel} IRC bridge`, error);
		}
	}
}

export function partIrcBridge(
	network: string,
	channel: string,
	state: RoomServerOperationsState | null,
): Promise<string> {
	const key = channelKey(network, channel);
	const held = bridged.get(key);
	if (held != null) return partBridge(key, held);
	if (state == null || !state.ircBridges().some((intent) => channelKey(intent.network, intent.channel) === key)) {
		return Promise.reject(new Error(`${network}/${channel} is not bridged`));
	}
	return state.forgetIrcBridge(network, channel).then(() => `${network}/${channel}`);
}

export function ircBridgeSnapshot(): Argument[] {
	return [...bridged.values()].map((held) => [
		held.network,
		held.channel,
		held.roomName,
		held.status,
		`${held.host}:${held.port}`,
	]);
}

/** Retire live bridge resources during process shutdown without changing the
 * durable intent that the next process must replay. */
export function closeIrcBridges(): void {
	for (const [key, held] of [...bridged]) retireBridge(key, held, false);
}
