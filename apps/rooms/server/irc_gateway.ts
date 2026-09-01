// Operator-owned IRC networks and the channel bridges beneath them.
//
// The standalone bridge (`irc/bridge/main.ts`) serves one argv-chosen channel as its
// own directory. This is the same machinery made dynamic and folded into the
// main directory. Holding the gateway capability lets an operator retain a
// network configuration with no channels, then create independent channel
// leases beneath it. Configured channels share one demand-owned feed socket;
// removing the last channel retires that socket without deleting the network
// capability.
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

import { type Argument, type Session } from "@pancake/runtime";
import { IrcBridgeRoom } from "../irc/bridge/room.ts";
import { IrcChannelRelay } from "../irc/bridge/outbound.ts";
import {
	type IrcChannelMembership,
	type IrcMemberConnection,
	openIrcMemberConnection,
} from "../irc/bridge/reader_connection.ts";
import { ircFold } from "../irc/protocol.ts";
import { automaticIrcNick, ircNickRenameRefusal } from "../irc/bridge/identity.ts";
import { ircIdentityForm } from "../irc/bridge/identity_form.ts";
import type { IrcNetworkChoice } from "../lib/irc_gateway_client.ts";
import type { SeatPhase } from "../lib/protocol_irc.ts";
import type { RoomServerContext } from "./context.ts";
import { notifyPublicRoom } from "./discovery.ts";
import type { BridgedChannel, IrcNetworkIdentity, ReaderSeat } from "./irc_gateway/tables.ts";
import type { RoomServerOperationsState } from "./operations_state.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import {
	type IrcSeatIdentity,
	memberBridgeBehavior,
	type MemberBridgeOperations,
} from "./irc_gateway/member_behavior.ts";
import { ircNetworkKey, type OperatorIrcNetwork } from "./irc_gateway/networks.ts";
import type { IrcBridgeAuthorities } from "./irc_gateway/authority.ts";
import { projectIrcBridgeSnapshot, projectIrcGatewaySnapshot } from "./irc_gateway/snapshot.ts";

class SeatSuperseded extends Error {}

function networkKey(network: string): string {
	return ircNetworkKey(network);
}

function retireBridge(ctx: RoomServerContext, key: string, held: BridgedChannel, notify: boolean): string {
	ctx.irc.bridged.delete(key);
	held.stopped = true;
	for (const invitation of held.invitations) {
		invitation.active = false;
		const ref = invitation.ref;
		if (ref !== null) {
			settleCapabilityCleanup(
				"retired IRC bridge invitation release failed",
				() => invitation.session.release(ref),
			);
		}
	}
	held.invitations.clear();
	for (const session of [...held.seats.keys()]) retireSeat(held, session, "This IRC bridge was parted.");
	ctx.irc.networks.detach(held.network, held);
	held.authorities?.deactivate(held.room.publicationId);
	const removed = ctx.live.forgetBridgeRoom(held.entryId);
	if (notify && removed !== null) notifyPublicRoom(ctx, removed, "closed", null);
	return held.roomName;
}

async function partBridge(ctx: RoomServerContext, key: string, held: BridgedChannel): Promise<string> {
	await held.forgetIntent();
	return retireBridge(ctx, key, held, true);
}

/** Part one exact bridge publication through the gateway owner. */
export async function operatorPartBridge(ctx: RoomServerContext, entryId: string): Promise<boolean> {
	for (const [key, held] of ctx.irc.bridged) {
		if (held.entryId !== entryId) continue;
		return await ctx.irc.networks.mutate(held.network, async () => {
			if (ctx.irc.bridged.get(key) !== held) return false;
			await partBridge(ctx, key, held);
			return true;
		});
	}
	return false;
}

