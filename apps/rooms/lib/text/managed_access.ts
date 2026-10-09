// Copy for explicit session use and independently held management.
export const managedAccessText = {
	"title": "Session access",
	"heldTitle": "Access",
	"held": "Unnamed access",
	"revokedName": "Revoked access",
	"ownControl": "This workspace",
	"ownSaid": "Your own access",
	"ownEditLead":
		"Your own access to this workspace. Everything you share comes from it, so it can't be paused or revoked.",
	"advancedSaid": "Onward sharing and future changes",
	"sharingLead":
		"Give a person or device its own link to this workspace, allowing only what you choose. Pause or revoke it any time.",
	"issuancePolicy": "Pause, revoke or rename it later from its card.",
	"noControl": "Nothing to manage yet. A workspace link someone gave you lets you use it, not manage it.",
	"editLead": "Change what this access allows, pause it, or revoke it.",
	"endedLead": "This access was revoked. It no longer works, and nothing about it can change.",
	"ancestor": "An access it was created under is paused or revoked, which limits this one too.",
	"savePermissions": "Save permissions",
	"label": "Name",
	"saveLabel": "Save name",
	"revokeAsk": "Revoke…",
	"revokeConfirm": "Revoke this access?",
	"revokeSaid":
		"Anyone using its link loses access at once, and so does any access created from it. This can't be undone. It leaves your list, and stays on record as revoked under the access it came from.",
	"keep": "Keep it",
	"revoke": "Revoke",
	"reapply": "Save mine instead",
	"discard": "Discard mine",
	"missingEdit": "Rooms couldn't confirm whether your change was saved. It is kept, so you can check again.",
	"recoverEdit": "Check again",
	"committedEdit": "Saved.",
	"staleEdit":
		"Someone else changed this access while you were editing, so your change wasn't saved. It is kept here.",
	"shareControlSaid":
		"Create a link that lets someone else manage this access. They can do only what you choose here, and you keep your own control.",
	"prepareControl": "Create management link",
	"shareEdit": "Change its permissions",
	"shareEditSaid": "Up to the limit your own access has.",
	"uninspectable": "This link can't see the access it manages, so its permissions aren't shown.",
	"powerless":
		"This access was created without any way to manage it, so it can't be changed, paused or revoked from here.",
	"copyControl": "Copy management link",
	"observeWorkspace": "See the workspace",
	"interactWorkspace": "Act in the workspace",
	"replaceWorkspace": "Replace the workspace",
	"manageCustody": "Add or remove keys and links",
	"shareCustody": "Share keys and links",
	"resolvePending": "Finish interrupted changes",
	"useOperations": "Use operator tools",
	"history": "Read message history",
	"readArchive": "Read the saved archive",
	"readFile": "Open files",
	"custom": "Custom",
	"customSaid": "Choose each permission yourself.",
	"matches": "Matches",
	"reading": "Also allow",
	"saveControl": "Save",
	"controlLink": "Management link",
	"holdControl": "Add",
	"controlLinkHint": "The ocapn:// link someone gave you to manage an access.",
	"holdRow": "A management link someone gave you",
	"holdAsk": "Add…",
	"holdTitle": "Add a management link",
	"holdLead": "Paste a management link to pause, revoke or change that access from here.",
	"issueAsk": "New access…",
	"issuePendingAsk": "Resume new access…",
	"issueTitle": "New access",
	"noDelegation":
		"Your access can't pass management on, so this new access can't be paused, changed or revoked once it exists.",
	"activeLabel": "Active",
	"statusLabel": "Status",
	"activeSaid": "Works now. Turn it off to pause it until you turn it back on.",
	"pausedNowSaid": "Paused. It does nothing until you turn it back on.",
	"revokeRow": "Revoke",
	"revokeRowSaid": "Ends this access for good, along with any access created from it.",
	"removeRow": "Remove from your list",
	"removeRowSaid":
		"Stops you managing it from here. Anyone using its link keeps their access, so revoke it first if it should end.",
	"removeAsk": "Remove…",
	"remove": "Remove",
	"removeConfirm": "Remove it from your list?",
	"removeSaid":
		"You won't be able to pause, change or revoke it from here again. Anyone using its link keeps their access.",
	"endedSaid": "It no longer works. Removing it only tidies your list.",
	"descendantsTitle": "Created from this access",
	"loadingDescendants": "Reading…",
	"labelPlaceholder": "Who or what it's for, like Sam's laptop",
	"issueActiveSaid": "Works as soon as it is created. Turn it off to create it paused.",
	"issuePausedSaid": "Created paused. Turn it on from its card when you're ready.",
	"depth": "Onward sharing",
	"depthSaid": "How many times its holder can pass it on. 0 keeps it with them.",
	"powers": "Advanced",
	"powersShare": "They can",
	"pausePower": "Pause",
	"resumePower": "Resume",
	"revokePower": "Revoke",
	"inspect": "See its details",
	"delegateControl": "Pass management on",
	"delegateControlSaid": "They can create narrower management links of their own.",
	"editPolicy": "Changing its permissions later",
	"editNoneSaid": "Its permissions stay as set.",
	"issueAccess": "Creating access from it",
	"issueNoneSaid": "No access can be created from it.",
	"ceilingNone": "Not allowed",
	"ceilingWithin": "Within these permissions",
	"ceilingWithinSaid": "You can remove and restore what's set above.",
	"ceilingAll": "Up to what you can grant",
	"ceilingAllSaid": "You can widen it later, as far as your own access allows.",
	"ceilingCustomSaid": "Choose the most it could ever allow.",
	"create": "Create access",
	"missingIssue":
		"Rooms couldn't confirm whether the access was created. Your request is kept, so you can check again.",
	"recoverIssue": "Check again",
	"conflictIssue":
		"Your access changed while this was being created, so nothing was created. Review it and try again.",
	"reviewIssuer": "Review and try again",
	"committedIssue": "Access created.",
	"copyAccessOnce": "Copy the link now. It is shown only once.",
	"copyAccess": "Copy access link",
	"recoverReturned": "Finish setting it up",
	"descriptive": "To manage one of these, open it from its own row.",
	"unlabelled": "Unnamed access",
	"notSaved": "Not saved",
	"permissionsTitle": "Permissions",
	"shareTitle": "Let someone else manage it",
	"more": "Show more",
	"presentation": "Workspace presentation",
	"observation": "Workspace observation",
	"management": "Workspace management",
	"activity": "Workspace activity",
	"manage": "Manage…",
	"done": "Done",
} as const;
export const issueLead = (label: string | null): string =>
	label == null
		? "A new link to this workspace, allowing only what you choose."
		: `A new link under ${label}, allowing only what you choose within it.`;
/** A row's short account of its access: the picker's names, side by side. */
export const permissionLine = (names: readonly string[]): string =>
	names.length === 0 ? "Allows nothing yet." : names.join(" · ");
export const allowedPermissions = (names: readonly string[]): string =>
	names.length === 0
		? "Allows nothing yet."
		: `Allows ${names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} and ${names.at(-1)}`}.`;
export const savedControlSource = (id: string): string => `Saved management control ${id}`;
export const permissionDependency = (permission: string, prerequisite: string): string =>
	`${permission} requires ${prerequisite}.`;
export const permissionMatch = (label: string): string => `Matches ${label}.`;
export const unavailablePermissions = (permissions: readonly string[]): string =>
	`Unavailable: ${permissions.join(", ")}`;
export const statusTag: Record<"active" | "paused" | "revoked" | "uninspected", string> = {
	active: "Active",
	paused: "Paused",
	revoked: "Revoked",
	uninspected: "Uninspected",
};
export const currentPermissions = (permissions: readonly string[]): string =>
	`Current permissions: ${permissions.join(", ") || "none"}.`;
