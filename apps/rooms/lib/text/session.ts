// The session chooser: the first screen a browser holding nothing meets, and
import { serverUnreachable } from "./failure.ts";
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
/** Said when the page could not open its session for a reason Rooms cannot
 * name. The browser console holds the cause, and the one act under it says
 * what to do. */
export const sessionDidNotOpen = "Something stopped this session from starting. The browser console has the details.";
/** The act under that notice on a page that has chosen no session. */
export const bootReload = "Reload";

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

/** The Rooms server line under the session choices. A shared session and every
 * directory are reached through it, so setup names it before anything opens. */
export const sessionServerName = "Rooms server";
export const sessionServerNone = "None. A shared session and directories need one.";
export const sessionServerChoose = "Choose…";
/** The server dialog over setup. Nothing has opened, so saving keeps the
 * choice in place. Opened by Attach, it says why, and saving attaches. */
export const sessionServerTitle = "Choose a Rooms server";
export const sessionServerLead =
	"Rooms reaches shared sessions and directories through one server. Test its address, then save it.";
export const sessionServerAttachLead =
	"A shared session is reached through a Rooms server, and this page has none. Test a server's address, and saving it attaches.";
export const sessionServerSave = "Save";
export const sessionServerSaveAttach = "Save and attach";
/** A session act that broke on the way, while this browser has a Rooms
 * server to go through: that server is the likeliest cause. */
export const sessionServerUnreachable = (host: string, detail: string) =>
	serverUnreachable(host, "Check that it is running, or change it.", detail);
/** The same dialog in the open workspace, opened by an act that reaches
 * through a Rooms server when the page has none. The session keeps its
 * server, so saving reloads, and the act is waiting on the other side. */
export const serverAskLead =
	"Rooms reaches directories, rooms, and people through a Rooms server, and this page has none. Test a server's address, and saving it reloads the page where you left off.";

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
