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

import { formatSturdyRef, Ref, retainCleanupFailures, retainSecondaryFailure } from "@pancake/runtime";
import type { Session } from "@pancake/runtime";
import { type RoomsDial, roomsLocator } from "./locator.ts";
import { INTRODUCTION_PENDING, RoomError, roomErrorOf } from "./errors.ts";
import {
	ADVERTISED_LOCATION,
	DIRECTORY,
	ENTER,
	ENTER_PUBLICATION,
	INTRODUCE,
	LINK,
	LIST_PUBLICATIONS,
	NOTIFY,
	OFFER_INBOX,
	OPEN,
	REGISTER,
	VOUCHER,
	WATCH_PUBLICATIONS,
} from "./protocol.ts";
import { ask } from "./ask.ts";
import { DirectorySignaling } from "./directory_signal.ts";
import { parseRooms, readRoomEvent, type RoomEvent, type RoomInfo } from "./directory_publications.ts";

// How long `register` waits for the directory's `notify("registered")` before it
// rejects. A registration whose ack never lands (the server's `registerMember`
// threw) must surface as a failure the caller can retry, not a silent hang; the
// window sits far above the round-trip a healthy directory answers within.
const REGISTER_ACK_TIMEOUT_MS = 10_000;

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
// would leave that unanswerable, so the second one waits; redeems through the
// same directory never wait on one another, which leaves the ordinary cases —
// one directory open, or several conversations in one room — unqueued.
const redeemsInFlight = new Map<Directory, number>();

const waitingToRedeem: (() => void)[] = [];

/** The directory whose redeem is in flight, or null when none is or the answer
 * would be a guess. Read by the WebRTC signaling authority to route one
 * exchange; every other caller has a directory in hand already. */
export function signalingRoute(): Directory | null {
	if (redeemsInFlight.size !== 1) return null;
	for (const dir of redeemsInFlight.keys()) return dir;
	return null;
}

/** Run `redeem` as this directory's, so signaling raised by the dial inside it
 * reaches this directory and no other. */
