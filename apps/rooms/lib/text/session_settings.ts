// The Session tab of Settings: what this browser is working from, where it
// could work instead, the access links a shared session hands out, the state
// file, message history, and the capabilities it holds.
//
// These are the sentences a reader meets while deciding something about
// their own session, so each says what stays and what goes: a session that
// keeps running for everyone else, a browser that forgets, an archive that is
// not erased. Moved here verbatim from the Settings components so the
// product's voice can be read in one place.

/** The three access levels a session link can carry, and what each lets
 * its holder do. */
export type SessionAccessLevel = "observe" | "interact" | "admin";
export const sessionAccessLabel: Readonly<Record<SessionAccessLevel, string>> = {
	observe: "Read only",
	interact: "Can interact",
	admin: "Can administer",
};
export const sessionAccessSaid: Readonly<Record<SessionAccessLevel, string>> = {
	observe: "Can follow rooms and messages, but cannot type or change the workspace.",
	interact: "Can join, post, and update their own activity, but cannot manage the session.",
	admin: "Full workspace control, including session data, access links, and saved capabilities.",
};
/** Reading the past is its own grant rather than a step on the access scale,
 * because reading the past and administering the session are different
 * authorities. */
export const sessionHistoryLabel = "Can read earlier messages";
export const sessionHistorySaid =
	"Everything this session has recorded, not only what is said from the moment the link is used.";

/** Rooms and settings: what this browser works from. */
export const currentSessionTitle = "Rooms and settings";
export const currentSessionPaused = "This capability is paused.";
export const currentSessionAdmin = "This capability can administer it.";
export const currentSessionInteract = "This capability can interact with it.";
export const currentSessionObserve = "This capability is read only.";
export const currentSessionHosted = "Hosted session";
export const currentSessionAttached = "Attached session";
export const currentSessionLocal = "Local session";
export const currentSessionHostedTag = "This browser is hosting";
export const currentSessionAttachedTag = "Session capability";
export const currentSessionLocalTag = "This browser";
export const currentSessionHostedHint =
	"This page is hosting this session. Open it anywhere else with the link below. Closing or reloading this page ends sharing.";
export function currentSessionAttachedHint(accessSaid: string): string {
	return `A durable session peer keeps this workspace, so wherever you open it you see the same rooms and settings. ${accessSaid}`;
}
export const currentSessionLocalHint = "This browser keeps this workspace. Its rooms and settings stay on this device.";
export const currentSessionExportOrReset = "Export or reset…";
export const currentSessionExport = "Export a copy…";

/** Where this browser works: the moves between sessions. */
export const sessionMovesTitle = "Where this browser works";
export const sessionLeaveHostingSay =
	"This browser stops hosting. Everyone attached to it loses the session. Rooms and settings stay saved here.";
export const sessionLeaveSharedSay =
	"This browser leaves the shared session. That session keeps running for everyone else attached to it. Names stay with it, so rooms here are for reading until you join under a name of your own. Coming back needs that link again.";
export const sessionLeaveLocalSay =
	"This browser goes back to choosing a session. Its rooms, settings, and message archive stay saved here.";
export const sessionLeaveKeep = "Stay";
export const sessionStopHosting = "Stop hosting";
export const sessionDetachBrowser = "Detach browser";
export const sessionLeaveWorkspace = "Leave workspace";
export const sessionMoveAnother = "Another session";
export const sessionMoveThis = "This session";
export const sessionMoveThisBrowser = "This browser";
export const sessionContinueLocallyAsk = "Continue locally…";
export const sessionStartOver = "Start over";
export const sessionReturnToSetupAsk = "Return to setup…";
export const sessionAttachAnotherTitle = "Attach to another session";
export const sessionAttachTitle = "Attach a session";
export const sessionAttachHostingLead =
	"This browser stops hosting. Everyone attached to it loses this session. Then this browser shows the session the capability names.";
