// Copy for managed workspace operation, recovery and access notices.
export const managedSessionText = {
	browserPreferences: "Browser preferences",
	capabilityExport: "Link export",
	workspaceHistory: "Session history",
	workspaceConflict: "The session changed. Check what is selected, then do it again.",
	acquisitionConflict: "The session changed before access was saved. Check what is selected, then try again.",
	acquisitionRefused: "The session refused this change, so nothing was saved.",
	acquisitionUnknown: "Rooms couldn't tell whether this change was saved. Pick it back up from Unfinished changes.",
	startupRecovery: "Session startup and cleanup need recovery",
	composerBusy: "Two sends are still in progress. Keep this draft and send it when they finish.",
	archiveOfferMissing: "The original archive offer is no longer held",
	archiveOffer: "Archive offer",
	archivePeer: "Archive peer",
	archiveUnavailable:
		"The selected archive peer is unavailable. Messages still reach their recipients. Retry history when the peer returns.",
	archiveReadPermission: "This access doesn't allow reading the selected archive.",
	receivingConversationMissing: "The receiving conversation is no longer open",
	operationsInventory: "Operations inventory",
	operationsAcquisitionRefused: "Rooms couldn't get the Operations links.",
	resultRecovery: "Original result recovery",
	resultAcquisition: "The change went through, but its result still needs recovery.",
	membershipEnded: "Membership ended",
	sharedRoom: "Shared room",
	workspaceShutdown: "Session shutdown",
	roomsConnection: "Rooms connection",
	roomsServer: "Rooms server",
	directoryUnavailable:
		"Rooms couldn't reach this directory with the saved access. Review its connection or access before retrying.",
	directReadinessTimeout: "This direct message didn't become ready in time. Try again.",
	workspaceAccess: "Session access",
	revoked: "This session access has been revoked.",
	receiptRetired: "This change already finished in another window.",
	resultExpired: "This change went through, but what it returned expired with an earlier connection.",
	outOfScope: "This access doesn't cover the selected session.",
} as const;
export const resultAcquisitionFailure = (detail: string): string =>
	`${managedSessionText.resultAcquisition} (${detail})`;
export const sharedHistoryLabel = (conversation: string): string => `History of ${conversation}`;
export const openingDirect = (peer: string): string => `Opening a direct message with ${peer}…`;
