// What a test says to the fakes of a page holding management access, and what
// they keep for it to read back: the plan each fake answers from, and the
// ledger of every handle they make. `held_access_fakes.ts` answers from these,
// and `held_access_page.ts` holds them on the page.
import { browserFailure } from "./browser_failure.ts";
import { bindingHandle } from "./managed_link.ts";

/** Every handle the fakes make, how often each was freed, and each call made
 * on one after its free. */
export class Ledger {
	readonly #frees = new Map<string, number>();
	readonly #made = new Map<string, number>();
	readonly misuse: string[] = [];
	/** A handle labelled `name` and its number among the handles of that name. */
	handle(name: string, fields: Record<string, unknown>) {
		const number = (this.#made.get(name) ?? 0) + 1;
		this.#made.set(name, number);
		const label = `${name} ${number}`;
		this.#frees.set(label, 0);
		const members = {
			...fields,
			name: label,
			free: () => this.#frees.set(label, (this.#frees.get(label) ?? 0) + 1),
		};
		return bindingHandle(members, (member) => this.misuse.push(`${label}.${member}`));
	}
	/** How many handles named `name` the fakes made. */
	made(name: string): number {
		return this.#made.get(name) ?? 0;
	}
	/** Whether the handle labelled `label` was freed. */
	freed(label: string): boolean {
		return (this.#frees.get(label) ?? 0) > 0;
	}
	/** Each handle not freed exactly once, with its count. */
	wrong(): string[] {
		return [...this.#frees].filter(([, count]) => count !== 1).map(([label, count]) => `${label} freed ${count}`);
	}
}

/** A failure asking again can clear, as a session that did not answer in time. */
export const timedOut = () => browserFailure(null, "no answer in time", "session-request-timed-out");
/** A failure that will not change, as a saved access the session no longer has. */
export const gone = () => browserFailure(-12, "the saved access is gone", "session-capability-gone");
/** A saved source whose session waits for a transport this browser cannot use. */
export const noTransport = () => browserFailure(null, "no transport", "saved-transport-unavailable");

/** The controls the page holds: a saved access (the source of a share), the
 * new access a share made, the page's own access, and an access attached from
 * another session. */
export type Held = "source" | "made" | "own" | "attached";
/** The link the attached access comes from. */
export const attachedLink = "ocapn://attached";

/** A connection to the session: the one a link of the page opened, or a held
 * control's own. Every handle made over it fails once it drops, as the
 * binding's handles over a closed session do. */
export interface Connection {
	dead: boolean;
}
/** One call the fakes hold open: the `at`th from when it is armed. */
export interface Park {
	readonly at: number;
	count: number;
	readonly hit: PromiseWithResolvers<void>;
	readonly release: PromiseWithResolvers<void>;
}
/** How a failed restore of the page's own access or the attached one fails:
 * its connection lost, gone for good, or not answered in time. */
export type RestoreFailure = "unreached" | "gone" | "timed out";

export interface Plan {
	/** How the next send of a share answers. An unconfirmed send is answered
	 * next time. */
	answer: "committed" | "uncertain" | "conflict" | "refused";
	/** The link of each new access a share made. */
	accessLink: string;
	/** How the next new access the session returns reads. */
	read: "ok" | "transient" | "final" | "lost";
	/** How many times a new access was read. */
	reads: number;
	/** How many times a share was sent, and how many of them went through a
	 * request the session resumed after its link moved. */
	sends: number;
	replays: number;
	/** Whether the next resumed request loses its connection when sent. */
	replayFails: boolean;
	/** How the session answers the next saves of an access, once set. */
	save: Promise<unknown> | null;
	/** How the session answers the next forgets of a saved access, once set. */
	forget: Promise<unknown> | null;
	/** The access rows this browser's storage holds a control in: the source
	 * the page opens with, and each access whose save commits. Saving one
	 * prepares nothing, and forgetting one prepares the release of its row. */
	savedRows: Set<string>;
	/** Whether the source's own connection is lost. */
	sourceLost: boolean;
	/** Whether the next narrower control made loses the connection of the
	 * control it was made from before its link is read. */
	narrowerLost: boolean;
	/** Whether the session has dropped its answers to the narrower controls
	 * made so far, as one whose receipt window moved past them does, so a
	 * resent request is refused. */
	narrowerExpired: boolean;
	/** Whether the next read of a source times out. */
	sourceRead: "ok" | "transient";
	/** Whether a source may list the accesses made from it. */
	inspect: boolean;
	/** Whether a source may make a narrower control for someone else. */
	delegates: boolean;
	/** How many pages of accesses made from a held control were asked for. */
	listings: number;
	/** How the next page asked for fails, once set: refused in time, or with a
	 * fault no refusal names. */
	listingFails: "refused" | "fault" | null;
	/** How the next restores of the source answer. Each is used once. */
	sources: (() => Promise<unknown>)[];
	/** How many times the page dialed a saved control. */
	dials: number;
	/** Which held control's next read or call outside a turn finds its own
	 * connection lost. */
	cut: Held | null;
	park: Park | null;
	/** How the next send of an edit answers. A lost reply drops the
	 * connection of the access it went through. */
	edit: "committed" | "uncertain" | "conflict" | "refused" | "lost";
	/** How many times an edit was sent. */
	editSends: number;
	/** The revision every access reads as now. A committed edit, or the change
	 * behind a conflict, moves it on, and an edit prepared at an older one
	 * conflicts. */
	revision: number;
	/** Whether the next edit prepared fails to prepare, for a failure other
	 * than a lost connection. */
	prepareFails: boolean;
	/** Whether the next resume of an edit onto a new handle fails. */
	resumeFails: boolean;
	/** How the next restore of the page's own access or the attached one
	 * fails, once set. */
	restore: Partial<Record<"own" | "attached", RestoreFailure>>;
}
/** A plan whose every call answers at once and well. */
export function plan(): Plan {
	return {
		answer: "committed",
		accessLink: "the access link",
		read: "ok",
		reads: 0,
		sends: 0,
		replays: 0,
		replayFails: false,
		save: null,
		forget: null,
		savedRows: new Set(["source"]),
		sourceLost: false,
		narrowerLost: false,
		narrowerExpired: false,
		sourceRead: "ok",
		inspect: false,
		delegates: false,
		listings: 0,
		listingFails: null,
		sources: [],
		dials: 0,
		cut: null,
		park: null,
		edit: "committed",
		editSends: 0,
		revision: 1,
		prepareFails: false,
		resumeFails: false,
		restore: {},
	};
}
