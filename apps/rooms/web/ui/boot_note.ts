// What the opening screen says while it is up.
//
// Two lines, and they are not the same kind of thing. The note is the truth
// about the wait: this page runs a peer, and building one is not the same wait
// as reaching a room server, so the line names whichever is actually
// happening. Nothing decorative goes in it, because it is the only thing on
// screen a reader can use to tell a slow network from a stuck page.
//
// The aside underneath is the other thing. A reader who is still here after a
// few seconds is owed something to read, so they get one, and it is marked
// hidden from assistive software: the note already carries everything that
// matters, and a line that changes every few seconds is noise to anything
// reading the page aloud. Each aside is true, because a loading screen is a
// poor place to start lying, and none of them is a claim the reader has to
// act on.
//
// The moment there is a real reason the screen is still up, the asides stop.
// A joke beside a fault report is the wrong register, and the fault is the
// thing to read.

/** What the page is doing, in the order it does it. `code` is page.html's own
 * word, already on screen before this module exists. */
export type BootPhase = "peer" | "session" | "rooms";

const NOTES: Readonly<Record<BootPhase, string>> = {
	peer: "Opening a peer in this browser…",
	session: "Reaching the session that keeps your rooms…",
	rooms: "Looking for the rooms you were in…",
};

/** Dry, short, and true. A reader gets at most a few of these, so none of them
 * is load-bearing and none is a promise. */
const ASIDES: readonly string[] = [
	"Warming the griddle.",
	"This page is the peer. Nothing is logging you in.",
	"No account, no password. Just the link you kept.",
	"Your rooms are capabilities you hold, not rows in a table.",
	"A room you hold is a room you can hand to somebody.",
	"Direct messages go direct. The room never sees them.",
	"Stacking.",
];

/** Long enough that an ordinary load never shows one. */
const FIRST_ASIDE_MS = 2_500;
const NEXT_ASIDE_MS = 4_000;

let timer: ReturnType<typeof setTimeout> | undefined;
let showing = 0;

function note(): HTMLElement | null {
	return document.querySelector("#boot .boot-note");
}

function aside(): HTMLElement | null {
	return document.querySelector("#boot .boot-aside");
}

/** Say which wait this is.
 *
 * Moving on retires the reason the last wait gave for taking so long. It
 * belonged to a wait that has now ended, and leaving it under a line about the
 * next one reads as a fault in that one. */
export function noteBootPhase(phase: BootPhase): void {
	const line = note();
	if (line !== null) line.textContent = NOTES[phase];
	document.querySelector("#boot .boot-why")?.remove();
}

/** Begin the asides. Calling this more than once is how a phase change keeps
 * the rotation running rather than restarting it. */
export function startBootAsides(): void {
	if (timer !== undefined || aside() === null) return;
	// A reader who asked for less motion gets one aside and no rotation: the
	// point is something to read, not something to watch change.
	const still = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
	showing = Math.floor(Math.random() * ASIDES.length);
	const tick = () => {
		const line = aside();
		if (line === null) return;
		line.textContent = ASIDES[showing % ASIDES.length];
		showing += 1;
		timer = still ? undefined : setTimeout(tick, NEXT_ASIDE_MS);
	};
	timer = setTimeout(tick, FIRST_ASIDE_MS);
}

/** Stop them, and take the last one off the screen. Called when the screen is
 * handed over and when there is a fault to report instead. */
export function stopBootAsides(): void {
	clearTimeout(timer);
	timer = undefined;
	const line = aside();
	if (line !== null) line.textContent = "";
}

/** Say on the opening screen why it is still up. The screen is page.html's own
 * markup, so this speaks to it directly: the note line turns patient, and one
 * detail line carries the newest reason. Recovery needs no undoing, because
 * the screen comes down through the ordinary handoff once the peer answers. */
export function noteBootDelay(why: string): void {
	stopBootAsides();
	const line = note();
	if (line !== null) {
		line.textContent = "Still opening. The server may be rebuilding this page's runtime…";
	}
	const wait = document.querySelector("#boot .boot-wait");
	if (wait === null) return;
	let detail = wait.querySelector(".boot-why");
	if (detail === null) {
		detail = document.createElement("p");
		detail.className = "boot-why";
		wait.append(detail);
	}
	detail.textContent = why;
}
