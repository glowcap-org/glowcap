// The session chooser: the first screen a browser holding nothing meets, and
// the two acts under it that take saved state away.
//
// A session is where this browser's rooms, messages and settings live. It is
// the one protocol term on this screen that is also an ordinary English word,
// so it stands without explanation. Everything else is named for what it does.

export const sessionSetupTitle = "Choose a session";
export const sessionSetupLead =
	"Your rooms, messages and settings live in a session. Pick where this browser keeps its session.";

export const sessionLocalTitle = "This browser";
/** What is local is the session, not what you say. Messages in a room go to
 * the server like any chat app, so the row makes no privacy claim. It names
 * the cost of keeping the session here, which is the reason to pick the other
 * option. */
export const sessionLocalHint =
	"Your session stays in this browser. Clear the browser and it's gone, and there's no copy anywhere else.";
export const sessionLocalCommit = "Use this browser";

export const sessionSharedTitle = "Shared session";
/** The reader pastes a link. That the link is a capability is true but not
 * what this row is for. */
export const sessionSharedHint =
	"Use a session another device or a server is already keeping. Paste the link it gave you.";
/** Named for what a reader pastes. The hint explains the form, for somebody
 * matching it against a printed capability. */
export const sessionSharedFieldLabel = "Session link";
export const sessionSharedFieldHint = "The ocapn:// link the other device or server printed.";
export const sessionSharedCommit = "Attach";

/** The option that is drawn shut. It shows the choice that will exist
 * instead of offering a control that would refuse. */
export const sessionSignInTitle = "Sign in";
export const sessionSignInHint =
	"Keep your session on a server and sign in from any device, instead of carrying a link around.";
export const sessionSignInState = "Not available";

/** The advanced section and the two confirmations under it. Each
 * confirmation names what survives as well as what goes, since "delete" alone
 * reads as "delete everything, everywhere". */
export const sessionAdvanced = "Advanced";
export const sessionResetAsk = "Reset workspace…";
export const sessionDeleteAsk = "Delete browser data…";
export const sessionChangeLabel = "Change saved browser data";
/** Both name their contents instead of saying "workspace", a word the reader
 * has never been given. They differ in one way: the first keeps your messages
 * and the second does not. */
export const sessionResetSay =
	"Forget the rooms and settings saved in this browser and start again from this screen? Your saved messages stay.";
export const sessionDeleteSay =
	"Delete everything saved in this browser: rooms, settings, saved links and messages. Anything kept on another device or server stays.";
export const sessionConfirmKeep = "Keep it";
export const sessionResetCommit = "Reset workspace";
export const sessionDeleteCommit = "Delete browser data";