export const sessionAttachSharedLead =
	"This browser moves to the session the capability names, and shows what that session keeps.";
export const sessionAttachLocalLead =
	"A session peer keeps your rooms and settings, so every browser you attach sees the same workspace.";
export const sessionAttachHostingHint =
	"A capability for another session ends hosting for everyone attached here. A capability for this same session leaves hosting as it is.";
export const sessionAttachSharedHint =
	"A capability for another session moves this browser to it, and the session it is on now keeps running for everyone else. A second capability for that same session only changes which one this browser uses.";
export const sessionAttachLocalHint =
	"An empty session takes this browser's rooms and settings with it. One that already keeps rooms and settings shows those instead.";
export const sessionAttachCommit = "Attach this browser";

/** Session access: the links a shared session hands out. */
export function sessionAccessCreated(level: string, label: string): string {
	return `Created ${level} access for ${label}.`;
}
export function sessionAccessRevoked(name: string): string {
	return `Revoked session access for ${name}.`;
}
export const sessionAccessLead =
	"Create a separately revocable link for each person, device, or integration that shares this session.";
export const sessionAccessNewTitle = "New access link";
export const sessionAccessCreate = "Create access link";
export const sessionAccessActiveTitle = "Active access links";
export const sessionAccessEmpty = "Nobody holds a separate access link to this session yet.";
export const sessionAccessThisBrowser = "This browser";
export const sessionAccessPaused = "Paused";
export const sessionAccessEarlierMessages = "Earlier messages";
export function sessionAccessRevokeLabel(label: string): string {
	return `Revoke access for ${label}`;
}
export const sessionAccessRevokeInUseSay =
	"This is the link this browser is using. Revoking it cuts this browser off as well, and coming back needs another link. Everyone holding it loses access immediately, and it stays revoked after restart.";
export const sessionAccessRevokeSay =
	"Existing holders lose access immediately, and this access link stays revoked after restart.";
export function sessionAccessCopyLabel(label: string): string {
	return `Copy session access for ${label}`;
}

/** Editing one access link. */
export const sessionGrantLead = "Changes reach whoever is holding this link. The link itself never changes.";
export const sessionGrantAccessTitle = "Access";
export const sessionGrantPausing = "Pausing";
export const sessionAccessPausedPrefix = "Paused:";
export function sessionGrantNowSaid(label: string, level: string): string {
	return `${label} is now ${level}.`;
}
export function sessionGrantHistoryOff(label: string): string {
	return `${label} can no longer read earlier messages.`;
}
export function sessionGrantHistoryOn(label: string): string {
	return `${label} can read earlier messages.`;
}
export const sessionGrantPausedSaid =
	"This link is paused. Whoever holds it can reach nothing until it is let back in.";
export function sessionGrantPausedNote(note: string): string {
	return `This link is paused: ${note}`;
}
export function sessionGrantResumedSaid(label: string): string {
	return `${label} works again.`;
}
export const sessionGrantResume = "Let it back in";
export const sessionGrantWhyLabel = "Why";
export const sessionGrantWhyOptional = "Optional";
export const sessionGrantWhyHint = "Said to whoever holds this link, in place of the session.";
export const sessionGrantPauseInUse =
	"This is the link this browser is using. Pausing it stops this browser too, and letting it back in has to be done from somewhere else.";
export function sessionGrantPausedNow(label: string): string {
	return `${label} is paused.`;
}
export const sessionGrantPause = "Pause it";
export const sessionGrantKeepWorking = "Keep it working";
export const sessionGrantPauseLead =
	"A paused link reaches nothing and keeps the access it was issued with, so letting it back in restores that.";
export const sessionGrantPauseAsk = "Pause access…";

/** Session data: the state file. */
export const sessionDataSharedTitle = "Shared session data";
export const sessionDataLocalTitle = "Local session data";
export const sessionDataSharedAdminLead =
	"The rooms and settings everyone attached to this session shares, plus this browser's own view preferences.";
