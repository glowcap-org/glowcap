// Who can be reached directly, and the proof that a name is theirs.
//
// The directory introduces two members and then steps out: it never carries a
// direct message, only the inbox one member minted for one other. So a
// registration is a claim on a name held by a connection, an introduction hands
// out exactly the inbox meant for the caller, and a voucher is the one way that
// claim travels to a connection the server has not seen before.
//
// WebRTC signaling rides here too, because it is the same shape: opaque strings
// routed between two members the directory already reaches, parsed by nobody.

import { currentSession, Ref, type Session } from "@pancake/runtime";
import type { Argument } from "@pancake/runtime";
import { designatorHostPort, durableIdentityAuthenticated, parseLocator, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { addressDesignator } from "@pancake/tcp";
import { isUriLocator } from "../lib/locator.ts";
import { notifyMember } from "./discovery.ts";
import { DIRECT_REQUEST_COALESCE_MS, MAX_DM_INBOXES, MAX_NAME_VOUCHERS, NAME_VOUCHER_BYTES } from "../lib/limits.ts";
import { NOTIFY, SIG_REJECT, VOUCHER } from "../lib/protocol.ts";
import type { RoomServerContext } from "./context.ts";
import type { RoomLiveIndex } from "./live_index.ts";
import { hex, type Introduction, nickKey } from "./registry.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";

export function dropSignalExchange(live: RoomLiveIndex, id: string, reason?: string): void {
	const exchange = live.signalExchanges.get(id);
	if (exchange === undefined) return;
	live.signalExchanges.delete(id);
	clearTimeout(exchange.expires);
	if (reason == null) {
		live.journal.release(exchange.originator, exchange.reply);
		return;
	}
	// Queue the reject before releasing the remote import. Retirement is joined
	// to the send so a slow carrier cannot invert those two protocol effects.
	void exchange.originator.tell(exchange.reply, SIG_REJECT, [reason]).then(
		() => live.journal.release(exchange.originator, exchange.reply),
		() => live.journal.release(exchange.originator, exchange.reply),
	);
}

/** The exchange `session` originated toward `designator`, if one is live. A
 * scan, bounded by the exchange cap. */
export function originatedExchange(live: RoomLiveIndex, session: Session, designator: string): string | null {
	const targetKey = live.webrtcDesignators.get(designator);
	if (targetKey === undefined) return null;
	for (const [id, exchange] of live.signalExchanges) {
		if (exchange.originator === session && exchange.targetKey === targetKey) return id;
	}
	return null;
}

/** Admit one reciprocal-route notification under a live registration.
 *
 * The map is a coalescing window, not a history of every peer this member has
 * met. Expired rows leave lazily at the capacity boundary; the common case is
 * one lookup and one write, while an attacker can force at most one bounded
 * scan before either freeing stale rows or receiving a refusal. */
export function directRequestNoticeDue(
	requests: Map<string, number>,
	peer: string,
	now: number,
): boolean {
	const prior = requests.get(peer);
	if (prior != null && now - prior < DIRECT_REQUEST_COALESCE_MS) return false;
	if (prior == null && requests.size >= MAX_DM_INBOXES) {
		for (const [key, requestedAt] of requests) {
			if (now - requestedAt >= DIRECT_REQUEST_COALESCE_MS) requests.delete(key);
		}
		if (requests.size >= MAX_DM_INBOXES) {
			throw new Error(`a member may track at most ${MAX_DM_INBOXES} reciprocal direct requests`);
		}
	}
	requests.set(peer, now);
	return true;
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
 * noise-relay designator of its own, so its connection here proves nothing about the address
 * it advertises. Refusing that would refuse the app's headline feature; accepting
 * it is what the directory has always done. The honest statement is that an
 * unkeyed registration is a claim the directory passes on without vouching for,
 * and that keying the directory's own connections is what would close it — a
 * larger change than this function. */
export function claimsOwnLocator(session: Session, locator: string): boolean {
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
export function registerMember(
	ctx: RoomServerContext,
	nick: string,
	locator: string,
	inbox: Ref,
	session: Session,
): Ref {
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
	let webrtcDesignator: string | null = null;
	try {
		if (isUriLocator(locator)) {
			const parsed = parseLocator(locator);
			if (parsed.transport === TRANSPORT_WEBRTC) webrtcDesignator = parsed.designator;
		}
	} catch (error) {
		ctx.journal.release(session, inbox, "unregistered member inbox");
		throw error;
	}
	let registrationId: string;
	const live = ctx.live;
	do registrationId = crypto.randomUUID(); while (live.introductionsById.has(registrationId));
	const intro: Introduction = {
		nick,
		registrationId,
		inbox,
		inboxes: new Map(),
		directRequests: new Map(),
		registrar: session,
		signaling: null,
		vouchers: new Set(),
	};
	// The name capability: the holding of this name, detached from the
	// connection that holds it. Its one verb mints a single-use voucher that
	// `subscribe` on any connection redeems as being this member — bytes rather
	// than a reference, because a reference cannot be recognised by its minter
	// after crossing sessions (the gift-id move). It answers only while this
	// registration is the current one: a re-register replaces the introduction,
	// and a capability for the old one must not go on speaking for the name.
	let nameCap: Ref;
	try {
		nameCap = session.spawn((verb: string, args: Argument[]): Argument => {
			const caller = currentSession();
			if (caller == null) throw new Error("a name capability is reachable only over a session");
			if (hasCapabilityArguments(args)) {
				throwAfterReleasingCapabilities(
					caller,
					args,
					new Error(`name capability ${verb} does not take capability arguments`),
				);
			}
			if (verb !== VOUCHER) throw new Error(`a name capability has no method ${verb}`);
			if (args.length !== 0) throw new Error("voucher takes no arguments");
			if (live.introductions.get(key) !== intro) {
				throw new Error("this name capability is no longer current");
			}
			if (intro.vouchers.size >= MAX_NAME_VOUCHERS) {
				throw new Error(`a name may have at most ${MAX_NAME_VOUCHERS} vouchers outstanding`);
			}
			const bytes = crypto.getRandomValues(new Uint8Array(NAME_VOUCHER_BYTES));
			intro.vouchers.add(hex(bytes));
			return bytes;
		});
	} catch (error) {
		ctx.journal.release(session, inbox, "unregistered member inbox");
		throw error;
	}
	try {
		const priorForSession = live.introductionsBySession.get(session);
		if (priorForSession != null && priorForSession !== live.introductions.get(key)) {
			withdrawIntroduction(ctx, nickKey(priorForSession.nick), priorForSession);
		}
		// Only ever this member replacing its own registration: a live one held by
		// another connection was refused at the verb, and a dead one is theirs to
		// lose. The name frees when its holder's connection goes, and nothing else
		// can take it while that connection stands.
		const prior = live.introductions.get(key);
		if (prior != null) withdrawIntroduction(ctx, key, prior);
	} catch (error) {
		ctx.journal.release(session, nameCap, "uncommitted name capability");
		ctx.journal.release(session, inbox, "unregistered member inbox");
		throw error;
	}
	live.introductions.set(key, intro);
	live.introductionsById.set(registrationId, intro);
	live.introductionsBySession.set(session, intro);
	ctx.operator.noteChange();
	// A `webrtc` locator is reached by signaling, not a socket, so index the
	// member under its designator for `signalOffer` routing.
	if (webrtcDesignator != null) live.webrtcDesignators.set(webrtcDesignator, key);
	try {
		session.tell(inbox, NOTIFY, ["registered", nick, intro.registrationId]).catch((error) => {
			ctx.journal.note("a registration acknowledgement failed", error);
		});
	} catch (error) {
		ctx.journal.note("a registration acknowledgement failed", error);
	}
	try {
		notifyMember(ctx, "registered", nick, intro.registrationId, 1);
	} catch (error) {
		ctx.journal.note("a registration discovery notification failed", error);
	}
	return nameCap;
}

/** Take one registration out of the registry, announce it, and leave nothing
 * behind that still points at the name.
 *
 * A name outlives its holders, so the next one to claim it must start from
 * nothing: the inboxes this holder collected are released, and so is every inbox
 * *other* members offered for this name. Skipping that second sweep is what would
 * hand the next holder of "bob" the inbox Carol minted for the previous one, and
 * her interface would paint their messages as his with full confidence. */
function withdrawIntroduction(ctx: RoomServerContext, key: string, intro: Introduction): void {
	const live = ctx.live;
	if (live.introductionsById.get(intro.registrationId) !== intro) {
		throw new Error("registration ID index does not name its nickname registration");
	}
	if (live.introductionsBySession.get(intro.registrar) !== intro) {
		throw new Error("registration session index does not name its nickname registration");
	}
	live.introductions.delete(key);
	live.introductionsById.delete(intro.registrationId);
	live.introductionsBySession.delete(intro.registrar);
	ctx.operator.noteChange();
	releaseInboxes(ctx, intro);
	forgetOfferedInboxes(live, intro.registrationId);
	for (const [designator, owner] of [...live.webrtcDesignators]) {
		if (owner === key) live.webrtcDesignators.delete(designator);
	}
	if (intro.signaling !== null) ctx.journal.release(intro.registrar, intro.signaling);
	// The register inbox is the last export the room held for this member, and
	// the only one that was not being given back — a retained import per nick
	// change until the connection died. Every other stop-holding site routes
	// through the journal's release; this one now does too. A replace-own re-register files a
	// freshly spawned inbox, so releasing the old Ref is safe.
	ctx.journal.release(intro.registrar, intro.inbox);
	// A bring-up toward this name cannot complete now its target is gone, and
	// the originator is a live third party mid-dial: tell them, rather than
	// leaving their offer to wait out its 30-second timeout and report a lie.
	// Only target-keyed exchanges: sweeping the ones this registrar *originated*
	// belongs to the disconnect path, because this also runs on a live
	// re-register, where killing the session's own in-flight dials to other
	// peers would be wrong.
	for (const [id, exchange] of [...live.signalExchanges]) {
		if (exchange.targetKey === key) dropSignalExchange(live, id, `"${intro.nick}" is no longer registered`);
	}
	notifyMember(ctx, "unregistered", intro.nick, intro.registrationId, 0);
}

/** Hand back every inbox an introduction collected. */
function releaseInboxes(ctx: RoomServerContext, intro: Introduction): void {
	for (const ref of intro.inboxes.values()) ctx.journal.release(intro.registrar, ref);
	intro.inboxes.clear();
}

/** Drop the inbox every other member offered for `registrationId`, so an `introduce` naming
 * it is refused `introduction-pending` and the member mints a fresh one. */
function forgetOfferedInboxes(live: RoomLiveIndex, registrationId: string): void {
	for (const intro of live.introductions.values()) {
		intro.directRequests.delete(registrationId);
		const ref = intro.inboxes.get(registrationId);
		if (ref === undefined) continue;
		intro.inboxes.delete(registrationId);
		live.journal.release(intro.registrar, ref);
	}
}

/** The nick this connection registered, or null when it registered none. The only
 * trustworthy source of a caller's own name is the registration the directory
 * granted, never an argument the caller passes. A scan, bounded by the members
 * present. */
export function registeredNickOf(live: RoomLiveIndex, session: Session): string | null {
	return registrationOf(live, session)?.nick ?? null;
}

/** The exact live registration held by `session`, or null when it holds none. */
export function registrationOf(live: RoomLiveIndex, session: Session): Introduction | null {
	return live.introductionsBySession.get(session) ?? null;
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
export function registeredByAnother(live: RoomLiveIndex, session: Session, nick: string): boolean {
	const holder = live.introductions.get(nickKey(nick));
	return holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen;
}

/** Spend one voucher for `nick`, true exactly once per minted voucher.
 *
 * A voucher redeems only while the registration that minted it stands — its
 * set rides the introduction, so a withdrawn or replaced registration takes
 * every outstanding voucher with it and a stale one fails closed. */
export function redeemNameVoucher(live: RoomLiveIndex, nick: string, voucher: Uint8Array): boolean {
	const intro = live.introductions.get(nickKey(nick));
	if (intro == null || !intro.registrar.sessionOpen) return false;
	return intro.vouchers.delete(hex(voucher));
}

/** Withdraw every introduction a closing connection registered. */
export function dropIntroductions(ctx: RoomServerContext, session: Session): void {
	const intro = ctx.live.introductionsBySession.get(session);
	if (intro != null) withdrawIntroduction(ctx, nickKey(intro.nick), intro);
}

/** Remove exactly the registration still owned by `session`. A nickname alone
 * is not an operator target because it may have changed hands since inventory. */
export function revokeIntroduction(ctx: RoomServerContext, nick: string, session: Session): boolean {
	const key = nickKey(nick);
	const intro = ctx.live.introductions.get(key);
	if (intro == null || intro.registrar !== session) return false;
	withdrawIntroduction(ctx, key, intro);
	return true;
}
