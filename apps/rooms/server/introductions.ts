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

import { Ref, type Session } from "@pancake/runtime";
import type { Argument } from "@pancake/runtime";
import { designatorHostPort, durableIdentityAuthenticated, parseLocator, TRANSPORT_WEBRTC } from "@pancake/runtime";
import { addressDesignator } from "@pancake/tcp";
import { isUriLocator } from "../lib/locator.ts";
import { notifyMember } from "./discovery.ts";
import { MAX_NAME_VOUCHERS, NAME_VOUCHER_BYTES } from "../lib/limits.ts";
import { NOTIFY, SIG_REJECT, VOUCHER } from "../lib/protocol.ts";
import {
	handBack,
	hex,
	type Introduction,
	introductions,
	nickKey,
	signalExchanges,
	webrtcDesignators,
} from "./registry.ts";

export function dropSignalExchange(id: string, reason?: string): void {
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
export function originatedExchange(session: Session, designator: string): string | null {
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
	const intro: Introduction = {
		nick,
		inbox,
		inboxes: new Map(),
		registrar: session,
		signaling: null,
		vouchers: new Set(),
	};
	introductions.set(key, intro);
	// The name capability: the holding of this name, detached from the
	// connection that holds it. Its one verb mints a single-use voucher that
	// `subscribe` on any connection redeems as being this member — bytes rather
	// than a reference, because a reference cannot be recognised by its minter
	// after crossing sessions (the gift-id move). It answers only while this
	// registration is the current one: a re-register replaces the introduction,
	// and a capability for the old one must not go on speaking for the name.
	const nameCap = session.spawn((verb: string): Argument => {
		if (verb !== VOUCHER) throw new Error(`a name capability has no method ${verb}`);
		if (introductions.get(key) !== intro) {
			throw new Error("this name capability is no longer current");
		}
		if (intro.vouchers.size >= MAX_NAME_VOUCHERS) {
			throw new Error(`a name may have at most ${MAX_NAME_VOUCHERS} vouchers outstanding`);
		}
		const bytes = crypto.getRandomValues(new Uint8Array(NAME_VOUCHER_BYTES));
		intro.vouchers.add(hex(bytes));
		return bytes;
	});
	// A `webrtc` locator is reached by signaling, not a socket, so index the
	// member under its designator for `signalOffer` routing.
	if (isUriLocator(locator)) {
		const loc = parseLocator(locator);
		if (loc.transport === TRANSPORT_WEBRTC) webrtcDesignators.set(loc.designator, key);
	}
	session.tell(inbox, NOTIFY, ["registered", nick]).catch(() => {});
	notifyMember("registered", nick, 1);
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
function withdrawIntroduction(key: string, intro: Introduction): void {
	introductions.delete(key);
	releaseInboxes(intro);
	forgetOfferedInboxes(key);
	for (const [designator, owner] of [...webrtcDesignators]) {
		if (owner === key) webrtcDesignators.delete(designator);
	}
	if (intro.signaling !== null) handBack(intro.registrar, intro.signaling);
	// The register inbox is the last export the room held for this member, and
	// the only one that was not being given back — a retained import per nick
	// change until the connection died. Every other stop-holding site routes
	// through handBack; this one now does too. A replace-own re-register files a
	// freshly spawned inbox, so releasing the old Ref is safe.
	handBack(intro.registrar, intro.inbox);
	// A bring-up toward this name cannot complete now its target is gone, and
	// the originator is a live third party mid-dial: tell them, rather than
	// leaving their offer to wait out its 30-second timeout and report a lie.
	// Only target-keyed exchanges: sweeping the ones this registrar *originated*
	// belongs to the disconnect path, because this also runs on a live
	// re-register, where killing the session's own in-flight dials to other
	// peers would be wrong.
	for (const [id, exchange] of [...signalExchanges]) {
		if (exchange.targetKey === key) dropSignalExchange(id, `"${intro.nick}" is no longer registered`);
	}
	notifyMember("unregistered", intro.nick, 0);
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
export function registeredNickOf(session: Session): string | null {
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
export function registeredByAnother(session: Session, nick: string): boolean {
	const holder = introductions.get(nickKey(nick));
	return holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen;
}

/** Spend one voucher for `nick`, true exactly once per minted voucher.
 *
 * A voucher redeems only while the registration that minted it stands — its
 * set rides the introduction, so a withdrawn or replaced registration takes
 * every outstanding voucher with it and a stale one fails closed. */
export function redeemNameVoucher(nick: string, voucher: Uint8Array): boolean {
	const intro = introductions.get(nickKey(nick));
	if (intro === undefined || !intro.registrar.sessionOpen) return false;
	return intro.vouchers.delete(hex(voucher));
}

/** Withdraw every introduction a closing connection registered. */
export function dropIntroductions(session: Session): void {
	for (const [key, intro] of [...introductions]) {
		if (intro.registrar !== session) continue;
		withdrawIntroduction(key, intro);
	}
}
