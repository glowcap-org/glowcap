// The link of a page to its session: the one port every call over it goes
// through, the first sends it holds back while it is replaced, the dial that
// replaces it, and the move of what the page keeps onto each new link, one move
// at a time. A session this browser runs has no link to lose, so its port only
// stamps calls with the first link.
import { invariant } from "../../../../lib/invariant.ts";
import { connectionLost, LocalRefusal } from "../../../../lib/text/failure.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedObservation,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { LINK_WAIT_MS, type LinkClock, ManagedLink } from "./link.ts";
import { FIRST_LINK, type LinkPort, linkPort, type Stamp } from "./link_port.ts";
import { dialAgain, type DialedLink, type LinkOwners, resumeLink } from "./relink.ts";

/** What the link reads of the session that holds the handles it replaces. */
export interface LinkedSession {
	/** The workspace handle of the current link. */
	workspace(): RoomsManagedWorkspace;
	/** The observation registered over the current link, once start has. */
	observation(): RoomsManagedObservation | null;
	stopped(): boolean;
	changed(): void;
	/** Put `dialed`'s handles in place, making the link live with `live` in the
	 * same turn. A throw comes before anything is replaced. */
	install(dialed: DialedLink, live: () => void): void;
	report(source: string, error: unknown): void;
	/** Keep the session's close waiting until `job` ends. */
	track(job: Promise<void>): void;
}

export class SessionLink {
	/** The link to a session a process elsewhere runs, or null for a session
	 * this browser runs. */
	readonly link: ManagedLink | null;
	readonly port: LinkPort;
	readonly #application: RoomsManagedApplication;
	readonly #session: LinkedSession;
	readonly #owners: LinkOwners;
	/** The move of what the page keeps onto the newest link. */
	#moving: Promise<void> = Promise.resolve();
	readonly #listeners = new Set<() => void>();
	/** What a first send held back for a link threw, which is the link's. */
	readonly #heldBack = new WeakSet<object>();

	constructor(
		application: RoomsManagedApplication,
		session: LinkedSession,
		/** Read only once a link is replaced, so they may be built after this. */
		owners: LinkOwners,
		local: boolean,
		clock: LinkClock,
	) {
		this.#application = application;
		this.#session = session;
		this.#owners = owners;
		this.link = local ? null : new ManagedLink({
			dial: (live) => this.#dial(live),
			probe: () => this.#probe(),
			changed: () => session.changed(),
		}, clock);
		this.port = linkPort({
			// The link owns the generation, which stamps the handles in place.
			current: () => ({ workspace: session.workspace(), generation: this.link?.generation ?? FIRST_LINK }),
			lost: (error, stamp) => this.link?.lost(error, stamp),
			available: () => this.link?.available(null) ?? Promise.resolve(false),
			ready: (unsent) => this.#ready(unsent),
		});
	}
	/** Whether the link tells `error` in its own notice, so a surface that
	 * hears it says nothing more. */
	tells(error: unknown): boolean {
		return this.link != null && connectionLost(error);
	}
	/** Whether the link, not the session, ended a call that failed with
	 * `error`: its connection was lost, it was never sent, or it was held back
	 * while no link was live and the link's own refusal or bound ended it. Work
	 * such a failure ended runs again over a new link. */
	ended(error: unknown): boolean {
		return connectionLost(error) || LocalRefusal.is(error, "not-sent") ||
			(typeof error === "object" && error != null && this.#heldBack.has(error));
	}
	/** Hear that a new link replaced the last, once its handles are in place.
	 * This is for what lives outside the session object and cannot fail: what
	 * the session holds moves in the move's own order, under its owner's name. */
	onRelink(listener: () => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}
	/** Stop telling anyone of a new link, once the page has closed. */
	clear(): void {
		this.#listeners.clear();
	}
	/** Ask whether the current link still answers. Only the link reads the
	 * answer: a refusal the session answers with keeps the link, and the
	 * observation's own loop hears any failure of the observation itself. A
	 * live link is probed only once start has registered its observation, so
	 * a missing one is a broken invariant, thrown at once. */
	#probe(): Promise<unknown> {
		const observation = this.#session.observation();
		invariant(observation != null, "a live link is probed only after its observation is registered");
		return observation.poll();
	}
	/** Hold a first send while the link is being replaced, until the new link
	 * is live, for as long as recovery may take. A refusal the session answered
	 * says why, in its own words, and with none the bound says `unsent`. */
	async #ready(unsent: LocalRefusalKey): Promise<void> {
		const link = this.link;
		if (link == null || link.live) return;
		if (await link.available(LINK_WAIT_MS)) return;
		if (this.#session.stopped()) throw new LocalRefusal("session-closed");
		const refusal = link.refusal ?? new LocalRefusal(unsent);
		if (typeof refusal === "object" && refusal != null) this.#heldBack.add(refusal);
		throw refusal;
	}
	/** Dial the session again. The page's handles change nothing until the new
	 * link has answered, so a failed dial leaves what the page shows as it was.
	 * The application closes the lost connection before it dials. The dial
	 * ends once the new handles are in place, which makes the link live, and the
	 * rest of the move follows as work of the link's own owners. */
	#dial(live: () => void): Promise<void> {
		const session = this.#session;
		return dialAgain(this.#application, session.workspace(), () => session.stopped(), (dialed) => {
			session.install(dialed, live);
			this.#move(this.port.current());
		});
	}
	/** Move what the page keeps onto the link `stamp` names. One move runs at a
	 * time. A move for a link already replaced ends at its next step, and the
	 * one after it moves what the newest link holds. */
	#move(stamp: Stamp): void {
		const session = this.#session;
		const moved = this.#moving.then(() =>
			resumeLink(this.#owners, {
				current: () => !session.stopped() && this.port.isCurrent(stamp),
				probe: () => {
					if (this.port.isCurrent(stamp)) this.link?.probeIfSeen();
				},
				report: (source, error) => session.report(source, error),
				listeners: this.#listeners,
			})
		);
		this.#moving = moved.catch(() => {
			// tolerant: each step reports its own failure.
		});
		session.track(moved);
	}
}
