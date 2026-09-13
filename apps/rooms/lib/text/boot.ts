// The opening screen: what a reader is told while the page builds its peer.
//
// Two lines that are not the same kind of thing. The note is the truth about
// the wait and names whichever step is actually happening, because it is the
// only thing on screen a reader can use to tell a slow network from a stuck
// page. The aside under it is for the reader still here after a few seconds;
// it is decorative, hidden from assistive software, and stops the moment there
// is a real reason the screen is still up.
//
// Written for a guest: none of these sentences asks a reader to know anything
// about OCapN, and the asides are where the product's one surprising fact —
// that this page is the peer, and nothing is logging you in — gets said in
// passing rather than taught.

/** What the page is doing, in the order it does it. `code` is page.html's own
 * word, already on screen before the bundle exists. */
export type BootPhase = "peer" | "session" | "rooms";

/** The phase line. Load-bearing: a reader distinguishes a slow network from a
 * stuck page by watching this change. */
export const bootNote: Readonly<Record<BootPhase, string>> = {
	peer: "Starting Rooms in this browser…",
	session: "Reaching the session that keeps your rooms…",
	rooms: "Looking for the rooms you were in…",
};

/** Dry, short, and true. A reader gets at most a few of these, so none of them
 * is load-bearing and none is a promise.
 *
 * Whimsy is fine here and a boast is not, and the line between them is whether
 * the reader is being told something or sold something. "Lighting the lantern"
 * claims nothing. "Your rooms are capabilities you hold, not rows in a table"
 * was an advertisement wearing a loading screen, and it opened on a contrast
 * with a product nobody mentioned. */
export const bootAsides: readonly string[] = [
	"Lighting the lantern.",
	"You get in with a link rather than an account.",
	"You can hand a room to somebody with a link.",
	"The server doesn't read your direct messages.",
	"Fruiting.",
];

/** The note line once the wait has a reason. The reason itself arrives from
 * the caller and is shown under this, so this sentence says only that the
 * screen is being patient on purpose. */
export const bootStillOpening = "Still opening. The server may still be building this page…";
