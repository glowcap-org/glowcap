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
// reader connection is not respun in the dark; the seat clears, and the next
// post opens a fresh one — a retry a person can see. SASL custody is still
// ahead, so registered-only networks refuse these nicks and the refusal
// lands in the poster's own bubble.

import type { Argument, Behavior, Session } from "@pancake/runtime";
import { IrcBridgeRoom } from "../irc/bridge.ts";
import { connectIrc, runIrcSession } from "../irc/client.ts";
import { IrcChannelRelay } from "../irc/outbound.ts";
import { openReaderConnection, type ReaderLink } from "../irc/reader_connection.ts";
import { ircFold } from "../irc/protocol.ts";
import { type SaslPlainCredentials, validateIrcNick, validateSaslPlain } from "../irc/registration.ts";
import { projectedNick } from "../irc/front/render.ts";
import { IRC_ACCOUNT, JOIN_IRC, PART_IRC, SNAPSHOT } from "../lib/protocol.ts";
import { forgetBridgeRoom, registerBridgeRoom } from "./registry.ts";
import { notifyPublicRoom } from "./discovery.ts";
import { noteTrouble } from "./journal.ts";

interface ReaderSeat {
	readonly ircNick: string;
	/** The nick this seat actually wears on the network right now: the
	 * chosen one until the wire says otherwise — a held-name retry suffixes
	 * it, and services can force-rename it after joining. The feed's echo
	 * suppression and the member's own room both follow this, not the wish. */
	liveNick: string;
	/** The member's own registered account, handed over once through the room
	 * and held only here, beside the connections it authenticates: never
	 * persisted, never answered back, gone with the seat. */
	sasl?: SaslPlainCredentials;
	link: ReaderLink | null;
	opening: Promise<ReaderLink> | null;
}

interface BridgedChannel {
	readonly network: string;
	readonly channel: string;
	readonly roomName: string;
	readonly host: string;
	readonly port: number;
	readonly tls: boolean;
	readonly nick: string;
	/** The shared feed's registered account, held in memory beside the
	 * connection it authenticates and nowhere else: never in a snapshot row,
	 * never in the journal, gone with the bridge. */
	readonly sasl?: SaslPlainCredentials;
	entryId: string;
	readonly room: IrcBridgeRoom;
	readonly readers: Map<Session, ReaderSeat>;
	status: "connecting" | "up" | "backoff";
	stopped: boolean;
	conn: Deno.Conn | null;
}

const bridged = new Map<string, BridgedChannel>();

/** How many members one bridged channel seats on IRC at once. Past it a
 * member still reads; their posts are refused with the reason. */
export const MAX_READERS_PER_CHANNEL = 32;

function channelKey(network: string, channel: string): string {
	return `${network}/${channel}`.toLowerCase();
}

/** The member's name as IRC will accept it: their own nick when it already
 * fits IRC's alphabet, the deterministic projection the IRC front already
 * uses otherwise. */
function ircNickFor(nick: string): string {
	try {
		validateIrcNick(nick);
		return nick;
	} catch {
		return projectedNick(nick);
	}
}

function retireSeat(held: BridgedChannel, session: Session): void {
	const seat = held.readers.get(session);
	if (seat === undefined) return;
	held.readers.delete(session);
	seat.link?.close();
}

function seatReader(held: BridgedChannel, session: Session, nick: string): void {
	if (held.readers.has(session)) return;
	if (held.readers.size >= MAX_READERS_PER_CHANNEL) {
		noteTrouble(
			`${held.roomName} is at its ${MAX_READERS_PER_CHANNEL}-reader IRC seat bound`,
			new Error(`${nick} reads without an IRC seat`),
		);
		return;
	}
	const ircNick = ircNickFor(nick);
	held.readers.set(session, { ircNick, liveNick: ircNick, link: null, opening: null });
	session.onClose(() => retireSeat(held, session));
	// The subscribe note promises presence, so the seat opens now rather than
	// on the first word: sitting in the room is joining the channel. A failed
	// open files trouble; the next post retries it where a person can see.
	void seatLink(held, session).catch((error) => {
		noteTrouble(`${held.roomName}: could not seat ${nick} on IRC`, error);
	});
}

/** The seat's live link, opened on first need. One suffixed retry when the
 * network holds the name; past that the reason is the poster's answer. */
