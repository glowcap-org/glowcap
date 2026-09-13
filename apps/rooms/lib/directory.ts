// The directory: the one object a rooms peer fetches by name, and everything it
// answers.
//
// Rooms are opened and entered here, names are registered here, and the
// introduction that opens a direct line is asked for here — but the directory
// carries none of the conversation. It hands out references and then steps out,
// which is why so much of this file is about arranging a meeting rather than
// relaying anything: an inbox minted for one peer, a handoff redeemed by
// dialing that peer, WebRTC signaling routed between two members who cannot
// dial each other at all.

import { Ref, retainCleanupFailures, retainSecondaryFailure } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import type { RoomsDirectoryDial } from "./locator.ts";
import { isManagedRoomId, MAX_DM_INBOXES, newManagedRoomId, REQUEST_TIMEOUT_MS } from "./limits.ts";
import type { RoomPolicy } from "./room/policy.ts";
import { INTRODUCTION_PENDING, RoomsError, roomsErrorOf } from "./errors.ts";
import {
	ADVERTISED_LOCATION,
	DIRECTORY,
	ENTER,
	ENTER_PUBLICATION,
	INTRODUCE,
	LINK,
	LIST_PUBLICATIONS,
	NOTIFY,
	OPEN,
	OPEN_PRIVATE_LINK,
	WATCH_PUBLICATIONS,
} from "./protocol.ts";
import { ask } from "./ask.ts";
import { DirectorySignaling } from "./directory_signal.ts";
import { type DirectoryRegisterOptions, DirectoryRegistration } from "./directory_registration.ts";
export type { DirectoryRegisterOptions } from "./directory_registration.ts";
import {
	parseDirectoryWatchSnapshot,
	parseRegistrationId,
	parseRooms,
	readRoomEvent,
	type RoomEvent,
	type RoomInfo,
} from "./directory_publications.ts";
import { parseRoomsSturdyref } from "./locator.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";
import { openManagedRoom } from "./managed_room.ts";
import { claimRedeemWithin, RedeemRouteCoordinator } from "./redeem_routes.ts";
import { claimCapabilityWithin } from "./capability_cleanup.ts";

// How long `introduceVia` waits for the peer to offer an inbox for us after the
// directory has asked them for one. Bounded, because the peer may never answer.
const INTRODUCIBLE_TIMEOUT_MS = 10_000;

// ── Which directory a redeem rides (ADR-0089) ──────────────────────────────
//
// A `webrtc` locator carries a designator and nothing else — no address, and no
// word about where the peer can be signaled — so the connector redeeming an
// introduction cannot say which directory vouched for the peer it is dialing.
// It asks the signaling authority, and a tab that joined somebody else's
// directory holds more than one: its own page's, opened at boot, and the one it
// went to. Signaling through the wrong one reaches nobody, because the offer
// names a designator that directory never registered — and it tells a room that
// has nothing to do with this conversation who the reader is trying to reach,
// and hands it an SDP describing where they are.
//
// So the redeem says which directory it rides, here, and the authority in
// `signaling.ts` reads it. Two redeems in flight through *different* directories
// would leave that unanswerable, so the second one waits. Redeems through the
// same directory share one active batch; once another directory is queued, new
// work waits behind it so a busy room cannot starve every other one.
const redeemRoutes = new RedeemRouteCoordinator<Directory>(MAX_DM_INBOXES, REQUEST_TIMEOUT_MS);

/** The directory whose redeem is in flight, or null when none is or the answer
 * would be a guess. Read by the WebRTC signaling authority to route one
 * exchange; every other caller has a directory in hand already. */
export function signalingRoute(): Directory | null {
	return redeemRoutes.current();
}

/** The directory of rooms: the server's one published object. Connect to it,
 * then `open` a new room or `enter` an existing one, each returns a reference
 * to that room. Both mirror the wire: `open` rejects if the name is taken,
 * `enter` rejects if there is no such room. `list` and `watch` are discovery:
 * the rooms that have people in them, as a snapshot or a live feed. The
 * directory owns the connection; close it with `close` when the session ends. */
