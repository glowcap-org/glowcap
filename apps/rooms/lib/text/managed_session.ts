// Copy for managed workspace operation, recovery and access notices.
export const managedSessionText = {
	browserPreferences: "Browser preferences",
	capabilityExport: "Capability export",
	workspaceHistory: "Workspace history",
	workspaceConflict: "The workspace changed. Review the current selection before reapplying this action.",
	acquisitionConflict:
		"The workspace changed before access was saved. Review the current selection before trying again.",
	startupRecovery: "Workspace startup and cleanup need recovery",
	composerBusy: "Two sends are still in progress. Keep this draft and send it when they finish.",
	archiveOfferMissing: "The original archive offer is no longer held",
	archiveOffer: "Archive offer",
	archivePeer: "Archive peer",
	archiveUnavailable:
		"The selected archive peer is unavailable. Messages still reach their recipients. Retry history when the peer returns.",
	archiveReadPermission: "This access does not allow reading the selected archive.",
	receivingConversationMissing: "The receiving conversation is no longer open",
	operationsInventory: "Operations inventory",
	operationsAcquisitionRefused: "The Operations capabilities could not be acquired",
	resultRecovery: "Original result recovery",
	resultAcquisition: "The change went through, but its result still needs recovery.",
	membershipEnded: "Membership ended",
	sharedRoom: "Shared room",
	workspaceShutdown: "Workspace shutdown",
	roomsConnection: "Rooms connection",
	directoryUnavailable:
		"Cannot reach this directory with the saved access. Review its connection or access before retrying.",
	directReadinessTimeout: "This direct conversation did not become ready in time. Try again.",
	workspaceAccess: "Workspace access",
	revoked: "This workspace access has been revoked.",
	receiptRetired: "This change already finished in another window.",
	resultExpired: "This change went through, but what it returned expired with an earlier connection.",
	outOfScope: "This access does not cover the selected workspace.",
} as const;
export const resultAcquisitionFailure = (detail: string): string =>
	`${managedSessionText.resultAcquisition} (${detail})`;
export const sharedHistoryLabel = (conversation: string): string => `History of ${conversation}`;
export const openingDirect = (peer: string): string => `Opening a direct conversation with ${peer}…`;
