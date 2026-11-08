// Settings: what is kept, what is shared, and how to get a room back.
//
// Mostly operator-adjacent, so these stay precise. The subject is whoever is
// reading, not the machinery.

/** Session message retention and the archive capability it selects. */
export const historyOffSession =
	"Nothing is saved. Messages show up in whatever windows are open, and are gone after that.";
export const historyOnSession = "Messages are saved in this session. Turn this off and new ones stop being saved.";

export const historyKeepLabel = "Keep message history";
export const historyArchivePeerLabel = "Archive peer capability";
export const historyArchivePeerTitle = "Archive peer";
export const historyBuiltInSession = "Built-in session archive";
export const historyPeerUnavailable = "That archive can't be reached right now.";
export const historyPeerDurable = "Connected. Its saved link lets this session reconnect on its own.";
export const historyPeerSaved = "Saved";
export const historyPeerReconnect = "Reconnect";
export const historyPeerLead =
	"A link that can read and write the archive. A new one starts keeping messages from now on, and doesn't copy what's already there.";

/** Getting back into a room a saved workspace remembers. The private case
 * needs care: a name is not enough, and rejoining a public room by name can
 * land somewhere else. */
export const recoveryPrivateNeedsLink = "This private room needs a current link. The name on its own won't find it.";
export const recoveryPrivateRetry = "Retry the saved link for this private room, or paste a current one.";
export const recoveryLinkRevoked =
	"The saved link was revoked. You can rejoin by name, but that may reach a different room using the same name now.";
export const recoveryPublicRetry = "Retry joining this public room by name.";
export const recoveryLinkLabel = "Current room entry link";
export const recoveryWait = "Wait for the room recovery to finish.";

/** Saving, and how it can fail. */
export const settingsConnectionSaving = "Wait for the connection setting to finish saving.";
export const settingsConnectionRefused = "Couldn't save the connection choice.";