async function seatLink(held: BridgedChannel, session: Session): Promise<ReaderLink> {
	const seat = held.readers.get(session);
	if (seat === undefined) {
		throw new Error(`this room seats at most ${MAX_READERS_PER_CHANNEL} IRC speakers; the seat list is full`);
	}
	if (seat.link !== null) return seat.link;
	if (seat.opening === null) {
		const endpoint = { hostname: held.host, port: held.port, tls: held.tls, nick: seat.ircNick };
		// A rename is seat news the member should hear where they speak, not
		// only a bookkeeping update: the suppression map and their outward
		// name both follow it.
		const renamed = (nick: string) => {
			seat.liveNick = nick;
			held.room.noteTo(session, `on IRC you are now <${nick}>`);
		};
		const opening = (use: string) => {
			seat.liveNick = use;
			return openReaderConnection({ ...endpoint, nick: use }, use, held.channel, seat.sasl, renamed);
		};
		seat.opening = opening(seat.ircNick)
			.catch((error) => {
				if (!(error instanceof Error) || !error.message.includes("already in use")) throw error;
				return opening(`${seat.ircNick.slice(0, 26)}-r`);
			})
			.then((link) => {
				seat.link = link;
				void link.down.then((reason) => {
					if (seat.link === link) {
						seat.link = null;
						if (!held.stopped) {
							noteTrouble(`${held.roomName}: a reader's IRC connection ended`, reason);
							held.room.noteTo(
								session,
								`your IRC seat ended: ${reason} — your next message reopens it`,
							);
						}
					}
				});
				return link;
			})
			.finally(() => {
				seat.opening = null;
			});
	}
	return await seat.opening;
}

/** The bridge room with reader citizenship on top: subscribing seats the
 * member on IRC, a post speaks as them there before the room echoes it, and
 * leaving takes their nick off the channel. */
function readerAwareRoom(held: BridgedChannel): { roomBehavior(session: Session): Behavior } {
	return {
		roomBehavior: (session: Session): Behavior => {
			const inner = held.room.roomBehavior(session);
			return (verb: string, args: Argument[]): ReturnType<Behavior> => {
				if (verb === "subscribe") {
					const answer = inner(verb, args);
					const nick = typeof args[0] === "string" ? args[0] : "";
					seatReader(held, session, nick);
					return answer;
				}
				if (verb === "post") {
					const said = typeof args[0] === "string" ? args[0] : "";
					// IRC first, the room after: a line the channel never carried
					// must not stand in the room claiming it did. A `/me` is the
					// same line IRC spells as a CTCP ACTION.
					return seatLink(held, session)
						.then((link) => said.startsWith("/me ") ? link.action(said.slice(4)) : link.say(said))
						.then(() => inner(verb, args))
						.then(() => null) as ReturnType<Behavior>;
				}
				if (verb === "away") {
					// The room's word first; the channel hears it as a courtesy,
					// through a live seat only — away is not worth opening a
					// connection for, and never worth refusing over.
					const answer = inner(verb, args);
					const reason = typeof args[0] === "string" ? args[0] : "";
					const seat = held.readers.get(session);
					if (seat?.link !== null && seat !== undefined) {
						void seat.link.away(reason).catch(() => {
							// tolerant: a dropped seat already files its own trouble
						});
					}
					return answer;
				}
				if (verb === IRC_ACCOUNT) {
					const seat = held.readers.get(session);
					if (seat === undefined) throw new Error("hand an account to a room you are seated in");
					if (!held.tls) {
						throw new Error("this bridge runs without TLS; a registered account needs an encrypted path");
					}
					const account = typeof args[0] === "string" ? args[0] : "";
					const password = typeof args[1] === "string" ? args[1] : "";
					const sasl = { account, password };
					validateSaslPlain(sasl);
					seat.sasl = sasl;
					// The current connection is anonymous; the next post opens one
					// that is theirs.
					seat.link?.close();
					seat.link = null;
					return `from your next message you speak on IRC as ${account} (nick ${seat.ircNick})`;
				}
				if (verb === "leave") {
					retireSeat(held, session);
					return inner(verb, args);
				}
				return inner(verb, args);
			};
		},
	};
}

/** The reconnect loop the standalone bridge runs, per bridged channel: fast
 * after a stretch of service, backed off toward 30s while the network
 * refuses, and over the moment the operator parts the channel. */
async function drive(held: BridgedChannel, relay: IrcChannelRelay): Promise<void> {
	let delay = 1_000;
	while (!held.stopped) {
		let registeredAt: number | null = null;
		try {
			held.status = "connecting";
			const conn = await connectIrc({
				hostname: held.host,
				port: held.port,
				tls: held.tls,
				nick: held.nick,
			});
			held.conn = conn;
			if (held.stopped) {
				conn.close();
				return;
			}
			await runIrcSession(conn, held.room, relay, {
				nick: held.nick,
				sasl: held.sasl,
				onRegistered: () => {
					registeredAt = performance.now();
					held.status = "up";
				},
			});
		} catch (error) {
			if (!held.stopped) noteTrouble(`the ${held.roomName} bridge lost its IRC connection`, error);
		} finally {
			held.conn = null;
			held.room.disconnected();
		}
		if (held.stopped) return;
		held.status = "backoff";
		if (registeredAt !== null && performance.now() - registeredAt >= 30_000) delay = 1_000;
		await new Promise((resolve) => setTimeout(resolve, delay));
		delay = Math.min(delay * 2, 30_000);
	}
}