export class Directory {
	readonly session: Session;
	#directory: Ref;
	readonly #serving: Promise<void>;
	readonly #localRefs = new Set<Ref>();
	#retainedFailure: unknown | null = null;
	readonly #signaling: DirectorySignaling;
	readonly #registration: DirectoryRegistration;
	#closePromise: Promise<void> | null = null;
	readonly #lifetime = new AbortController();
	// Callers parked in `introduceVia` waiting for a peer to offer them an inbox,
	// by the peer's lowercased nick. Fed by the register inbox's `introducible`.
	readonly #introducible = new Map<string, (() => void)[]>();
	#introducibleWaiterCount = 0;
	// Peers whose `introducible` arrived with nobody parked on it. The notify
	// dispatches synchronously inside the inbound feed while our own refusal
	// surfaces as a promise rejection on a later microtask, so the wakeup can
	// reach us before the caller it is for.
	readonly #introducibleSeen = new Set<string>();

	private constructor(session: Session, directory: Ref, serving: Promise<void>) {
		this.session = session;
		this.#directory = directory;
		this.#serving = serving;
		this.#signaling = new DirectorySignaling(
			session,
			directory,
			(ref) => this.#releaseLocal(ref),
		);
		this.#registration = new DirectoryRegistration(
			session,
			directory,
			(ref) => this.#releaseLocal(ref),
			(peer, registrationId) => this.#wakeIntroducible(peer, registrationId),
		);
	}

	/** Dial `locator`, start serving, and fetch the directory by name. The caller
	 * supplies a dialer bound to the Runtime that owns its identity and transport
	 * composition. */
	static async connect(
		locator: string,
		dial: RoomsDirectoryDial,
	): Promise<Directory> {
		const reached = await dial(locator);
		const session = "session" in reached ? reached.session : reached;
		const routedDirectory = "session" in reached ? reached.directory : null;
		// Start the inbound loop before fetching, so the fetch's resolution arrives.
		const serving = session.serve();
		// tolerant: a Directory owns this promise and observes it at close, so
		// nothing is lost here. This handler only keeps a transport fault before
		// then from surfacing as an unhandled rejection.
		void serving.catch(() => {});
		try {
			const directory = routedDirectory ?? await claimCapabilityWithin(
				session,
				session.fetch(DIRECTORY),
				"the Rooms peer did not answer fetching its directory",
				REQUEST_TIMEOUT_MS,
			);
			return new Directory(session, directory, serving);
		} catch (error) {
			throw await retainCleanupFailures(error, [
				() => session.close(),
				() => serving,
			]);
		}
	}

	#releaseLocal(ref: Ref): void {
		try {
			this.session.release(ref);
			this.#localRefs.delete(ref);
		} catch (error) {
			// The Directory remains the explicit owner and retries at close. A
			// successful remote adoption is not turned into a false operation failure.
			this.#localRefs.add(ref);
			this.#retainedFailure = this.#retainedFailure === null
				? error
				: retainSecondaryFailure(this.#retainedFailure, error);
		}
	}

	/** Create a new room and return a reference to it.
	 *
	 * A public room takes the name, so this rejects if that name is taken. A
	 * private one takes nothing: it is not listed, cannot be entered by name, and
	 * is reached only by holding the reference this answers with or one passed on
	 * from it with `invite`. Two of them may share a label, and neither reader
	 * learns of the other's. */
	open(name: string): Promise<Ref> {
		return ask(
			this.session,
			this.#directory,
			OPEN,
			[name],
			`the directory did not answer opening "${name}"`,
		) as Promise<Ref>;
	}

	/** Create a room with its separate, passable management capability. The
	 * two-stage bootstrap settles persistence before exposing either sturdyref;
	 * baseline `open` remains room-only. */
	openManaged(
		name: string,
		options: { policy?: RoomPolicy; roomId?: string } = {},
	): Promise<{ room: Ref; roomLink: string; managerLink: string }> {
		return openManagedRoom(this.session, this.#directory, name, options);
	}

	/** Create or recover one private room under an opaque caller-held key.
	 * A repeated call with the same key returns the same room, so a lost answer
	 * can be retried without creating another room. */
	openPrivate(label: string, recoveryKey = newManagedRoomId()): Promise<Ref> {
		if (!isManagedRoomId(recoveryKey)) throw new Error("a private room recovery key is invalid");
		return ask(
			this.session,
			this.#directory,
			OPEN,
			[label, true, recoveryKey],
			`the directory did not answer opening private room "${label}"`,
		) as Promise<Ref>;
	}

	/** Persist and return a private room's durable authority as one directory
	 * act. Repeating the opaque key returns the same sturdyref across restarts. */
	async openPrivateLink(recoveryKey = newManagedRoomId()): Promise<string> {
		if (!isManagedRoomId(recoveryKey)) throw new Error("a private room recovery key is invalid");
		const answer = await ask(
			this.session,
			this.#directory,
			OPEN_PRIVATE_LINK,
			[recoveryKey],
			"the directory did not answer creating a private room link",
		);
		if (typeof answer !== "string" || answer === "") {
			throw new Error("the directory answered private room creation without a sturdyref");
		}
		return answer;
	}

	/** Return a reference to an existing room. Rejects if there is no such room. */
	enter(name: string): Promise<Ref> {
		return ask(
			this.session,
			this.#directory,
			ENTER,
			[name],
			`the directory did not answer entering "${name}"`,
		) as Promise<Ref>;
	}

	/** Return the exact generation advertised by this wrapper's rich discovery verbs. */
	enterPublication(id: string): Promise<Ref> {
		return ask(
			this.session,
			this.#directory,
			ENTER_PUBLICATION,
			[id],
			"the directory did not answer entering that room publication",
		) as Promise<Ref>;
	}

	/** The stable room sturdyref this directory minted. The room Host authors
	 * both its durable authority and the location current for this session, so a
	 * client cannot accidentally splice that authority onto one stale route. */
	async link(name: string): Promise<string> {
		const sturdyref = await ask(
			this.session,
			this.#directory,
			LINK,
			[name],
			`the directory did not answer linking "${name}"`,
		);
		if (typeof sturdyref !== "string" || sturdyref.length === 0) {
			throw new Error(`link("${name}") did not return a sturdyref`);
		}
		parseRoomsSturdyref(sturdyref);
		return sturdyref;
	}

	/** The live rooms right now, the ones with people in them. */
	async list(): Promise<RoomInfo[]> {
		return parseRooms(
			await ask(
				this.session,
				this.#directory,
				LIST_PUBLICATIONS,
				[],
				"the directory did not answer its room list",
			),
		);
	}

	/** Ask the server that owns its listeners how durable links should reach it. */
	async advertisedLocation(): Promise<string> {
		const location = await ask(
			this.session,
			this.#directory,
			ADVERTISED_LOCATION,
			[],
			"the directory did not answer its advertised location",
		);
		if (typeof location !== "string" || location.length === 0) {
			throw new Error("advertisedLocation did not return a locator");
		}
		return location;
	}

	/** Follow the live room list: spawn an observer the directory calls back with
	 * each change, register it, and return the current snapshot as a baseline.
	 * `onEvent` then fires on every open/close/count change. */
	async watch(onEvent: (event: RoomEvent) => void): Promise<RoomInfo[]> {
		const observer = this.session.spawn((verb, args) => {
			releaseUnclaimedCapabilityArguments(
				this.session,
				args,
				"the directory watch inbox could not return an unexpected capability",
			);
			if (verb !== NOTIFY) throw new Error(`watch inbox has no method ${verb}`);
			const event = readRoomEvent(args);
			if (event !== null) onEvent(event);
			return null;
		});
		try {
			const raw = await ask(
				this.session,
				this.#directory,
				WATCH_PUBLICATIONS,
				[observer],
				"the directory did not answer watching its rooms",
			);
			const snapshot = parseDirectoryWatchSnapshot(raw);
			for (const peer of snapshot.peers) {
				onEvent({
					kind: "registered",
					name: peer.name,
					registrationId: peer.registrationId,
					count: 1,
					entry: null,
				});
			}
			if (snapshot.omitted > 0) {
				onEvent({ kind: "truncated", name: "", count: snapshot.omitted, entry: null });
			}
			this.#releaseLocal(observer);
			return snapshot.rooms;
		} catch (error) {
			throw await retainCleanupFailures(error, [() => this.session.release(observer)]);
		}
	}

	/** Announce a member for DM introduce. `locator` is the listen address redeem
	 * should dial. Resolves on `notify("registered", …)`.
	 *
	 * `onMintInboxFor` fires when the directory needs an inbox for a named peer.
	 * Supply one to be reachable by direct message at all: without it every
	 * `introduce` aimed here stays pending. Answer it with `offerInbox`. */
	register(
		nick: string,
		locator: string,
		options: DirectoryRegisterOptions = {},
	): Promise<string> {
		return this.#registration.register(nick, locator, options);
	}

	/** Ask a registered peer to establish the reciprocal direct carrier after
	 * this side learned it cannot dial the peer's advertised one. */
	async requestDirect(peer: string, registrationId: string): Promise<void> {
		await this.#registration.requestDirect(peer, registrationId);
	}

	async memberRegistration(peer: string): Promise<string> {
		return await this.#registration.memberRegistration(peer);
	}

	/** A single-use proof that the caller holds this directory's registered
	 * name, for a `subscribe` arriving on another connection; null when this
	 * directory minted no name capability. Each voucher redeems once, and only
	 * while the registration stands. */
	async nameVoucher(): Promise<Uint8Array | null> {
		return await this.#registration.nameVoucher();
	}

	/** Ask the directory to introduce us to a registered member, returning a live
	 * reference to that member's `dm` object. The directory answers with a
	 * `desc:handoff-give`, and the binding redeems it by dialing the member
	 * directly. The reference we get back therefore talks to the member over our
	 * own connection, not through the directory.
	 *
	 * `register` first: the directory reads the asker's name off its own
	 * registration, never from the message, so an unregistered caller has no name
	 * an inbox could have been minted for. Rejects if no member with that nick is
	 * registered. */
	async introduce(nick: string, registrationId: string): Promise<Ref> {
		return (await this.introduceVia(nick, registrationId)).dm;
	}

	/** Introduce us to a member, returning both the member's `dm` reference and
	 * the direct `Session` the redeem dialed to reach it (`via`). Hosting a reply
	 * inbox on `via` and sending the DM over `via` lets the member answer us back
	 * over that same connection — the bidirectional completion of the
	 * introduction, which is the only way a member can reach a caller (a browser,
	 * say) that cannot itself be dialed. `via` is null only if the reply named no
	 * fresh redeem. Requires a `register`, like `introduce`. Rejects if no member
	 * with that nick is registered. */
	async introduceVia(
		nick: string,
		expectedRegistrationId?: string,
	): Promise<{ dm: Ref; via: Session | null; registrationId: string }> {
		const registrationId = expectedRegistrationId ?? await this.memberRegistration(nick);
		parseRegistrationId(registrationId, `introduce("${nick}")`);
		try {
			return await this.#introduceOnce(nick, registrationId);
		} catch (err) {
			if (roomsErrorOf(err)?.code !== INTRODUCTION_PENDING) throw err;
		}
		// First contact with this peer: the directory has just asked them for an
		// inbox for us. Wait for the offer to land, then ask again.
		//
		// Twice, because a wakeup recorded before we asked may be spent: the
		// directory drops a member's offers whenever either name changes hands, so
		// an `introducible` we banked can name an inbox that no longer exists. A
		// retry refused again therefore waits for a fresh notify rather than
		// reporting failure on the strength of an old one.
		for (let attempt = 0; attempt < 2; attempt += 1) {
			await this.#awaitIntroducible(nick, registrationId, attempt === 0);
			try {
				return await this.#introduceOnce(nick, registrationId);
			} catch (err) {
				if (roomsErrorOf(err)?.code !== INTRODUCTION_PENDING) throw err;
			}
		}
		throw new RoomsError(
			INTRODUCTION_PENDING,
			`"${nick}" did not offer an inbox for us`,
		);
	}

	async #introduceOnce(
		nick: string,
		expectedRegistrationId: string,
	): Promise<{ dm: Ref; via: Session | null; registrationId: string }> {
		// Named as this directory's redeem: the dial it raises may need signaling,
		// and only this side knows which directory is vouching for the peer.
		const redemption = redeemRoutes.run(
			this,
			this.#lifetime.signal,
			() => this.session.sendRedeeming(this.#directory, INTRODUCE, [nick, expectedRegistrationId]),
		);
		const result = await claimRedeemWithin(
			redemption,
			`introduce("${nick}") did not finish redeeming its handoff`,
			REQUEST_TIMEOUT_MS,
			(late) => this.#releaseAbandonedRedeem(late.reply, late.via),
		);
		const { reply, via } = result;
		if (!(reply instanceof Ref)) {
			throw new Error(`introduce("${nick}") did not return a capability`);
		}
		return { dm: reply, via, registrationId: expectedRegistrationId };
	}

	#releaseAbandonedRedeem(reply: unknown, via: Session | null): void {
		if (!(reply instanceof Ref)) return;
		try {
			(via ?? this.session).release(reply);
		} catch (error) {
			// Before close, preserve the cleanup refusal for its owning barrier. Once
			// close has begun, native session retirement is the remaining authority.
			if (this.#closePromise === null) {
				this.#retainedFailure = this.#retainedFailure === null
					? error
					: retainSecondaryFailure(this.#retainedFailure, error);
			}
		}
	}

	#wakeIntroducible(_peer: string, registrationId: string): void {
		const key = registrationId;
		const waiting = this.#introducible.get(key);
		this.#introducible.delete(key);
		// A list every waiter has timed out of is the same as no list: bank the
		// wakeup, or it reaches nobody and the next caller parks on a signal that
		// has already been sent.
		if (waiting === undefined || waiting.length === 0) {
			if (!this.#introducibleSeen.has(key) && this.#introducibleSeen.size >= MAX_DM_INBOXES) {
				const oldest = this.#introducibleSeen.values().next().value;
				if (oldest != null) this.#introducibleSeen.delete(oldest);
			}
			this.#introducibleSeen.add(key);
			return;
		}
		for (const wake of waiting) wake();
	}

	/** Wait for `nick` to offer us an inbox. `useBanked` spends a wakeup that
	 * arrived before this call; the retry pass passes false, so it waits for a
	 * fresh one. */
	#awaitIntroducible(nick: string, registrationId: string, useBanked: boolean): Promise<void> {
		const key = registrationId;
		if (useBanked && this.#introducibleSeen.delete(key)) return Promise.resolve();
		return new Promise((resolve, reject) => {
			if (this.#lifetime.signal.aborted) {
				reject(this.#lifetime.signal.reason);
				return;
			}
			if (this.#introducibleWaiterCount >= MAX_DM_INBOXES) {
				reject(new Error(`a directory connection may await at most ${MAX_DM_INBOXES} direct introductions`));
				return;
			}
			let settled = false;
			const cleanup = () => {
				const waiting = this.#introducible.get(key);
				if (waiting !== undefined) {
					const i = waiting.indexOf(wake);
					if (i >= 0) waiting.splice(i, 1);
					if (waiting.length === 0) this.#introducible.delete(key);
				}
				clearTimeout(timer);
				this.#lifetime.signal.removeEventListener("abort", abort);
				this.#introducibleWaiterCount -= 1;
			};
			const finish = (error?: unknown) => {
				if (settled) return;
				settled = true;
				cleanup();
				if (error === undefined) resolve();
				else reject(error);
			};
			const wake = () => finish();
			const abort = () => finish(this.#lifetime.signal.reason);
			const timer = setTimeout(() => {
				finish(
					new RoomsError(
						INTRODUCTION_PENDING,
						`"${nick}" did not offer an inbox for us in time`,
					),
				);
			}, INTRODUCIBLE_TIMEOUT_MS);
			this.#introducibleWaiterCount += 1;
			const waiting = this.#introducible.get(key);
			if (waiting === undefined) this.#introducible.set(key, [wake]);
			else waiting.push(wake);
			this.#lifetime.signal.addEventListener("abort", abort, { once: true });
		});
	}

	/** Offer the directory an inbox for one named peer, the answer to a
	 * `mintInboxFor` request. */
	async offerInbox(forNick: string, forRegistrationId: string, inbox: Ref): Promise<void> {
		await this.#registration.offerInbox(forNick, forRegistrationId, inbox);
	}

	/** File this member's WebRTC signaling inbox with the directory. */
	offerSignaling(inbox: Ref): Promise<void> {
		return this.#signaling.offerSignaling(inbox);
	}

	/** Start one signaling exchange toward `designator` and resolve the far
	 * peer's SDP answer. */
	signalOffer(designator: string, sdp: string): Promise<string> {
		return this.#signaling.signalOffer(designator, sdp);
	}

	/** Answer exchange `id` with this member's SDP answer. */
	signalAnswer(id: string, sdp: string): Promise<void> {
		return this.#signaling.signalAnswer(id, sdp);
	}

	/** Trickle one ICE candidate toward the live exchange named by `key`. */
	signalCandidate(key: string, ice: string): Promise<void> {
		return this.#signaling.signalCandidate(key, ice);
	}

	/** Register the sink for candidates the far peer trickles back. */
	onSignalCandidate(designator: string, sink: (ice: string) => void): () => void {
		return this.#signaling.onSignalCandidate(designator, sink);
	}

	/** Close the session, ending every room's `messages` stream. */
	close(): Promise<void> {
		if (this.#closePromise !== null) return this.#closePromise;
		this.#closePromise = this.#close();
		return this.#closePromise;
	}

	async #close(): Promise<void> {
		this.#lifetime.abort(new Error("the directory connection ended"));
		let failure: unknown | null = this.#retainedFailure;
		const signalingFailure = this.#signaling.takeFailure();
		if (signalingFailure !== null) {
			failure = failure === null ? signalingFailure : retainSecondaryFailure(failure, signalingFailure);
		}
		const observe = (error: unknown) => {
			failure = failure === null ? error : retainSecondaryFailure(failure, error);
		};
		const release = (ref: Ref) => {
			try {
				this.session.release(ref);
				this.#localRefs.delete(ref);
			} catch (error) {
				observe(error);
			}
		};
		for (const reply of this.#signaling.abandon("rooms: directory closed")) {
			this.#localRefs.add(reply);
		}
		for (const ref of [...this.#localRefs]) release(ref);
		release(this.#directory);
		const nameCap = await this.#registration.takeNameCapability();
		if (nameCap !== null) release(nameCap);
		try {
			await this.session.close();
		} catch (error) {
			observe(error);
		}
		try {
			await this.#serving;
		} catch (error) {
			observe(error);
		}
		if (failure !== null) throw failure;
	}
}
