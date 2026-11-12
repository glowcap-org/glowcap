// The Session tab of Settings: what this browser is working from, where it
// could work instead, the access links a shared session hands out, the state
// file, message history, and the capabilities it holds.
//
// A reader meets these while deciding something about their own session, so
// each says what stays and what goes: a session that keeps running for
// everyone else, a browser that forgets, an archive that is not erased.

/** The three access levels a session link can carry, and what each lets its
 * holder do. */
export type SessionAccessLevel = "observe" | "interact" | "admin";
export const sessionAccessLabel: Readonly<Record<SessionAccessLevel, string>> = {
	observe: "Read only",
	interact: "Can interact",
	admin: "Can administer",
};

/** Rooms and settings: what this browser works from. */
export const currentSessionTitle = "Rooms and settings";
export const currentSessionPaused = "This link is paused.";
export const currentSessionAdmin = "This link can administer it.";
export const currentSessionInteract = "This link can interact with it.";
export const currentSessionObserve = "This link is read only.";
export const currentSessionHosted = "Hosted session";
export const currentSessionAttached = "Attached session";
export const currentSessionLocal = "Local session";
export const currentSessionHostedTag = "This browser is hosting";
export const currentSessionAttachedTag = "Session link";
export const currentSessionLocalTag = "This browser";
export const currentSessionHostedHint =
	"Open it anywhere else with the link below. Closing or reloading this page ends sharing.";
export function currentSessionAttachedHint(accessSaid: string): string {
	return `A session peer keeps this session, so you see the same rooms and settings wherever you open it. ${accessSaid}`;
}
export const currentSessionLocalHint = "Its rooms and settings stay on this device.";
export const currentSessionExportOrReset = "Export or reset…";
export const currentSessionExport = "Export a copy…";

/** Where this browser works: the moves between sessions. */
export const sessionMovesTitle = "Where this browser works";
export const sessionLeaveHostingSay =
	"This browser stops hosting. Everyone attached to it loses the session. Rooms and settings stay saved here.";
export const sessionLeaveSharedSay =
	"This browser leaves the shared session, which keeps running for everyone else. Names stay with it. Rooms here are for reading until you join under a name of your own, and coming back needs that link again.";
export const sessionLeaveLocalSay =
	"This browser goes back to choosing a session. Its rooms, settings, and message archive stay saved here.";
export const sessionLeaveKeep = "Stay";
export const sessionStopHosting = "Stop hosting";
export const sessionDetachBrowser = "Detach browser";
export const sessionLeaveWorkspace = "Leave session";
export const sessionMoveAnother = "Another session";
export const sessionMoveThis = "This session";
export const sessionMoveThisBrowser = "This browser";
export const sessionContinueLocallyAsk = "Continue locally…";
export const sessionStartOver = "Start over";
export const sessionReturnToSetupAsk = "Return to setup…";
export const sessionAttachAnotherTitle = "Attach to another session";
export const sessionAttachTitle = "Attach a session";
export const sessionAttachHostingLead = "This browser shows the session the link names.";
export const sessionAttachSharedLead =
	"This browser moves to the session the link names, and shows what that session keeps.";
export const sessionAttachLocalLead =
	"A session peer keeps your rooms and settings, so every browser you attach sees the same rooms and settings.";
export const sessionAttachHostingHint =
	"A link for another session ends hosting for everyone attached here. A link for this same session leaves hosting as it is.";
export const sessionAttachSharedHint =
	"Your current session keeps running for everyone else. A second link to the same session swaps which one this browser uses.";
export const sessionAttachLocalHint =
	"An empty session takes this browser's rooms and settings with it. One that already keeps rooms and settings shows those instead.";
export const sessionAttachCommit = "Attach this browser";

/** Session data: the state file. */
export const sessionDataSharedTitle = "Shared session data";
export const sessionDataLocalTitle = "Local session data";
export const sessionDataSharedAdminLead =
	"The rooms and settings everyone attached to this session shares, plus this browser's own view preferences.";
export const sessionDataSharedLead =
	"The rooms and settings this link can see, plus this browser's own view preferences. It can't replace or reset them.";
