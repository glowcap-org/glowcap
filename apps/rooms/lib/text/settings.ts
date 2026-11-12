// Settings: what is kept, what is shared, and how to get a room back.
//
// Mostly operator-adjacent, so these stay precise. The subject is whoever is
// reading, not the machinery.

import { browserBlocks } from "./failure.ts";
import { historyReadAgain, historyTitle, sessionSettingsLocation } from "./session_settings.ts";
import { serverModel, serverNeedDm } from "./session.ts";

/** Session message retention and the archive capability it selects. */
export const historyOffSession =
	"New messages aren't saved. They show up in whatever windows are open, and are gone after that.";
export const historyOnSession = "Messages are saved in this session.";
/** Said beside the switch, to a reader who can use it. */
export const historyOnSessionOff = "Turn this off and new ones stop being saved.";

export const historyKeepLabel = "Keep message history";
export const historyArchivePeerLabel = "Archive peer link";
export const historyArchivePeerTitle = "Archive peer";
export const historyBuiltInSession = "Built-in session archive";
export const historyPeerUnavailable =
	`That archive can't be reached. When it returns, choose ${historyReadAgain} under ${historyTitle} in ${sessionSettingsLocation}.`;
export const historyPeerDurable = "Connected. Its saved link lets this session reconnect on its own.";
export const historyPeerSaved = "Saved";
export const historyPeerLead =
	"A link that can read and write the archive. A new one starts keeping messages from now on, and doesn't copy what's already there.";

/** Getting back into a room a saved session remembers. The private case
 * needs care: a name is not enough, and rejoining a public room by name can
 * land somewhere else. */
export const recoveryPrivateNeedsLink = "This private room needs a current link. The name on its own won't find it.";
export const recoveryPrivateRetry = "Retry the saved link for this private room, or paste a current one.";
export const recoveryLinkRevoked =
	"The saved link was revoked. Rejoining by name may reach a different room that uses the name now.";
export const recoveryPublicRetry = "Retry joining this public room by name.";
export const recoveryLinkLabel = "Current room link";

/** Saving, and how it can fail. */
export const settingsConnectionRefused = "Rooms couldn't save the connection choice. Try again in a moment.";

export const settingsCopyDirectory = "Copy the directory address";
export const settingsCopyServer = "Copy the server address";
export const settingsShareDirectory = "Lets anyone join this server's rooms by name.";
/** The Rooms server this browser is reached through, chosen on this device. */
export const serverOfferTitle = "Use this Rooms server?";
export const serverOfferSay = (host: string, local: boolean) =>
	`This link asks Rooms to use the server at ${host}. People reach this browser through it, and it fetches link previews. Use it only if you started it or trust whoever runs it. Change it later in Settings, under Connection.${
		local
			? " Your browser may first ask to let this page reach a server on your computer or network. Allow it."
			: ""
	}`;
export const serverOfferKeep = "Not now";
export const serverOfferCommit = "Use this server";
/** The server field's hint. A page from a static host has no server of its
 * own to fall back to, so a blank field means none. What a server must allow
 * is said where it matters: by Test, and by the card while it refuses. */
export const settingsServerHint = (served: boolean) =>
	served
		? "Paste another Rooms server's address, or leave it blank to use the server this page came from."
		: "As you would open it in a browser.";
export const settingsServerExample = "https://rooms.example/";
/** The trouble row's source for a link's server offer the page could not read. */
export const settingsServerOffer = "Server offer";
export const settingsServerRefused =
	"A Rooms server address starts with http:// or https://, ends with /, and has no ? or # in it.";
/** Said while the relay this browser is reached through turns it away. A
 * browser sees only a closed socket, so both causes are named. */
export const settingsRelayAway = (host: string, origin: string) =>
	`People can't reach this browser right now. The Rooms server at ${host} isn't answering, or doesn't allow pages from ${origin}. Rooms keeps trying.`;

/** How other people's direct lines reach this browser. Every route is
 * encrypted end to end, so the choice is about the path and who can start a
 * line, not about who can read it. The radios are only drawn with a Rooms
 * server, since without one browser to browser is the one route the page
 * has. Fastest is the default, and the mark beside it says so. */
