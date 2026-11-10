// The session chooser: the first screen a browser holding nothing meets, and
// the two acts under it that take saved state away.
//
// A session is where this browser's rooms, messages and settings live. It is
// the one protocol term on this screen that is also an ordinary English word,
// so it stands without explanation. Everything else is named for what it does.

import { serverUnreachable } from "./failure.ts";

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

/** The Rooms server line under the session choices. It is how this browser is
 * reached, so setup names it before anything opens. */
export const sessionServerName = "Rooms server";
export const sessionServerNone = "None yet. You need one to reach some addresses and to share links to this browser.";
export const sessionServerChoose = "Choose…";
/** The server dialog over setup. Nothing has opened, so saving keeps the
 * choice in place. Opened by Attach, it says why, and saving attaches. */
export const sessionServerTitle = "Choose a Rooms server";
/** What a Rooms server is, said once and composed into every dialog that
 * asks for one. */
export const serverModel =
	"A Rooms server is how this browser reaches addresses it can't open on its own, and how people reach it.";
export const sessionServerLead = `${serverModel} Test its address, then save it.`;
/** What an act needs a Rooms server for, said first in every ask. An address
 * or link is judged by its doors: one this browser opens itself needs no
 * server, and one it cannot open does. A link that leads to this browser, and
 * a direct message through the server, need the server because that is where
 * other people reach this browser. */
export const serverNeedAddress = "This browser can't reach this address on its own. A Rooms server can.";
export const serverNeedHome = "A blank address, or a name alone, means the home directory of the page's Rooms server.";
export const serverNeedLink = "A link to this browser works through its Rooms server.";
export const serverNeedDm = "Direct messages are set to go through the Rooms server.";
export const sessionServerAttachLead = `${serverNeedAddress} Test a server's address, and saving it attaches.`;
export const sessionServerSave = "Save";
export const sessionServerSaveAttach = "Save and attach";
/** A session act that broke on the way, while this browser has a Rooms
 * server to go through: that server is the likeliest cause. */
export const sessionServerUnreachable = (host: string, detail: string) =>
	serverUnreachable(host, "Check that it is running, or change it.", detail);
/** The same dialog in the open workspace, opened by an act that needs a
 * Rooms server when the page has none: `need` is one of the needs above. The
 * session keeps its server, so saving reloads, and the act is waiting on the
 * other side. */
const serverAskHow = "Test a server's address, then save it to reload where you left off.";
export const serverAskFor = (need: string) => `${need} This page has none. ${serverAskHow}`;
/** The same ask after the door this browser opens by itself did not get
 * through: `door` says so, and a Rooms server is the other way in. */
export const serverAskAfterDoor = (door: string) => `${door} A Rooms server can reach it another way. ${serverAskHow}`;
/** The same ask after a direct line to `peer` found no route on a page with
 * no server: a route through a server is the other way to that person. */
export const serverAskAfterDirect = (peer: string) =>
	`No direct route to ${peer} opened from this browser. A Rooms server gives this browser another way to reach them. ${serverAskHow}`;

/** The advanced section and the two confirmations under it. Each
 * confirmation names what survives as well as what goes, since "delete" alone
 * reads as "delete everything, everywhere". */
export const sessionAdvanced = "Advanced";
export const sessionResetAsk = "Forget rooms and settings…";
export const sessionDeleteAsk = "Delete browser data…";
export const sessionChangeLabel = "Change saved browser data";
/** Both name their contents instead of a collective noun the reader has
 * never been given. They differ in one way: the first keeps your messages
 * and the second does not. They read as a pair of questions. */
export const sessionResetSay =
	"Forget the rooms and settings saved in this browser and start again from this screen? Your saved messages stay.";
export const sessionDeleteSay =
	"Delete everything this page saved in this browser: sessions, messages, saved links, your preferences, and the theme this site's pages share? Anything kept on another device or server stays.";
export const sessionConfirmKeep = "Keep it";
export const sessionResetCommit = "Forget rooms and settings";
export const sessionDeleteCommit = "Delete browser data";
