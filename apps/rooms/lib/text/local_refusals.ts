// Local refusal keys own their sentence and retry advice together.
import { MAX_ROOM_AUDIENCE } from "../application_data.ts";
import type { RoomsFailureRetry } from "../error_codes.ts";
import { recoveryFinish, recoveryLetGoAsk } from "./recovery.ts";
import {
	historyReadAgain,
	historyTitle,
	holdingsOpsTitle,
	sessionChangesName,
	sessionDataIncludeCapabilities,
	sessionSettingsLocation,
	settingsHoldingsTab,
} from "./session_settings.ts";
import { notARoomEntryLink } from "./commands.ts";
import { managedSessionText } from "./managed_session.ts";
import { storageBlocked } from "./page.ts";
import { recoverManagerJoinFirst, roomCapabilityWait } from "./room_authority.ts";
import { managedAccessText } from "./managed_access.ts";
import { conversationNoLongerOpen } from "./attached.ts";
import { cannotSendRegistrationEnded } from "./conversation.ts";

export const LOCAL_REFUSALS = {
	"mentions-room": {
		summary: "Join this room as a participant to change automatic mentions.",
		retry: "never",
	},
	"mentions-name": { summary: "Use a member’s @name. Room-wide mentions cannot be saved here.", retry: "never" },
	"mentions-offline": { summary: "Choose members currently online in this room.", retry: "never" },
	"mentions-members": { summary: "Choose each member once and leave out your own name.", retry: "never" },
	"mentions-limit": { summary: `Choose up to ${MAX_ROOM_AUDIENCE} members per room.`, retry: "never" },
	"session-startup-failed": {
		summary: "Rooms couldn't open or cleanly close this session. Reload the page before opening it again.",
		retry: "never",
	},
	"tab-identity-invalid": {
		summary:
			"Rooms can't use the session identity saved in this tab. Open Rooms in a new tab, then close this one.",
		retry: "never",
	},
	"retained-result-unreadable": {
		summary:
			`This saved change has a result this version of Rooms can't read. Under ${sessionChangesName}, choose ${recoveryLetGoAsk} when you no longer need its result. The change itself is not undone.`,
		retry: "never",
	},
	"access-unavailable": {
		summary: "This access can no longer be managed. Ask its owner for a current control link.",
		retry: "after-request-change",
	},
	"archive-invalid": {
		summary:
			`Rooms couldn't read your saved messages. Choose ${historyReadAgain} under ${historyTitle} in ${sessionSettingsLocation}. Messages already shown are kept.`,
		retry: "after-state-change",
	},
	"history-unavailable": {
		summary:
			`Rooms couldn't read every conversation's saved messages. Choose ${historyReadAgain} under ${historyTitle} in ${sessionSettingsLocation}. Messages already shown are kept.`,
		retry: "after-state-change",
	},
	"clipboard-unavailable": {
		summary: "This browser couldn't copy the text. Select it and copy it yourself.",
		retry: "never",
	},
	"not-room-entry": {
		summary: notARoomEntryLink,
		retry: "after-request-change",
	},
	"workspace-unavailable": {
		summary: "Rooms hasn't loaded this session yet. Wait for it to open.",
		retry: "after-state-change",
	},
	"operations-access-missing": {
		summary:
			`This session no longer holds the access this action needs. Check ${holdingsOpsTitle} under ${settingsHoldingsTab}.`,
		retry: "after-state-change",
	},
	"capability-unsavable": {
		summary: "One of these links can't be saved. Ask its owner for a link that can be shared.",
		retry: "never",
	},
	"history-invalid": {
		summary: "Rooms couldn't read this history. Ask whoever shared it to check their archive.",
		retry: "never",
	},
	"preview-unreadable": {
		summary: "The server returned an unreadable preview. Send the link without a preview.",
		retry: "never",
	},
	"capability-set-unreadable": {
		summary: "Rooms couldn't read these operations links.",
		retry: "after-request-change",
	},
	"result-needs-recovery": { summary: managedSessionText.resultAcquisition, retry: "after-state-change" },
	"session-closed": { summary: "This session has closed. Reload the page to continue.", retry: "never" },
	"still-working": { summary: "Rooms is still working on this. Try again once it finishes.", retry: "soon" },
	"busy": { summary: "Rooms is still working on earlier requests. Try again once they finish.", retry: "soon" },
	"not-sent": { summary: "Nothing was sent. Try again.", retry: "soon" },
	"invite-unsent": {
		summary:
			"The direct conversation opened, but Rooms couldn't read it to send the invitation. Try inviting again.",
		retry: "soon",
	},
	"archive-unsent": {
		summary: "The direct conversation opened, but Rooms couldn't read it to share the archive. Try sharing again.",
		retry: "soon",
	},
	"session-unread": {
		summary: "Rooms couldn't read the session while its connection is away.",
		retry: "soon",
	},
	"receipt-lost": {
		summary:
			"The connection dropped before Rooms could confirm this, so it may not have gone through. Look for it, and do it again if it is missing.",
		retry: "after-request-change",
	},
	"directory-changed": {
		summary: "This directory's access changed. Check it, then try again.",
		retry: "after-state-change",
	},
	"directory-gone": {
		summary: "This directory is no longer in the session. Paste its address to reach it again.",
		retry: "never",
	},
	"conflict": { summary: managedSessionText.workspaceConflict, retry: "after-state-change" },
	"room-gone": { summary: "This room is no longer in the session. Pick another from the sidebar.", retry: "never" },
	"conversation-gone": {
		summary: "This conversation is no longer in the session. Pick another from the sidebar.",
		retry: "never",
	},
	"message-gone": {
		summary: "This message is no longer waiting to send, so there is nothing to change.",
		retry: "never",
	},
	"direct-not-opened": {
		summary: "This direct message didn't open. Start it again from the directory.",
		retry: "never",
	},
	"acquisition-gone": {
		summary: `This change is no longer under ${sessionChangesName}. Start it again if you still want it.`,
		retry: "never",
	},
	"connection-gone": {
		summary: "This connection is no longer in the session. Open its settings again to see what it holds.",
		retry: "never",
	},
	"publication-gone": {
		summary: "This publication is no longer in the session, so there is nothing to revoke.",
		retry: "never",
	},
	"target-gone-held": {
		summary: `What this change was for is no longer in the session. It stays under ${sessionChangesName}.`,
		retry: "after-state-change",
	},
	"result-still-running": {
		summary:
			`The change went through, and the session is still finishing it. It waits under ${sessionChangesName}. Choose ${recoveryFinish} there in a moment.`,
		retry: "soon",
	},
	"old-manager-recovery": {
		summary:
			`An older version of Rooms started this manager recovery, and this version can't finish it. Under ${sessionChangesName}, choose ${recoveryLetGoAsk}, then ask for the manager link again. Letting go doesn't revoke a link that was already issued.`,
		retry: "never",
	},
	"recovery-seat-lost": {
		summary:
			`This room's seat was lost or replaced, and no entrance holds the room, so this manager link can't be finished. Under ${sessionChangesName}, choose ${recoveryLetGoAsk}, rejoin the room, then ask for the manager link again. Letting go doesn't revoke a link that was already issued.`,
		retry: "never",
	},
	"registration-unfinished": {
		summary: `Registering in this directory didn't finish. Pick it up from ${sessionChangesName}.`,
		retry: "after-state-change",
	},
	"several-saved": {
		summary: "This name matches several saved rooms. Pick the one you mean from the sidebar.",
		retry: "after-request-change",
	},
	"name-ambiguous": {
		summary: "More than one room in this directory has this name. Pick the one you mean from its list.",
		retry: "after-request-change",
	},
	"needs-invitation": {
		summary: "This room needs an invitation. Ask someone in it to send you one.",
		retry: "after-request-change",
	},
	"not-directory": {
		summary: "This address isn't a directory. Check it, or paste a room link instead.",
		retry: "after-request-change",
	},
	"pick-conversation": {
		summary: "Select a room or direct message to share its history.",
		retry: "after-request-change",
	},
	"export-incomplete": {
		summary:
			`Rooms can't export every link here, because one of them can't be saved. Export without "${sessionDataIncludeCapabilities}" to keep the rest.`,
		retry: "never",
	},
	"not-export": { summary: "This file isn't a Rooms session export.", retry: "after-request-change" },
	"access-own-stays-held": { summary: "Your own access to this session can't be removed.", retry: "never" },
	"access-change-unfinished": {
		summary: "Save or discard the change to this access first.",
		retry: "after-state-change",
	},
	"access-share-unfinished": {
		summary: "Finish sharing the access you started before sharing another.",
		retry: "after-state-change",
	},
	"access-share-source": {
		summary: "You're sharing a new access from this one. Finish sharing it before removing this access.",
		retry: "after-state-change",
	},
	"access-share-made-unsaved": {
		summary: "Save the new access before removing it, so this browser can still revoke it.",
		retry: "after-state-change",
	},
	"access-share-unread": {
		summary:
			"The new access was made, but this browser couldn't read it, so it can't be revoked on its own from here. Ask whoever runs the session to revoke it, then share again.",
		retry: "after-request-change",
	},
	"access-share-unconfirmed": {
		summary: "Rooms couldn't confirm the access you started sharing. Check it again before finishing.",
		retry: "after-state-change",
	},
	"access-share-unpublished": {
		summary: "Get the new access's link before finishing.",
		retry: "after-state-change",
	},
	"access-share-unsaved": { summary: "Save the new access before finishing.", retry: "after-state-change" },
	"access-share-lost": {
		summary:
			"The new access was made, but Rooms lost hold of it before this browser saved it, so it can't be revoked on its own from here. Ask whoever runs the session to revoke it, then share again.",
		retry: "after-request-change",
	},
	"access-share-lost-removed": {
		summary:
			"The new access was made, but it was removed from this browser before its link was shown. Ask whoever runs the session to revoke it, then share again.",
		retry: "after-request-change",
	},
	"access-share-lost-unknown": {
		summary:
			"Rooms couldn't confirm the new access, so it may have been made, and it can't be revoked on its own from here. Ask whoever runs the session to look for it and revoke it, then share again.",
		retry: "after-request-change",
	},
	"access-share-unsent": {
		summary:
			"Nothing was sent, and Rooms can't reach the access you shared from. Share again from an access that works.",
		retry: "after-request-change",
	},
	"access-share-revoked": {
		summary:
			"The access you shared from was revoked, which revokes any access shared from it, so nothing was left behind. Share again from an access that is still active.",
		retry: "after-request-change",
	},
	"access-share-unlinked": {
		summary:
			"The new access was made and saved, but Rooms lost hold of it before its link was shown. It is listed with this session's other access, where you can revoke it.",
		retry: "never",
	},
	"access-share-unheld": {
		summary:
			`The new access was made, but Rooms lost hold of it. Choose ${managedAccessText.recoverReturned} and Rooms asks the session for it again.`,
		retry: "soon",
	},
	"access-narrower-pending": {
		summary:
			"Rooms is still asking the session for the management link you asked for last, with the choices it asked for.",
		retry: "after-state-change",
	},
	"access-narrower-unconfirmed": {
		summary:
			`Rooms couldn't confirm the management link you asked for last. If it was made, its link was never shown, so no one has it. Choose ${managedAccessText.prepareControl} again to make a new one.`,
		retry: "after-request-change",
	},
	"access-edit-unfinished": {
		summary: "Finish or discard your other change to this access first.",
		retry: "after-state-change",
	},
	"access-edit-submitting": {
		summary: "Your change to this access is still saving. Try again once it finishes.",
		retry: "soon",
	},
	"access-edit-unconfirmed": {
		summary: "Rooms couldn't confirm whether your change was saved. Check it again before discarding it.",
		retry: "after-state-change",
	},
	"access-edit-lost": {
		summary:
			"Rooms couldn't confirm whether your change was saved, and can't check it now. Look at this access to see whether it changed.",
		retry: "after-state-change",
	},
	"settings-capability-set-saving": { summary: "Wait for the capability set to finish saving.", retry: "soon" },
	"settings-archive-peer-changing": { summary: "Wait for the archive peer change to finish.", retry: "soon" },
	"settings-access-holding": { summary: "Wait for this access to finish opening.", retry: "soon" },
	"settings-session-data-busy": { summary: "Wait for the session data change to finish.", retry: "soon" },
	"settings-attach-busy": { summary: "Wait for this browser to finish attaching.", retry: "soon" },
	"storage-blocked": { summary: storageBlocked, retry: "after-state-change" },
	"room-link-busy": { summary: roomCapabilityWait, retry: "soon" },
	"capability-set-incomplete": {
		summary: "Enter the complete link for every item you turned on.",
		retry: "after-request-change",
	},
	"access-issuance-busy": { summary: managedAccessText.issueBusy, retry: "soon" },
	"room-recovery-busy": { summary: "Wait for the room recovery to finish.", retry: "soon" },
	"manager-recovery-needs-membership": { summary: recoverManagerJoinFirst, retry: "after-state-change" },
	"connection-setting-busy": { summary: "Wait for the connection setting to finish saving.", retry: "soon" },
	"conversation-not-open": { summary: conversationNoLongerOpen, retry: "after-state-change" },
	"registration-ended": { summary: cannotSendRegistrationEnded, retry: "after-request-change" },
	"acquisition-conflict": { summary: managedSessionText.acquisitionConflict, retry: "after-state-change" },
	"result-expired": { summary: managedSessionText.resultExpired, retry: "never" },
	"receipt-retired": { summary: managedSessionText.receiptRetired, retry: "never" },
	"operations-acquisition-refused": {
		summary: managedSessionText.operationsAcquisitionRefused,
		retry: "after-state-change",
	},
	"composer-busy": { summary: managedSessionText.composerBusy, retry: "soon" },
	"acquisition-unknown": { summary: managedSessionText.acquisitionUnknown, retry: "after-state-change" },
	"access-issue-unknown": { summary: managedAccessText.missingIssue, retry: "after-state-change" },
	"access-edit-unknown": { summary: managedAccessText.missingEdit, retry: "after-state-change" },
	"access-issue-conflict": { summary: managedAccessText.conflictIssue, retry: "after-state-change" },
	"access-edit-conflict": { summary: managedAccessText.staleEdit, retry: "after-state-change" },
	"message-too-long": {
		summary: "This message is too long. Shorten it before sending.",
		retry: "after-request-change",
	},
	"access-changed": {
		summary: "This access changed while Rooms was reading it. Review its current details before continuing.",
		retry: "after-state-change",
	},
	"room-authority-changed": {
		summary: "This room's manager or moderator access changed. Review its settings before removing access.",
		retry: "after-state-change",
	},
	"room-access-changed": {
		summary: "Your access to this room changed. Review the room before continuing.",
		retry: "after-state-change",
	},
	"invitation-changed": {
		summary: "This invitation changed or is no longer held. Open the current invitation before accepting it.",
		retry: "after-state-change",
	},
	"registration-changed": {
		summary: "Your registration in this directory changed. Check the directory, then try again.",
		retry: "after-state-change",
	},
	"conversation-changed": {
		summary: "This conversation changed. Select it again before sharing its history.",
		retry: "after-state-change",
	},
	"history-offer-changed": {
		summary: "This history offer changed. Open the current offer before reading it.",
		retry: "after-state-change",
	},
	"command-selection-changed": {
		summary: "Your selection for this change has changed. Review it, then try again.",
		retry: "after-state-change",
	},
	"gateway-changed": {
		summary: "This IRC connection changed. Open its current settings before continuing.",
		retry: "after-state-change",
	},
	"message-selection-changed": {
		summary: "This conversation or message changed. Review it before sending your change.",
		retry: "after-state-change",
	},
	"room-not-listed": {
		summary: "That room is no longer listed. Refresh the directory before joining.",
		retry: "after-state-change",
	},
	"selected-access-changed": {
		summary: "The access selected for this change has changed. Review it, then try again.",
		retry: "after-state-change",
	},
	"export-changed": {
		summary: "The session changed while Rooms was exporting it. Export again.",
		retry: "after-state-change",
	},
	"unfinished-limit": {
		summary:
			`There are too many unfinished changes. Finish or release one under ${sessionChangesName} before starting another.`,
		retry: "after-state-change",
	},
	"change-blocked": {
		summary:
			`Another unfinished change affects this selection. Finish it under ${sessionChangesName} before continuing.`,
		retry: "after-state-change",
	},
	"change-owned": {
		summary: `This change is already in progress. Continue it under ${sessionChangesName}.`,
		retry: "after-state-change",
	},
	"result-held": {
		summary: "This change's result is still in use. Finish that work before releasing it.",
		retry: "after-state-change",
	},
	"change-busy": {
		summary: "This change is still running. Wait for it to finish before releasing it.",
		retry: "soon",
	},
	"release-unconfirmed": {
		summary:
			`Rooms couldn't confirm that this change was let go. Check it under ${sessionChangesName}, then let it go again if it is still there.`,
		retry: "after-state-change",
	},
	"change-replay-required": {
		summary: `This change has already started. Pick it up from ${sessionChangesName} instead of starting it again.`,
		retry: "after-state-change",
	},
	"change-unconfirmed": {
		summary: `Rooms couldn't confirm this change. Check it under ${sessionChangesName} before continuing.`,
		retry: "after-state-change",
	},
	"result-saving": {
		summary: `Finish saving this result under ${sessionChangesName} before continuing.`,
		retry: "after-state-change",
	},
	"session-switch-in-progress": {
		summary: "Rooms is already switching sessions. Wait for that switch to finish.",
		retry: "soon",
	},
	"session-switch-unconfirmed": {
		summary: "The previous session switch hasn't finished. Continue it before choosing another session.",
		retry: "after-state-change",
	},
	"access-change-retained": {
		summary:
			`Another change to this access is unfinished. Finish it under ${sessionChangesName} before starting a different one.`,
		retry: "after-state-change",
	},
	"import-in-progress": {
		summary: "A session import is unfinished. Finish it before importing another file.",
		retry: "after-state-change",
	},
	"message-edit-unfinished": {
		summary: "An earlier edit to this message hasn't finished. Finish it before changing the text again.",
		retry: "after-state-change",
	},
} as const satisfies Record<string, { summary: string; retry: RoomsFailureRetry }>;

export type LocalRefusalKey = keyof typeof LOCAL_REFUSALS;
export type LocalRefusalCode = `local-${LocalRefusalKey}`;