export const settingsDmFastestLabel = "Fastest";
export const settingsDmDefault = "Default";
export const settingsDmFastestSaid =
	"Tries both routes at once and uses the first that opens, often the server. Someone on another app can write to you first.";
export const settingsDmDirectLabel = "Browser to browser";
export const settingsDmDirectSaid =
	"Tries a direct route first and uses the server only if none opens. Someone on another app can reply only after you write first.";
export const settingsDmRelayLabel = "Through the server";
export const settingsDmRelaySaid = "Always through the server. Someone on another app can write to you first.";
export const settingsDmEncrypted = "Every route is encrypted end to end.";
/** The page with no Rooms server: the one route it has, and what a server adds. */
export const settingsDmNoServer =
	"With no Rooms server, direct messages go browser to browser. Adding a server above gives them a second route and lets someone on another app write to you first.";
/** The saved choice is shown as it is while the page has no Rooms server,
 * with one act that moves to the default. */
export const settingsDmRelayNeedsServer = `${serverNeedDm} This page has none.`;
export const settingsDmUseFastest = "Switch to Fastest";
export const settingsDmReload = "Saving reloads this window.";

export const sessionShareLabel = "Share this session";
export const sessionShareLinkCopy = "Copy the link to this session";
export const sessionLocalCopyLabel = "Continue with a local session copy";
export const sessionLeaveLabel = "Leave current Rooms session";
export const sessionCapabilityLabel = "Session link";
export const sessionShareSay =
	"You get a link to this session that opens it anywhere, including from a different Rooms page. Close or reload this page and sharing ends for everyone holding it.";
export const sessionGoLocalSay =
	"You get a copy of the rooms and settings and work from that. The shared session keeps running without you. Your name stays with it. Rooms here are read-only until you join under a name of your own, and coming back needs the link again.";
export const sessionKeepLocal = "Keep it local";
export const sessionStayAttached = "Stay attached";
export const sessionContinueLocally = "Continue locally";
export const sessionAccessTitle = "Session access";
export const sessionStateFile = "State file";
/** What the link field takes: the whole link the server prints, not just
 * the secret name inside it. */
export const capabilityUriLabel = "Link";
export const capabilitySetPlaceholder = "ROOMS-ADMIN-LISTENERS …";

/** Why a keepable link is not on offer, and where to go about it.
 *
 * Three parts because the middle one is a control. The conversation card draws
 * this sentence and the choice it names is in Settings, so the control takes
 * the reader there. */
export const archiveNeedsPeerLead =
	"Needs an archive peer to hold it. The archive built into this browser can't create one. Choose one in";
export const archiveNeedsPeerLink = sessionSettingsLocation;
export const archiveNeedsPeerAfter = ".";

/** The Connection tab's headings. Its sentences are the share and direct
 * message entries above. */
export const reachServerTitle = "Rooms server";
export const serverFactDirectory = "Directory";
export const serverFromPage = "The server this page came from";
export const serverChosenHere = "Chosen on this browser";
export const serverConnected = "Connected";
export const serverConnecting = "Connecting";
export const serverNotAnswering = "Not answering";
export const serverNotConnected = "Not connected";
export const serverTurnsAway = "Turns this page away";
export const serverBlockedByBrowser = "Blocked by this browser";
/** Said while the server turns this page's origin away, with the one fix. */
export const serverAwayRefuses = (origin: string) => `Restart it with --allow-origin=${origin} to let this page in.`;
/** Said while nothing answers at the server's address. */
export const serverAwaySilent = (host: string) => `Nothing answers at ${host}. Rooms keeps trying.`;
export const serverAwayBlocked = (permission: "prompt" | "denied") =>
	`${browserBlocks(permission)}, then Rooms connects.`;