export const sessionDataLocalLead = "The rooms, settings, and view preferences this browser keeps.";
export const sessionDataMessagesApart = "Messages are kept separately, under Message history.";
export const sessionDataExportTitle = "Export a copy";
export const sessionDataIncludeCapabilities = "Include saved links";
export function sessionDataIncludeCapabilitiesSaid(shared: boolean): string {
	return `The file will also hold the selected links that grant access to rooms, operations, moderation, and any archive${
		shared ? " in the shared session" : ""
	}. Anyone with the file could use them. It doesn't include session management.`;
}
export const sessionDataExport = "Export state";
export const sessionDataImportTitle = "Replace from a file";
export const sessionDataImportSharedHint =
	"Importing replaces the shared session's rooms and settings once the file checks out, and this browser stays attached. A file that carries saved links grants access with every one of them.";
export const sessionDataImportLocalHint =
	"Importing replaces this browser's rooms and settings once the file checks out. A file that carries saved links grants access with every one of them.";
export const sessionDataImport = "Import state";
export const sessionDataImported = (name: string) => `Imported ${name}.`;
export const sessionDataClearSharedTitle = "Empty this session for everyone";
export const sessionDataClearLocalTitle = "Empty this session";
export const sessionDataClearSharedHint =
	"Everyone attached starts again from no rooms and no settings. The session itself stays, and message archives aren't erased.";
export const sessionDataClearLocalHint =
	"This session forgets its rooms, settings, and saved links. This browser stays on the empty session. Rooms on servers and archives elsewhere aren't erased.";
export const sessionDataClearSharedLabel = "Empty this session for everyone";
export const sessionDataClearLocalLabel = "Empty this session";
export const sessionDataClearSharedSay = "Every attached browser sees an empty session the moment this goes through.";
export const sessionDataClearLocalSay = "This browser's message archive goes with it.";
export const sessionDataClearSharedCommit = "Empty for everyone";
export const sessionDataClearLocalCommit = "Empty this session";
export const sessionDataClearSharedAsk = "Empty for everyone…";
export const sessionDataClearLocalAsk = "Empty this session…";
export const sessionDataClearSharedDone = "Emptied. Everyone attached is on the empty session now.";
export const sessionDataClearLocalDone = "Emptied. This browser is on an empty session now.";

/** Message history. */
export function historyKeptBy(label: string): string {
	return `New room and direct messages are kept by ${label}.`;
}
/** Said beside the switch, to a reader who can use it. */
export const historyKeptByOff = "Turning this off stops new messages from being saved. It can't erase the session.";
export function historyPeerUnavailableSaid(label: string): string {
	return `The selected ${label} is unavailable. New messages aren't silently copied into this browser.`;
}
export const historyTitle = "Message history";
export const settingsSessionTab = "Session";
export const sessionSettingsLocation = `Settings, under ${settingsSessionTab}`;
export const historyReadAgain = "Read saved messages again";
export const historyArchiveTitle = "Archive link";
export const historyOwnedSession = "Keeps this session's message history.";
export const historyUseSessionArchive = "Use session archive";
export const historyChangePeerAsk = "Change archive peer…";
export const historyUsePeerAsk = "Use an archive peer…";
export const historyPeerTaken = "This archive peer keeps new history now.";
export const historyPeerModalLead =
	"A separate glowcap peer keeps your history. Rooms and message recipients never receive it.";
export const historyPeerSessionRetains =
	"This session retains the archive link across reloads and for every attached view.";
export const historyPeerCommit = "Use archive peer";

/** Holdings: the capabilities this session has. The lead is in `ops.ts` and
 * the access title is in `settings.ts`. */
export const holdingsCopyHosted = "Copy the hosted session link";
export const holdingsCopyAttached = "Copy the attached session link";
export const holdingsSavedTitle = "Saved room links";
export const holdingsSavedEmpty = "This session has no saved room links.";
export const holdingsEntryLink = "Entry link";
export const holdingsModerator = "Moderator";
export const holdingsManager = "Manager";
export const holdingsOpenRoomControls = "Open room controls";
export const settingsHoldingsTab = "Holdings";
export const holdingsOpsTitle = "Operations links";
/** The session card's acts, one per line like "Where this browser works":
 * what the line is about, then the act. */
export const sessionChangesName = "Unfinished changes";
export const sessionChangesAct = "Review…";
export const sessionAccessName = "Access";
export const sessionAccessAct = "Manage…";
export const sessionDataName = "Session data";