export function operatorBridgeMembers(
	ctx: RoomServerContext,
	entryId: string,
): ReadonlyArray<{ nick: string; session: Session; state: string }> {
	for (const held of ctx.irc.bridged.values()) {
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
const MAX_READERS_PER_CHANNEL = 32;

function channelKey(network: string, channel: string): string {
	return `${networkKey(network)}\u0000${ircFold(channel)}`;
}

function retireSeat(held: BridgedChannel, session: Session, ended?: string): void {
	const seat = held.seats.get(session);
	if (seat == null) return;
	held.seats.delete(session);
	seat.identity.seats.delete(held);
	seat.membership?.part();
	seat.membership = null;
	held.tables.operator.noteChange();
	// The gateway owns the bridge room's membership lifecycle as well as IRC.
	// Retiring only the channel lease leaves a ghost Rooms nick and inbox.
	held.room.retire(session, ended);
	if (seat.identity.seats.size === 0) forgetIdentity(seat.identity);
}

function seatReader(held: BridgedChannel, session: Session, nick: string): void {
	if (held.seats.has(session)) return;
	let byNetwork = held.tables.identities.get(session);
	if (byNetwork == null) {
		byNetwork = new Map();
		held.tables.identities.set(session, byNetwork);
	}
	const key = held.network.key;
	let identity = byNetwork.get(key);
	if (identity == null) {
		const ircNick = automaticIrcNick(nick);
		identity = {
			tables: held.tables,
			key,
			session,
			ircNick,
			liveNick: ircNick,
			identityChosen: false,
			enabled: true,
			connection: null,
			opening: null,
			openingAbort: null,
			seats: new Map(),
			stopClose: () => {},
		};
		byNetwork.set(key, identity);
		identity.stopClose = session.onClose(() => {
			for (const channel of [...identity!.seats.keys()]) retireSeat(channel, session);
		});
	}
	const seat: ReaderSeat = {
		identity,
		liveNick: identity.liveNick,
		phase: "rooms",
		enabled: identity.enabled,
		membership: null,
	};
	held.seats.set(session, seat);
	identity.seats.set(held, seat);
	held.tables.operator.noteChange();
	// The room subscribed before the gateway could create this projection. Say
	// the explicit Rooms-only baseline now; a full IRC seat list can refuse the
	// following open without a phase change, and the member must still retain
	// the manage action that can retry it later.
	held.room.seatChanged(session);
	// The subscribe note promises presence, so the seat opens now rather than
	// on the first word: sitting in the room is joining the channel. A failed
	// open files trouble; the next post retries it where a person can see.
	if (!identity.enabled) return;
	void seatMembership(held, session).catch((error) => {
		if (error instanceof SeatSuperseded) return;
		held.tables.journal.note(`${held.roomName}: could not seat ${nick} on IRC`, error);
	});
}

function showSeat(
	held: BridgedChannel,
	session: Session,
	seat: ReaderSeat,
	phase: SeatPhase,
	nick: string = seat.liveNick,
): void {
	if (seat.phase === phase && seat.liveNick === nick) return;
	seat.phase = phase;
	seat.liveNick = nick;
	held.tables.operator.noteChange();
	held.room.seatChanged(session);
}

/** Reflect one network identity across each channel membership it currently owns. */
function showIdentity(identity: IrcNetworkIdentity, phase: SeatPhase, nick = identity.liveNick): void {
	identity.liveNick = nick;
	for (const [held, seat] of identity.seats) showSeat(held, identity.session, seat, phase, nick);
}

function cancelIdentityOpening(identity: IrcNetworkIdentity): void {
	identity.openingAbort?.abort();
	identity.opening = null;
	identity.openingAbort = null;
}

function closeIdentityConnection(identity: IrcNetworkIdentity): void {
	identity.connection?.close();
	identity.connection = null;
}

function forgetIdentity(identity: IrcNetworkIdentity): void {
	const byNetwork = identity.tables.identities.get(identity.session);
	if (byNetwork?.get(identity.key) !== identity) return;
	byNetwork.delete(identity.key);
	if (byNetwork.size === 0) identity.tables.identities.delete(identity.session);
	settleCapabilityCleanup("IRC identity close observer cleanup failed", () => identity.stopClose());
	cancelIdentityOpening(identity);
	closeIdentityConnection(identity);
}

function endpointFor(identity: IrcNetworkIdentity, signal: AbortSignal) {
	const held = identity.seats.keys().next().value as BridgedChannel | undefined;
	if (held == null) throw new SeatSuperseded();
	const { host, port, tls } = held.network.choice;
	return { hostname: host, port, tls, nick: identity.ircNick, signal };
}

function openIdentity(identity: IrcNetworkIdentity): Promise<IrcMemberConnection> {
	if (!identity.enabled) throw new Error("link your IRC identity before posting to this bridged room");
	if (identity.connection != null) return Promise.resolve(identity.connection);
	if (identity.opening != null) return identity.opening;
	const controller = new AbortController();
	let installed: IrcMemberConnection | null = null;
	let observedNick = identity.ircNick;
	showIdentity(identity, "connecting", observedNick);
	const attempt = openIrcMemberConnection(
		endpointFor(identity, controller.signal),
		identity.ircNick,
		identity.sasl,
		(nick) => {
			observedNick = nick;
			if (installed == null || identity.connection !== installed) return;
			const refusal = ircNickRenameRefusal(identity.ircNick, nick);
			if (refusal != null) installed.close(refusal);
			else {
				showIdentity(identity, "linked", nick);
				for (const held of identity.seats.keys()) {
					held.room.noteTo(identity.session, `on IRC you are now <${nick}>`);
				}
			}
		},
	).then((connection) => {
		installed = connection;
		if (identity.opening !== attempt || controller.signal.aborted || identity.seats.size === 0) {
			connection.close();
			throw new SeatSuperseded();
		}
		const refusal = ircNickRenameRefusal(identity.ircNick, observedNick);
		if (refusal != null) {
			connection.close(refusal);
			throw new Error(refusal);
		}
		identity.connection = connection;
		identity.liveNick = observedNick;
		void connection.down.then(() => {
			if (identity.connection === connection) identity.connection = null;
		});
		return connection;
	}).catch((error) => {
		if (controller.signal.aborted) throw new SeatSuperseded();
		if (!(error instanceof SeatSuperseded) && identity.opening === attempt) {
			showIdentity(identity, "failed", observedNick);
		}
		throw error;
	}).finally(() => {
		if (identity.opening === attempt) {
			identity.opening = null;
			identity.openingAbort = null;
		}
	});
	identity.opening = attempt;
	identity.openingAbort = controller;
	return attempt;
}

function attachMembership(
	identity: IrcNetworkIdentity,
	held: BridgedChannel,
	seat: ReaderSeat,
	membership: IrcChannelMembership,
): void {
	if (identity.seats.get(held) !== seat) {
		membership.part();
		return;
	}
	seat.membership = membership;
	showSeat(held, identity.session, seat, "linked", identity.liveNick);
	void membership.down.then((reason) => {
		if (seat.membership !== membership) return;
		seat.membership = null;
		showSeat(held, identity.session, seat, "failed", identity.liveNick);
		if (!held.stopped) {
			held.tables.journal.note(`${held.roomName}: an IRC channel membership ended`, reason);
			held.room.noteTo(identity.session, `your IRC membership ended: ${reason} — your next message rejoins`);
		}
	});
}

async function seatMembership(held: BridgedChannel, session: Session): Promise<IrcChannelMembership> {
	const seat = held.seats.get(session);
	if (seat == null) throw new Error("post needs a live IRC bridge membership");
	if (!seat.enabled || !seat.identity.enabled) {
		throw new Error("link your IRC identity before posting to this bridged room");
	}
	if (seat.membership != null) return seat.membership;
	let occupied = 0;
	for (const other of held.seats.values()) {
		if (other !== seat && (other.phase === "connecting" || other.phase === "linked")) occupied++;
	}
	if (occupied >= MAX_READERS_PER_CHANNEL) {
		showSeat(held, session, seat, "rooms", seat.identity.ircNick);
		throw new Error(`this room seats at most ${MAX_READERS_PER_CHANNEL} IRC speakers; the seat list is full`);
	}
	const connection = await openIdentity(seat.identity);
	if (seat.membership != null) return seat.membership;
	const membership = await connection.join(held.channel);
	attachMembership(seat.identity, held, seat, membership);
	return membership;
}

async function joinIdentityChannels(identity: IrcNetworkIdentity): Promise<void> {
	for (const held of identity.seats.keys()) await seatMembership(held, identity.session);
}

async function replaceNetworkIdentity(identity: IrcNetworkIdentity, replacement: IrcSeatIdentity): Promise<void> {
	const prior: IrcSeatIdentity = identity.sasl == null
		? { nick: identity.ircNick }
		: { nick: identity.ircNick, sasl: identity.sasl };
	const priorChosen = identity.identityChosen;
	const priorEnabled = identity.enabled;
	cancelIdentityOpening(identity);
	for (const seat of identity.seats.values()) seat.membership = null;
	closeIdentityConnection(identity);
	identity.ircNick = replacement.nick;
	identity.sasl = replacement.sasl;
	identity.enabled = true;
	identity.identityChosen = true;
	for (const seat of identity.seats.values()) seat.enabled = true;
	identity.tables.operator.noteChange();
	try {
		await openIdentity(identity);
		await joinIdentityChannels(identity);
	} catch (error) {
		if (error instanceof SeatSuperseded) throw error;
		cancelIdentityOpening(identity);
		for (const seat of identity.seats.values()) seat.membership = null;
		closeIdentityConnection(identity);
		identity.ircNick = prior.nick;
		identity.sasl = prior.sasl;
		identity.enabled = priorEnabled;
		identity.identityChosen = priorChosen;
		for (const seat of identity.seats.values()) seat.enabled = priorEnabled;
		if (priorEnabled && identity.seats.size !== 0) {
			try {
				await openIdentity(identity);
				await joinIdentityChannels(identity);
			} catch (rollbackError) {
				if (!(rollbackError instanceof SeatSuperseded)) {
					identity.tables.journal.note("could not restore the prior IRC network identity", rollbackError);
				}
			}
		} else showIdentity(identity, "rooms", prior.nick);
		throw error;
	}
}

function disconnectNetworkIdentity(identity: IrcNetworkIdentity): void {
	cancelIdentityOpening(identity);
	for (const seat of identity.seats.values()) {
		seat.enabled = false;
		seat.membership = null;
	}
	closeIdentityConnection(identity);
	identity.enabled = false;
	identity.sasl = undefined;
	showIdentity(identity, "rooms", identity.ircNick);
	identity.tables.operator.noteChange();
}

const memberOperations: MemberBridgeOperations<BridgedChannel, ReaderSeat> = {
	network: (bridge) => ({ name: bridge.network.choice.network, tls: bridge.network.choice.tls }),
	seat: (bridge, session, nick) => seatReader(bridge, session, nick),
	membership: (bridge, session) => seatMembership(bridge, session),
	seatFor: (bridge, session) => bridge.seats.get(session) ?? null,
	replaceIdentity: (seat, identity) => replaceNetworkIdentity(seat.identity, identity),
	identityForm: (bridge, seat) =>
		ircIdentityForm(
			{ network: bridge.network.choice.network, phase: seat.phase, nick: seat.liveNick },
			bridge.room.origin,
			bridge.network.choice.tls,
		),
	disconnectIdentity: (seat) => disconnectNetworkIdentity(seat.identity),
	retire: (bridge, session) => retireSeat(bridge, session),
};

/** Retain one operator-owned IRC network. Its transport remains dormant until
 * the first channel lease needs a shared feed. */
export async function openIrcNetwork(
	ctx: RoomServerContext,
	choice: IrcNetworkChoice,
	state: RoomServerOperationsState | null,
	remember: boolean,
): Promise<void> {
	await ctx.irc.networks.open(
		choice,
		() => remember ? state?.rememberIrcNetwork(choice) ?? Promise.resolve() : Promise.resolve(),
	);
}

export async function joinIrcBridge(
	ctx: RoomServerContext,
	network: string,
	channel: string,
	state: RoomServerOperationsState | null,
	remember: boolean,
	publicationId: string = crypto.randomUUID(),
	authorities: IrcBridgeAuthorities | null = null,
): Promise<string> {
	const owner = ctx.irc.networks.get(network);
	if (owner == null) throw new Error(`IRC network ${network} is not open`);
	return await ctx.irc.networks.mutate(
		owner,
		() => joinIrcBridgeNow(ctx, owner, channel, state, remember, publicationId, authorities),
	);
}

async function joinIrcBridgeNow(
	ctx: RoomServerContext,
	owner: OperatorIrcNetwork,
	channel: string,
	state: RoomServerOperationsState | null,
	remember: boolean,
	publicationId: string,
	authorities: IrcBridgeAuthorities | null,
): Promise<string> {
	const { network: networkName, host, port, nick } = owner.choice;
	const key = channelKey(networkName, channel);
	if (ctx.irc.bridged.has(key)) throw new Error(`${networkName}/${channel} is already bridged`);
	const relay = new IrcChannelRelay(channel, nick, { sendIntervalMs: 0 });
	const room = new IrcBridgeRoom(networkName, channel, relay, {
		publicationId,
		origin: `${host}:${port}`,
		ownOutbound: true,
		seatNick: (ircNick) => {
			const folded = ircFold(ircNick);
			for (const seat of held.seats.values()) {
				if (
					(seat.phase === "connecting" || seat.phase === "linked") &&
					(ircFold(seat.liveNick) === folded || ircFold(seat.identity.ircNick) === folded)
				) return true;
			}
			return false;
		},
		seatView: (session) => {
			const seat = held.seats.get(session);
			return seat == null ? null : { network: networkName, phase: seat.phase, nick: seat.liveNick };
		},
		onTrouble: (source, error) => ctx.journal.note(source, error),
		subscribeNote: () =>
			`this room bridges to ${channel}; your member row shows whether your IRC identity is connected`,
	});
	const held: BridgedChannel = {
		tables: ctx.irc,
		network: owner,
		channel,
		roomName: room.roomName,
		entryId: "",
		room,
		seats: new Map(),
		invitations: new Set(),
		status: "connecting",
		problem: "",
		stopped: false,
		forgetIntent: () => state?.forgetIrcBridge(networkName, channel) ?? Promise.resolve(),
		authorities,
	};
	const behavior = memberBridgeBehavior(
		held,
		memberOperations,
		authorities == null ? null : { link: (session) => authorities.link(publicationId, session) },
	);
	const entry = ctx.live.registerBridgeRoom(
		room.roomName,
		`${host}:${port}`,
		behavior,
		publicationId,
	);
	held.entryId = entry.id;
	ctx.irc.bridged.set(key, held);
	let persisted = false;
	try {
		if (remember) await state?.rememberIrcBridge({ network: networkName, channel, publicationId });
		persisted = remember && state != null;
		authorities?.activate(
			publicationId,
			room.roomName,
			behavior.roomBehavior(),
			(nick) => {
				const session = room.memberSession(nick);
				if (session == null) return false;
				retireSeat(held, session, "A moderator removed you from this IRC bridge room.");
				return true;
			},
			(nick) => room.prefixes.holderOf(nick) !== null,
			(kind, token) => room.authorityChanged(kind, token),
		);
	} catch (error) {
		if (persisted) {
			await state?.forgetIrcBridge(networkName, channel).catch((cleanup) =>
				held.tables.journal.note(`could not roll back ${room.roomName} authority state`, cleanup)
			);
		}
		retireBridge(ctx, key, held, false);
		throw error;
	}
	notifyPublicRoom(ctx, entry, "opened", null);
	ctx.irc.networks.attach(owner, held, relay);
	return room.roomName;
}

export async function restoreIrcBridges(
	ctx: RoomServerContext,
	state: RoomServerOperationsState,
	authorities: IrcBridgeAuthorities | null = null,
): Promise<void> {
	for (const choice of state.ircNetworks()) {
		try {
			await openIrcNetwork(ctx, choice, state, false);
		} catch (error) {
			ctx.journal.note(`could not restore the ${choice.network} IRC network`, error);
		}
	}
	for (const intent of state.ircBridges()) {
		try {
			await joinIrcBridge(ctx, intent.network, intent.channel, state, false, intent.publicationId, authorities);
		} catch (error) {
			ctx.journal.note(`could not restore the ${intent.network}/${intent.channel} IRC bridge`, error);
		}
	}
}

/** Delete one network capability and every channel lease below it. Persistence
 * moves first, so a crash can only restore the complete pre-close tree or the
 * complete post-close tree. */
export async function closeIrcNetwork(
	ctx: RoomServerContext,
	network: string,
	state: RoomServerOperationsState | null,
): Promise<void> {
	const owner = ctx.irc.networks.get(network);
	if (owner == null) throw new Error(`IRC network ${network} is not open`);
	await ctx.irc.networks.mutate(owner, async () => {
		await state?.forgetIrcNetwork(owner.choice.network);
		for (const [channelKey, held] of [...ctx.irc.bridged]) {
			if (held.network === owner) retireBridge(ctx, channelKey, held, true);
		}
		ctx.irc.networks.retire(owner);
	});
}

export function partIrcBridge(
	ctx: RoomServerContext,
	network: string,
	channel: string,
	state: RoomServerOperationsState | null,
): Promise<string> {
	const key = channelKey(network, channel);
	const held = ctx.irc.bridged.get(key);
	if (held != null) {
		return ctx.irc.networks.mutate(held.network, () => {
			if (ctx.irc.bridged.get(key) !== held) throw new Error(`${network}/${channel} is not bridged`);
			return partBridge(ctx, key, held);
		});
	}
	if (state == null || !state.ircBridges().some((intent) => channelKey(intent.network, intent.channel) === key)) {
		return Promise.reject(new Error(`${network}/${channel} is not bridged`));
	}
	return state.forgetIrcBridge(network, channel).then(() => `${network}/${channel}`);
}

export function ircBridgeSnapshot(ctx: RoomServerContext): Argument[] {
	return projectIrcBridgeSnapshot(ctx.irc.bridged.values());
}

/** The complete operator view: retained network capabilities first, then the
 * channel leases nested beneath them. Passwords never enter this projection. */
export function ircGatewaySnapshot(ctx: RoomServerContext): Argument[] {
	return projectIrcGatewaySnapshot(ctx.irc.networks, ctx.irc.bridged.values());
}

/** The one connection configuration a logical IRC network currently uses. */
export function ircNetworkChoice(ctx: RoomServerContext, network: string): IrcNetworkChoice | null {
	return ctx.irc.networks.choice(network);
}

/** Retire live bridge resources during process shutdown without changing the
 * durable intent that the next process must replay. */
export function closeIrcBridges(ctx: RoomServerContext): void {
	for (const [key, held] of [...ctx.irc.bridged]) retireBridge(ctx, key, held, false);
	ctx.irc.networks.closeAll();
}