export const settingsCopyDirectory = "Copy the directory address";
export const settingsCopyServer = "Copy the server address";
export const settingsCopyBrowser = "Copy this session's address";
export const settingsShareDirectory = "Lets anyone join this server's rooms by name.";
/** Said in place of the browser's address while the page has no Rooms server. */
export const settingsBrowserNoServer = "Nobody can reach this browser without a Rooms server.";
export const settingsBrowserUnreachable = "Nobody can reach this address until the Rooms server connects.";
export const settingsShareBrowser = "Share this address to let somebody start a direct conversation with you.";
/** The Rooms server this browser is reached through, chosen on this device. */
export const serverOfferTitle = "Use this Rooms server?";
export const serverOfferSay = (host: string, local: boolean) =>
	`This link asks Rooms to use the Rooms server at ${host}. People reach this browser through it, it carries your connections to directories that have no browser route, and link previews in messages are fetched through it. Use it if you started that server or trust whoever runs it. You can change this later in Settings, under Reachability.${
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

/** Where direct messages go. Both are end-to-end encrypted, so the choice is
 * about who can start one, not about who can read them. */
export const settingsDmDirectLabel = "Browser to browser";
export const settingsDmDirectSaid =
	"Encrypted between browsers. A client that isn't a browser can only reply after you write first.";
export const settingsDmRelayLabel = "Through the room relay";
export const settingsDmRelaySaid =
	"Encrypted end to end, and the Rooms server only carries the encrypted bytes. A client that isn't a browser can write to you first.";
export const settingsDmReload = "Saving reloads this window.";

export const sessionShareLabel = "Share this session";
export const sessionShareLinkCopy = "Copy the link to this session";
export const sessionLocalCopyLabel = "Continue with a local session copy";
export const sessionLeaveLabel = "Leave current Rooms session";
export const sessionCapabilityLabel = "Session capability";
export const sessionShareSay =
	"You get a link to this session that opens it anywhere, including from a different Rooms page. Close or reload this page and sharing ends for everyone holding it.";
export const sessionGoLocalSay =
	"You get a copy of the rooms and settings and work from that. The shared session keeps running without you. Your name stays with it, so rooms here are read-only until you join under a name of your own, and coming back needs the link again.";
export const sessionKeepLocal = "Keep it local";
export const sessionStayAttached = "Stay attached";
export const sessionContinueLocally = "Continue locally";
export const sessionAccessTitle = "Session access";
export const sessionStateFile = "State file";
/** What the capability value field takes: the whole URI the server prints,
 * not a swiss number alone. */
export const capabilityUriLabel = "Capability URI";
export const capabilitySetPlaceholder = "ROOMS-ADMIN-LISTENERS …";

/** Why a keepable link is not on offer, and where to go about it.
 *
 * Three parts because the middle one is a control. The conversation card draws
 * this sentence and the choice it names is in Settings, so the control takes
 * the reader there. */
export const archiveNeedsPeerLead =
	"Needs an archive peer to hold it. The archive built into this browser cannot create one. Choose one in";
export const archiveNeedsPeerLink = "Session settings";
export const archiveNeedsPeerAfter = ".";

/** The Reachability tab's headings. Its sentences are the share and direct
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
/** This browser stands between a public page and a server on the person's own
 * computer or network, asking once or refusing until they allow it. */
const browserBlocks = (permission: "prompt" | "denied") =>
	permission === "denied"
		? "This browser blocks this page from reaching servers on your computer or network. Allow local network access for this site in the browser's site settings"
		: "This browser asks before this page reaches a server on your computer or network. Allow it when the browser asks";
export const serverAwayBlocked = (permission: "prompt" | "denied") =>
	`${browserBlocks(permission)}, then Rooms connects.`;
export const serverTestBlocked = (permission: "prompt" | "denied") => `${browserBlocks(permission)}, then test again.`;
export const serverNoDirectory = "None";
export const serverChange = "Change server";
export const serverChangeLead =
	"A Rooms server is how this browser is reached. Saving reloads this window, so test the address first.";
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
		: "This page will have no Rooms server, so nobody can reach this browser. It reloads.";
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
export const serverNone =
	"This page has no Rooms server, which is how this browser is reached. Links you issue, direct messages, and an archive peer need one, and so does a directory whose address has no browser route.";
export const reachAboutDirectory = "About…";
/** The home directory choice. A room joined with no directory address opens in it. */
export const settingsHomeLabel = "Home directory";
export const settingsHomeChoice = "Directory";
export const settingsHomeNone = "None";
export const settingsHomeHint = "A room you join without a directory address opens here.";
export const settingsHomeAway =
	"Your home directory is not connected. Rooms keeps trying, and a room you join without an address waits for it.";
export const settingsHomeServerName = "This server's directory";
export const settingsHomeUseServer = "Make it home";
export const settingsHomeOption = (name: string, away: boolean): string => away ? `${name} (not connected)` : name;
export const settingsHomeHintEmpty =
	"This session has no home directory. Join a directory, then choose it here, so a room you join without an address opens there.";
export const reachBrowserTitle = "This browser";
export const dmConnectionTitle = "Direct message connection";
export const operationsTitle = "Operations";
export const settingsTitle = "Settings";
export const operationsLoadingNoun = "operations";
export const settingsSessionTab = "Session";
export const settingsHoldingsTab = "Holdings";
export const settingsReachabilityTab = "Reachability";

/** The title row every card shares: the theme and the notification bell. */
export const themeToLight = "Switch to light";
export const themeToDark = "Switch to syrup (dark)";
export const notifyChanging = "Changing mention notifications";
export const notifyToggle = "Toggle mention notifications";
export const notifyOnMention = "Notify me when I'm mentioned";
export const notifyBlocked =
	"Notifications are on here, but this browser is blocking them. Allow notifications for this site in the browser's settings.";

/** Issued archive shares. */
export const archiveSharesTitle = "Issued archive shares";
export const archiveSharesLead =
	"These are independently revocable publications from the selected archive peer. Revoking one unpublishes its sturdyref. A live one-shot handover is a different object and is not affected.";
export const archiveSharesEmpty = "This archive has issued no durable shares.";

/** The operations capability set. */
export const capabilitySetTitle = "Capability set";
export function capabilitySetEditUri(label: string): string {
	return `Edit ${label} capability URI`;
}
export function capabilitySetInclude(label: string): string {
	return `Include ${label}`;
}
export const capabilitySetRetry = "Retry";
export const capabilitySetSave = "Save changes";
export const capabilitySetUriRefused = "Enter the complete capability URI printed by the server.";
export const capabilitySetIncomplete = "Supply a complete capability URI for every enabled capability.";
export function capabilitySetMintedSaid(flag: string, how: string): string {
	return `The server mints it with ${flag}. ${how} It is bearer authority and is retained by this session.`;
}
export const capabilitySetSaveTo = "Save to capability set";

/** Restoring a room a saved workspace remembers. */
export const roomRecoveryTitle = "Restore room access";
export const recoveryRestoring = "Restoring room…";
export const recoveryRetrySaved = "Retry saved link";
export const recoveryUseCurrent = "Use current link";
export const recoveryRejoinByName = "Rejoin by name";