/** The separately published authority to bridge IRC channels into this
 * directory. The swiss is the capability, the shape every operator
 * capability here shares. */
export function ircGatewayBehavior(): Behavior {
	return (verb: string, args: Argument[]): Argument => {
		if (verb === JOIN_IRC) {
			const network = typeof args[0] === "string" ? args[0] : "";
			const channel = typeof args[1] === "string" ? args[1] : "";
			const host = typeof args[2] === "string" ? args[2] : "";
			const port = typeof args[3] === "bigint" ? Number(args[3]) : typeof args[3] === "number" ? args[3] : 6697;
			const tls = args[4] !== false;
			const nick = typeof args[5] === "string" && args[5] !== "" ? args[5] : "pancake-rooms";
			const saslAccount = typeof args[6] === "string" ? args[6] : "";
			const saslPassword = typeof args[7] === "string" ? args[7] : "";
			if (host === "") throw new Error("joinIrc needs the IRC server's host");
			let sasl: SaslPlainCredentials | undefined;
			if (saslAccount !== "" || saslPassword !== "") {
				// A password on a cleartext socket is a credential handed to the
				// network path; refusing is the only honest answer.
				if (!tls) throw new Error("a registered account needs TLS; join with TLS on");
				sasl = { account: saslAccount, password: saslPassword };
				validateSaslPlain(sasl);
			}
			if (!Number.isInteger(port) || port <= 0 || port > 65535) {
				throw new Error("joinIrc needs a real port");
			}
			const key = channelKey(network, channel);
			if (bridged.has(key)) throw new Error(`${network}/${channel} is already bridged`);
			// The bridge room validates network and channel shape. The shared
			// relay stays read-only: members speak on IRC through their own
			// reader connections, never through the feed's nick.
			const relay = new IrcChannelRelay(channel, nick);
			const held: BridgedChannel = {
				network,
				channel,
				roomName: "",
				host,
				port,
				tls,
				nick,
				sasl,
				entryId: "",
				room: null as unknown as IrcBridgeRoom,
				readers: new Map(),
				status: "connecting",
				stopped: false,
				conn: null,
			};
			const room = new IrcBridgeRoom(network, channel, relay, {
				ownOutbound: true,
				seatNick: (ircNick) => {
					// Both names a seat has worn: the live one, and the chosen one
					// whose channel echo can still be in flight across a suffixed
					// retry or a services rename.
					const folded = ircFold(ircNick);
					return [...held.readers.values()].some((seat) =>
						ircFold(seat.liveNick) === folded || ircFold(seat.ircNick) === folded
					);
				},
				subscribeNote: (member) =>
					`you appear in ${channel} as <${
						ircNickFor(member)
					}> while you are here; lines you post go to IRC as you`,
			});
			(held as { room: IrcBridgeRoom }).room = room;
			(held as { roomName: string }).roomName = room.roomName;
			const entry = registerBridgeRoom(room.roomName, `${host}:${port}`, readerAwareRoom(held));
			held.entryId = entry.id;
			bridged.set(key, held);
			notifyPublicRoom(entry, "opened", null);
			void drive(held, relay);
			return room.roomName;
		}
		if (verb === PART_IRC) {
			const network = typeof args[0] === "string" ? args[0] : "";
			const channel = typeof args[1] === "string" ? args[1] : "";
			const held = bridged.get(channelKey(network, channel));
			if (held === undefined) throw new Error(`${network}/${channel} is not bridged`);
			bridged.delete(channelKey(network, channel));
			held.stopped = true;
			for (const session of [...held.readers.keys()]) retireSeat(held, session);
			try {
				held.conn?.close();
			} catch {
				/* tolerant: the connection may already be down */
			}
			const removed = forgetBridgeRoom(held.entryId);
			if (removed !== null) notifyPublicRoom(removed, "closed", null);
			return held.roomName;
		}
		if (verb === SNAPSHOT) {
			const rows: Argument[] = [];
			for (const held of bridged.values()) {
				rows.push([held.network, held.channel, held.roomName, held.status, `${held.host}:${held.port}`]);
			}
			return rows;
		}
		throw new Error(`the IRC gateway has no method ${verb}`);
	};
}