async function redeemingThrough<T>(dir: Directory, redeem: () => Promise<T>): Promise<T> {
	// A redeem through another directory is already the route; wait for it
	// rather than make the route ambiguous while this one is in flight.
	while (redeemsInFlight.size > 0 && !redeemsInFlight.has(dir)) {
		await new Promise<void>((wake) => waitingToRedeem.push(wake));
	}
	redeemsInFlight.set(dir, (redeemsInFlight.get(dir) ?? 0) + 1);
	try {
		return await redeem();
	} finally {
		const rest = (redeemsInFlight.get(dir) ?? 1) - 1;
		if (rest > 0) redeemsInFlight.set(dir, rest);
		else {
			redeemsInFlight.delete(dir);
			// Everyone waiting, because each re-reads the condition on its own
			// turn and the first one through sets the route the rest then see.
			if (redeemsInFlight.size === 0) {
				for (const wake of waitingToRedeem.splice(0)) wake();
			}
		}
	}
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
	#closePromise: Promise<void> | null = null;
	// The name capability the directory answered `register` with. A promise,
	// because `register` resolves on the directory's ack and the capability rides
	// the reply, which can land after it: a caller who registers and immediately
	// mints a voucher must wait for the capture, not read a null that is about to
	// stop being true. Settles null when a directory grants no transferable name
	// authority, and on a failed register, so no waiter hangs on it.
	#nameCap: Promise<Ref | null> = Promise.resolve(null);
	// Callers parked in `introduceVia` waiting for a peer to offer them an inbox,
	// by the peer's lowercased nick. Fed by the register inbox's `introducible`.
	readonly #introducible = new Map<string, (() => void)[]>();
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
	}

	/** Dial `locator`, start serving, and fetch the directory by name. The caller
	 * supplies a dialer bound to the Runtime that owns its identity and transport
	 * composition. */
	static async connect(
		locator: string,
		dial: RoomsDial,
	): Promise<Directory> {
		const session = await dial(locator);
		// Start the inbound loop before fetching, so the fetch's resolution arrives.
		const serving = session.serve();
		// A Directory owns this promise and observes it at close. Attach a handler
		// now so a transport fault before then is not an unhandled rejection.
		void serving.catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
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
	open(name: string, isPrivate = false): Promise<Ref> {
		return ask(
			this.session,
			this.#directory,
			OPEN,
			isPrivate ? [name, true] : [name],
			`the directory did not answer opening "${name}"`,
		) as Promise<Ref>;
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

	/** The stable room sturdyref this directory minted. The peer half comes from
	 * the locator the caller actually used, preserving its authenticated route
	 * and current reachability hints; the server answers only the opaque swiss
	 * authority it owns. */
	async link(name: string, locator: string): Promise<string> {
		const swiss = await ask(
			this.session,
			this.#directory,
			LINK,
			[name],
			`the directory did not answer linking "${name}"`,
		);
		if (typeof swiss !== "string" || swiss.length === 0) {
			throw new Error(`link("${name}") did not return a swissnum`);
		}
		return formatSturdyRef(roomsLocator(locator), swiss, this.session.profile.captpVersion);
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
			this.#releaseLocal(observer);
			return parseRooms(raw);
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
		onMintInboxFor?: (peer: string) => void,
	): Promise<void> {
		return new Promise((resolve, reject) => {
			// The timeout is armed before `settle` exists because `settle` has to
			// clear it. Neither forward reference runs early: the callback below
			// is stored, not called, and the block finishes before any task can
			// fire it.
			const timer = setTimeout(
				() => settle(() => reject(new Error(`register("${nick}") was not acknowledged in time`))),
				REGISTER_ACK_TIMEOUT_MS,
			);
			const settle = (run: () => void) => {
				clearTimeout(timer);
				run();
			};
			const inbox = this.session.spawn((verb, args) => {
				if (verb !== NOTIFY) return null;
				const event = args[0];
				const peer = typeof args[1] === "string" ? args[1] : "";
				if (event === "registered") settle(resolve);
				else if (event === "mintInboxFor" && peer) onMintInboxFor?.(peer);
				else if (event === "introducible" && peer) this.#wakeIntroducible(peer);
				return null;
			});
			// A real reject edge: a dropped `send` (the directory session died
			// mid-register) and an ack that never arrives both surface as a failure
			// the caller can retry, instead of a promise that only ever resolves or
			// hangs — a hang would pin the caller out of the DM roster silently.
			//
			// The reply is the name capability: the holding of the granted name,
			// detached from this connection. Kept on the Directory because a later
			// subscribe on another connection proves itself with a voucher this
			// capability mints. A directory may grant no transferable name authority;
			// every voucher path then degrades to the refusal it already had.
			const sent = this.session.send(this.#directory, REGISTER, [nick, locator, inbox]);
			this.#nameCap = sent.then(
				(reply) => (reply instanceof Ref ? reply : null),
				() => null,
			);
			void sent.then(
				() => this.#releaseLocal(inbox),
				async (error) => {
					const primary = await retainCleanupFailures(error, [() => this.session.release(inbox)]);
					settle(() => reject(primary));
				},
			);
		});
	}

	/** A single-use proof that the caller holds this directory's registered
	 * name, for a `subscribe` arriving on another connection; null when this
	 * directory minted no name capability. Each voucher redeems once, and only
	 * while the registration stands. */
	async nameVoucher(): Promise<Uint8Array | null> {
		const nameCap = await this.#nameCap;
		if (nameCap === null) return null;
		const voucher = await ask(
			this.session,
			nameCap,
			VOUCHER,
			[],
			"the directory did not answer minting a name voucher",
		);
		return voucher instanceof Uint8Array ? voucher : null;
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
	async introduce(nick: string): Promise<Ref> {
		return (await this.introduceVia(nick)).dm;
	}

	/** Introduce us to a member, returning both the member's `dm` reference and
	 * the direct `Session` the redeem dialed to reach it (`via`). Hosting a reply
	 * inbox on `via` and sending the DM over `via` lets the member answer us back
	 * over that same connection — the bidirectional completion of the
	 * introduction, which is the only way a member can reach a caller (a browser,
	 * say) that cannot itself be dialed. `via` is null only if the reply named no
	 * fresh redeem. Requires a `register`, like `introduce`. Rejects if no member
	 * with that nick is registered. */
	async introduceVia(nick: string): Promise<{ dm: Ref; via: Session | null }> {
		try {
			return await this.#introduceOnce(nick);
		} catch (err) {
			if (roomErrorOf(err)?.code !== INTRODUCTION_PENDING) throw err;
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
			await this.#awaitIntroducible(nick, attempt === 0);
			try {
				return await this.#introduceOnce(nick);
			} catch (err) {
				if (roomErrorOf(err)?.code !== INTRODUCTION_PENDING) throw err;
			}
		}
		throw new RoomError(
			INTRODUCTION_PENDING,
			`"${nick}" did not offer an inbox for us`,
		);
	}

	async #introduceOnce(nick: string): Promise<{ dm: Ref; via: Session | null }> {
		// Named as this directory's redeem: the dial it raises may need signaling,
		// and only this side knows which directory is vouching for the peer.
		const { reply, via } = await redeemingThrough(
			this,
			() => this.session.sendRedeeming(this.#directory, INTRODUCE, [nick]),
		);
		if (!(reply instanceof Ref)) {
			throw new Error(`introduce("${nick}") did not return a capability`);
		}
		return { dm: reply, via };
	}

	#wakeIntroducible(peer: string): void {
		const key = peer.toLowerCase();
		const waiting = this.#introducible.get(key);
		this.#introducible.delete(key);
		// A list every waiter has timed out of is the same as no list: bank the
		// wakeup, or it reaches nobody and the next caller parks on a signal that
		// has already been sent.
		if (waiting === undefined || waiting.length === 0) {
			this.#introducibleSeen.add(key);
			return;
		}
		for (const wake of waiting) wake();
	}

	/** Wait for `nick` to offer us an inbox. `useBanked` spends a wakeup that
	 * arrived before this call; the retry pass passes false, so it waits for a
	 * fresh one. */
	#awaitIntroducible(nick: string, useBanked: boolean): Promise<void> {
		const key = nick.toLowerCase();
		if (useBanked && this.#introducibleSeen.delete(key)) return Promise.resolve();
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				const waiting = this.#introducible.get(key);
				if (waiting !== undefined) {
					const i = waiting.indexOf(wake);
					if (i >= 0) waiting.splice(i, 1);
					// Drop the row with its last waiter, or the map keeps one per peer
					// ever waited on for the session's life.
					if (waiting.length === 0) this.#introducible.delete(key);
				}
				reject(
					new RoomError(
						INTRODUCTION_PENDING,
						`"${nick}" did not offer an inbox for us in time`,
					),
				);
			}, INTRODUCIBLE_TIMEOUT_MS);
			const wake = () => {
				clearTimeout(timer);
				resolve();
			};
			const waiting = this.#introducible.get(key);
			if (waiting === undefined) this.#introducible.set(key, [wake]);
			else waiting.push(wake);
		});
	}

	/** Offer the directory an inbox for one named peer, the answer to a
	 * `mintInboxFor` request. */
	async offerInbox(forNick: string, inbox: Ref): Promise<void> {
		await ask(
			this.session,
			this.#directory,
			OFFER_INBOX,
			[forNick, inbox],
			`the directory did not answer offering an inbox for ${forNick}`,
		);
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
		const nameCap = await this.#nameCap.catch(() => null);
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