export const serverTestBlocked = (permission: "prompt" | "denied") => `${browserBlocks(permission)}, then test again.`;
export const serverNoDirectory = "None";
export const serverChange = "Change server";
export const serverChangeLead = `${serverModel} Saving reloads this window, so test the address first.`;
export const serverAddressName = "Address";
export const serverChangeName = "Another server";
export const serverChangeAct = "Change…";
export const serverRemoveName = "Remove from this browser";
export const serverRemoveAct = "Remove…";
export const serverRemoveConfirm = "Remove this server?";
/** What removing the chosen server leaves: the page's own server, or none. */
export const serverRemoveSaid = (served: boolean) =>
	served
		? "This page goes back to the server it came from, and reloads."
		: "This page will have no Rooms server, so it reaches only addresses this browser can open on its own, and nobody reaches it. It reloads.";
export const serverRemoveKeep = "Keep it";
export const serverRemoveCommit = "Remove and reload";
export const serverNoneTitle = "No Rooms server";
export const serverTest = "Test";
export const serverTestAnswers = "It answers, and hosts a directory.";
export const serverTestElsewhere =
	"Something answers at this address, but it serves no Rooms directory. Check the address, or try again if the server is starting.";
export const serverTestRefuses = (origin: string) =>
	`It answers, but doesn't allow pages from ${origin}. Restart it with --allow-origin=${origin}.`;
export const serverTestSilent =
	"Nothing answers at this address. Check that the server is running and the address is right.";
export const serverNone = serverModel;
export const reachAboutDirectory = "About…";
/** The home directory choice. A room joined with no directory address opens in it. */
export const settingsHomeLabel = "Home directory";
export const settingsHomeChoice = "Home directory";
export const settingsHomeNone = "None";
export const settingsHomeHint = "A room you join without a directory address opens here.";
export const settingsHomeAway =
	"Your home directory isn't connected. Rooms keeps trying, and a room you join without an address waits for it.";
export const settingsHomeServerName = "This server's directory";
export const settingsHomeUseServer = "Make it home";
export const settingsHomeOption = (name: string, away: boolean): string => away ? `${name} (not connected)` : name;
export const settingsHomeHintEmpty =
	"Join a directory, then choose it here, so a room you join without an address opens there.";
export const dmConnectionTitle = "Direct message connection";
export const operationsTitle = "Operations";
export const settingsTitle = "Settings";
export const operationsLoadingNoun = "operations";
export const settingsConnectionTab = "Connection";

/** The title row every card shares: the theme and the notification bell. */
export const themeToLight = "Switch to light";
export const themeToDark = "Switch to dark";
export const notifyChanging = "Changing mention notifications";
export const notifyToggle = "Toggle mention notifications";
export const notifyOnMention = "Notify me when I'm mentioned";
export const notifyBlocked =
	"Notifications are on here, but this browser is blocking them. Allow notifications for this site in the browser's settings.";

/** Issued archive shares. */
export const archiveSharesTitle = "Issued archive shares";
export const archiveSharesLead = "Revoking one stops it working. A link handed over once isn't affected.";
export const archiveSharesEmpty = "This archive has shared nothing yet.";

/** The operations capability set. */
export const capabilitySetTitle = "Operations links";
export function capabilitySetEditUri(label: string): string {
	return `Edit ${label} link`;
}
export function capabilitySetInclude(label: string): string {
	return `Include ${label}`;
}
export const capabilitySetRetry = "Retry";
export const capabilitySetDiscard = "Discard";
export const capabilitySetSave = "Save changes";
export const capabilitySetUriRefused = "Enter the complete link the server printed.";
export function capabilitySetMintedSaid(flag: string): string {
	return `The server prints it when started with ${flag}. Paste the full link here and Rooms fetches it from the server it names. Anyone holding it has this access, so this session keeps it private.`;
}
export const capabilitySetSaveTo = "Save";

/** Restoring a room a saved session remembers. */
export const roomRecoveryTitle = "Restore room access";
export const recoveryRestoring = "Restoring room…";
export const recoveryRetrySaved = "Retry saved link";
export const recoveryUseCurrent = "Use current link";
export const recoveryRejoinByName = "Rejoin by name";
export const sessionStateSaved = (file: string) => `Saved ${file}.`;
