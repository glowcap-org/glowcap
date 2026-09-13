// The session chooser: the first screen a browser holding nothing meets, and
// the two acts under it that take saved state away.
//
// A session is where this browser's rooms, messages and settings live. The
// word is the one piece of protocol vocabulary on this screen that is also an
// ordinary English word, so it stands without apposition; everything else on
// the screen is named for what it does.

export const sessionSetupTitle = "Choose a session";
export const sessionSetupLead =
	"Your rooms, messages and settings live in a session. Pick where this browser keeps its session.";

export const sessionLocalTitle = "This browser";
/** "Nothing leaves it" was the row's old promise and it was not true: what you
 * say in a room goes to the server like any chat app, and a reader choosing on
 * that sentence is choosing on a privacy claim nothing here makes. What is
 * actually local is the session, so the row says that and names the cost of
 * keeping it here, which is the reason somebody would pick the other door. */
export const sessionLocalHint =
	"Your session stays in this browser. Clear the browser and it's gone, and there's no copy anywhere else.";
export const sessionLocalCommit = "Use this browser";

export const sessionSharedTitle = "Shared session";
/** "the capability it printed" was the protocol's word for a thing the reader
 * is holding in their clipboard as a link. The act is pasting a link; the fact
 * that a link is a capability is true, interesting, and not what this row is
 * for. */
export const sessionSharedHint =
	"Use a session another device or a server is already keeping. Paste the link it gave you.";
/** Named for what a reader is pasting rather than for what it is. The
 * apposition is on the field's own hint, where somebody matching it against a
 * printed capability will be looking. */
export const sessionSharedFieldLabel = "Session link";
export const sessionSharedFieldHint = "The ocapn:// link the other device or server printed.";
export const sessionSharedCommit = "Attach";

/** The door that is drawn shut. It states a boundary rather than offering a
 * control that would refuse, so the shape of the choice is already the shape
 * it will have. */
export const sessionSignInTitle = "Sign in";
export const sessionSignInHint =
	"Keep your session on a server and sign in from any device, instead of carrying a link around.";
export const sessionSignInState = "Coming soon";

/** The advanced fold, and the two confirmations under it. Each confirmation
 * names what survives as well as what goes, because "delete" with no boundary
 * reads as "delete everything, everywhere". */
export const sessionAdvanced = "Advanced";
export const sessionResetAsk = "Reset workspace…";
export const sessionDeleteAsk = "Delete browser data…";
export const sessionChangeLabel = "Change saved browser data";
/** Both name their contents rather than saying "workspace", which is a word
 * the control uses and the reader has never been given. The pair differ in one
 * thing and it is the thing that matters: the first keeps your messages and
 * the second does not. */
export const sessionResetSay =
	"Forget the rooms and settings saved in this browser and start again from this screen? Your saved messages stay.";
export const sessionDeleteSay =
	"Delete everything saved in this browser: rooms, settings, saved links and messages. Anything kept on another device or server stays.";
export const sessionConfirmKeep = "Keep it";
export const sessionResetCommit = "Reset workspace";
export const sessionDeleteCommit = "Delete browser data";
