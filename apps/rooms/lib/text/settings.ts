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

export const settingsCopyDirectory = "Copy the address for this server";
export const settingsCopyBrowser = "Copy this session's address";
export const settingsShareDirectory =
	"Share this address to let somebody reach this server and join its rooms by name.";
export const settingsShareBrowser = "Share this address to let somebody start a direct conversation with you.";

/** Where direct messages go. Both are end-to-end encrypted, so the choice is
 * about who can start one, not about who can read them. */
export const settingsDmDirectLabel = "Browser to browser";
export const settingsDmDirectSaid =
	"Encrypted between browsers. A client that isn't a browser can only reply after you write first.";
export const settingsDmRelayLabel = "Through the room relay";
export const settingsDmRelaySaid =
	"Encrypted end to end, and the relay only carries the encrypted bytes. A client that isn't a browser can write to you first.";
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
export const sessionAccessFor = "Who or what is this for?";
export const sessionAccessTitle = "Session access";
export const sessionAccessKeep = "Keep access";
export const sessionAccessRevoke = "Revoke access";
export const sessionAccessPlaceholder = "Kitchen display";
export const sessionGrantNotePlaceholder = "Back on Monday";
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
export const reachDirectoryTitle = "This directory";
export const reachAboutDirectory = "About this directory";
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