export const sessionDataSharedLead =
	"The rooms and settings this capability can see, plus this browser's own view preferences. It cannot replace or reset them.";
export const sessionDataLocalLead = "The rooms, settings, and view preferences this browser keeps.";
export const sessionDataMessagesApart = "Messages are kept separately, under Message history.";
export const sessionDataExportTitle = "Export a copy";
export const sessionDataIncludeCapabilities = "Include remembered capabilities";
export function sessionDataIncludeCapabilitiesSaid(shared: boolean): string {
	return `The file will also hold the selected links that grant access to rooms, operations, moderation, and any archive${
		shared ? " in the shared workspace" : ""
	}. Anyone with the file could use them. It does not include session management.`;
}
export const sessionDataExport = "Export state";
export const sessionDataImportTitle = "Replace from a file";
export const sessionDataImportSharedHint =
	"Importing replaces the shared session's rooms and settings once the file checks out, and this browser stays attached. A file that carries capabilities grants every one of them.";
export const sessionDataImportLocalHint =
	"Importing replaces this browser's rooms and settings once the file checks out. A file that carries capabilities grants every one of them.";
export const sessionDataImport = "Import state";
export const sessionDataImported = (name: string) => `Imported ${name}.`;
export const sessionDataClearSharedTitle = "Start the session over";
export const sessionDataClearLocalTitle = "Start over";
export const sessionDataClearSharedHint =
	"Everyone attached starts again from no rooms and no settings. The session itself stays, and message archives are not erased.";
export const sessionDataClearLocalHint =
	"This session forgets its rooms, settings, and remembered capabilities. This browser stays on the empty session. Rooms on servers and archives elsewhere are not erased.";
export const sessionDataClearSharedLabel = "Reset the shared session";
export const sessionDataClearLocalLabel = "Delete this browser's session";
export const sessionDataClearSharedSay = "Every attached browser sees an empty session the moment this goes through.";
export const sessionDataClearLocalSay = "This browser's message archive goes with it.";
export const sessionDataClearSharedCommit = "Reset shared session";
export const sessionDataClearLocalCommit = "Delete local session";
export const sessionDataClearSharedAsk = "Reset shared session…";
export const sessionDataClearLocalAsk = "Delete local session…";

/** Message history. */
export function historyKeptBy(label: string): string {
	return `New room and direct messages are kept by ${label}. Turning this off stops new writes. It cannot erase the session.`;
}
export function historyPeerUnavailableSaid(label: string): string {
	return `The selected ${label} is unavailable. New messages are not silently copied into this browser.`;
}
export const historyTitle = "Message history";
export const historyArchiveTitle = "Archive capability";
export const historyOwnedSession = "Keeps this session's message history.";
export const historyUseSessionArchive = "Use session archive";
export const historyChangePeerAsk = "Change archive peer…";
export const historyUsePeerAsk = "Use an archive peer…";
export const historyPeerTaken = "This archive peer keeps new history now.";
export const historyPeerModalLead =
	"A separate glowcap peer keeps your history. Rooms and message recipients never receive it.";
export const historyPeerSessionRetains =
	"This session retains the archive capability across reloads and for every attached view.";
export const historyPeerCommit = "Use archive peer";

/** Holdings: the capabilities this session has. Its lead and the title of
 * its access well are `ops.ts`'s and `settings.ts`'s. */
export const holdingsCopyHosted = "Copy the hosted session capability";
export const holdingsCopyAttached = "Copy the attached session capability";
export const sessionManageAccessAsk = "Manage access…";
export const holdingsSavedTitle = "Saved bearer authority";
export const holdingsSavedEmpty = "This session has saved no room authority.";
export const holdingsEntryLink = "Entry link";
export const holdingsModerator = "Moderator";
export const holdingsManager = "Manager";
export const holdingsOpenRoomControls = "Open room controls";
export const holdingsOpsTitle = "Operations capabilities";
