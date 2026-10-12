// The opening screen: what a reader is told while the page builds its peer.
//
// Two lines of different kinds. The note names the step that is happening,
// because it is the only thing on screen a reader can use to tell a slow
// network from a stuck page. The aside under it is for the reader still here
// after a few seconds. It is decorative, hidden from assistive software, and
// stops as soon as there is a real reason the screen is still up.
//
// Written for a guest: none of these sentences asks a reader to know anything
// about OCapN. The asides mention in passing that this page is the peer and
// nothing is logging you in.

/** What the page is doing, in the order it does it. */
export type BootPhase = "peer" | "session" | "rooms";

/** The phase line. A reader tells a slow network from a stuck page by
 * watching it change. */
export const bootNote: Readonly<Record<BootPhase, string>> = {
	peer: "Starting Rooms in this browser…",
	session: "Reaching the session that keeps your rooms…",
	rooms: "Looking for the rooms you were in…",
};

/** Short and true. A reader sees at most a few of these, and none is a
 * promise. Whimsy is fine and a boast is not: the line is whether the reader
 * is being told something or sold something. */
export const bootAsides: readonly string[] = [
	"Lighting the lantern.",
	"You get in with a link rather than an account.",
	"You can hand a room to somebody with a link.",
	"The server doesn't read your direct messages.",
	"Fruiting.",
];

/** The note line once the wait has a reason. The caller shows the reason
 * under this line. */
export const bootStillOpening = "Still opening. The server may still be building this page…";
