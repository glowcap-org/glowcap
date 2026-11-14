// Who is typing, the rule that clears it, and the level a composer sends.
//
// One answer for rooms and direct lines alike, because the flag is the same
// promise either way: somebody is about to say something. A peer that goes
// quiet without sending the "off" is ordinary (a closed tab, a dropped
// connection) so nothing here trusts the far side to end what it started, and
// every flag carries its own expiry.

import * as store from "./store.ts";
import { type Conv, conversationCarries, silencedFrom } from "./conversation.ts";
import { TYPING_CLEAR_MS, TYPING_IDLE_MS, TYPING_RENEW_MS } from "./limits.ts";
import type { RoomsPageContext } from "./page.ts";

/** The clock a typing signal waits on. `after` answers the way to call it off. */
interface TypingClock {
	after(ms: number, run: () => void): () => void;
}

const timers: TypingClock = {
	after(ms, run) {
		const timer = setTimeout(run, ms);
		return () => clearTimeout(timer);
	},
};

/** One composer's typing level, as one conversation hears it.
 *
 * The level goes on at a keystroke and off when the member sends, pauses for
 * `TYPING_IDLE_MS`, or leaves. A draft that changes with no keystroke, kept
 * from earlier or put back after a refused send, is not typing. While the
 * level stays on it is said again every `TYPING_RENEW_MS`, because a reader
 * clears a flag nobody renewed. The renewal runs on the clock and not on a
 * keystroke, so it arrives before a reader's wait ends however the member's
 * keystrokes fall. */
class TypingSignal {
	readonly #send: (on: boolean) => void;
	readonly #clock: TypingClock;
	#on = false;
	#idle: (() => void) | null = null;
	#renewal: (() => void) | null = null;

	constructor(send: (on: boolean) => void, clock: TypingClock) {
		this.#send = send;
		this.#clock = clock;
	}

	note(typing: boolean, keystroke: boolean): void {
		if (typing && !keystroke) return;
		this.#idle?.();
		this.#idle = null;
		if (typing !== this.#on) this.#tell(typing);
		if (typing) this.#idle = this.#clock.after(TYPING_IDLE_MS, () => this.#tell(false));
	}

	/** The composer left this conversation. A level still on is owed its stop. */
	close(): void {
		this.note(false, false);
	}

	#tell(on: boolean): void {
		this.#renewal?.();
		this.#renewal = null;
		this.#on = on;
		this.#send(on);
		if (on) this.#renewal = this.#clock.after(TYPING_RENEW_MS, () => this.#tell(true));
	}
}

/** Whether a composer may say its member is typing in `conv`: it holds the
 * caret and a draft, the conversation hears typing, and a direct line is up.
 * Changing a line already said is not typing, because no line follows it. */
export function composerSpeaks(
	conv: Conv | null,
	composer: { enabled: boolean; focused: boolean; changing: number | undefined; draft: string },
): boolean {
	return composer.enabled && composer.focused && conv !== null && (conv.type !== "dm" || conv.line === "live") &&
		composer.changing === undefined && composer.draft.trim() !== "" && conversationCarries(conv, "typing");
}

/** A composer's typing across the conversations it shows, one signal each.
 * A stop names the conversation that heard the start, whichever one is on
 * screen when it is sent. */
export class ComposerTyping {
	readonly #send: (conversation: string, on: boolean) => void;
	readonly #clock: TypingClock;
	#conversation: string | null = null;
	#signal: TypingSignal | null = null;

	constructor(send: (conversation: string, on: boolean) => void, clock: TypingClock = timers) {
		this.#send = send;
		this.#clock = clock;
	}

	/** What the composer shows now. `typing` says whether it may speak for
	 * the draft: focused, with text, in a conversation that hears typing.
	 * `keystroke` says the member just edited that draft. */
	note(conversation: string | null, typing: boolean, keystroke: boolean): void {
		if (conversation !== this.#conversation) {
			this.close();
			this.#conversation = conversation;
			if (conversation != null) {
				this.#signal = new TypingSignal((on) => this.#send(conversation, on), this.#clock);
			}
		}
		this.#signal?.note(typing, keystroke);
	}

	/** The composer is gone, or showing another conversation. */
	close(): void {
		this.#signal?.close();
		this.#signal = null;
		this.#conversation = null;
	}
}

/** Auto-clear timers for peer typing flags, one per (conversation, peer). */
export class PageTyping {
	readonly timers = new Map<string, ReturnType<typeof setTimeout>>();
}

export function applyTyping(page: RoomsPageContext, key: string, from: string, on: boolean): void {
	// The one indicator that was left outside the ignore authority: "bob is
	// typing…" over a log that will refuse bob's line promises a message that
	// never comes, again every time he types. A clear still applies, so a flag
	// set just before the ignore cannot linger.
	if (on && silencedFrom(from, false, page.projection.get().ignored)) return;
	const timerKey = `${key}\u0000${from}`;
	const running = page.typing.timers.get(timerKey);
	if (running) clearTimeout(running);
	if (on) {
		page.typing.timers.set(
			timerKey,
			setTimeout(() => {
				page.typing.timers.delete(timerKey);
				store.setTyper(page.projection, key, from, false);
			}, TYPING_CLEAR_MS),
		);
	} else page.typing.timers.delete(timerKey);
	store.setTyper(page.projection, key, from, on);
}
