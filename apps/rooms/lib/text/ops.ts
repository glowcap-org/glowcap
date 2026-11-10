// The operator capabilities: what each one is, and what holding it does.
//
// Precision beats plainness here. A reader is matching a word against a flag
// a server printed, and softer vocabulary would make them guess. Each entry
// instead says what turning the capability on does, since that is the
// decision in front of them.

export const opsListenersLabel = "Administer listeners";
export const opsListenersShort = "Listeners";
export const opsListenersLead = "Lists this server's live listeners and lets you bring them up or down.";

export const opsDiagnosticsLabel = "Inspect this server";
export const opsDiagnosticsShort = "Inspect";
export const opsDiagnosticsLead = "Lists what this server is holding.";

export const opsIrcLabel = "IRC gateway";
export const opsIrcShort = "IRC";
export const opsIrcLead = "Bridges IRC channels into this server as ordinary rooms.";

export const opsOperatorLabel = "Operator";
export const opsOperatorShort = "Operator";
export const opsOperatorLead = "Lists and changes the links, names and live connections this server has issued.";

export const opsPeeringLabel = "Directory peering";
export const opsPeeringShort = "Peering";
export const opsPeeringLead = "Lists a durable room from another server here, for this connection.";

/** The toggle with a privacy consequence, so the sentence read before
 * flipping it says so.
 *
 * What a browser publishes is the field list in
 * `rust/runtime/src/trace/publish.rs`: who the session talked to, over what,
 * which operations ran and how big they were. Message bytes are not in that
 * list, which is why "not the text" is true. If the list gains a payload
 * field, this sentence must change with it. */
export const opsTraceLabel = "Live trace";
export const opsTraceShort = "Trace";
export const opsTraceLead =
	"Publishes which peers this session talks to and what it does with them, direct messages included. Not the text of your messages.";

/** Holdings, where the toggles live. The lead separates holding something now
 * from having saved it for next time. */
export const holdingsSharedLead = "Links this shared session has saved so it can use them again.";
export const holdingsLocalLead = "Links this session has saved so it can use them again.";
export const holdingsSetChanged = "The saved links changed. Your unsaved edits are still here.";
export const holdingsSetSaved = "Links saved.";
export const holdingsEditAsText = "Edit links as text";
export const holdingsEditAsControls = "Edit links as controls";

export const opsSearchLabel = "Search everything this directory holds";
export const opsSearchPlaceholder = "Search rooms, names, connections, references…";
export const opsListenerServingThisPage = "This listener is serving this page";
export const opsSweepKeep = "Keep them";
export const opsIrcBridgesWhat = "IRC bridges";
export const opsPeeringRoomLabel = "Room to publish";
export const opsPeeringAsLabel = "Listed here as";
export const peeringAsPlaceholder = "what this directory lists it as";
export const peeringPublishing = "publishing…";
export const peeringPublish = "Publish";
export const peeringPublishingAction = "Publishing…";
export const opsRefresh = "Refresh";
export const opsRefreshing = "Refreshing";
export const tracePublishing = "Publishing";
export const traceOn = "on";
export const traceRefused = "refused";
export const traceReconnecting = "reconnecting…";
export const opsListenersLoading = "listeners";
export const opsPeeredRoomsLoading = "peered rooms";
export const opsVisualizerStatusLoading = "visualizer status";
export const opsOperatorStateLoading = "the operator page";
export const opsDirectoryHoldingsLoading = "what this server holds";
export const opsOperatorPane = "operator page";
export const opsInspectPane = "inspect page";

/** Destinations in the operations navigation. */
export const opsPaneListeners = "Listeners";
export const opsPaneOperator = "Operator";
export const opsPaneIrc = "IRC";
export const opsPanePeering = "Peering";
export const opsPaneVisualizer = "Visualizer";

/** The Inspect page: each list it reads, what it is, and what an empty one
 * says. Inspect sees that a thing exists, never the thing. */
export interface OpsInspectSection {
	readonly title: string;
	readonly lead: string;
	readonly empty: string;
}
export const inspectLinks: OpsInspectSection = {
	title: "Room access",
	lead: "Durable room entry links this directory publishes. Inspect sees that a link stands, never the link.",
	empty: "This directory publishes no durable room entry link.",
};
export const inspectRegistrations: OpsInspectSection = {
	title: "Names and connections",
	lead: "A registered nickname holds direct-message inboxes and signaling routes on one exact session.",
	empty: "No nickname is registered here.",
};
export const inspectSessions: OpsInspectSection = {
	title: "Connections and live references",
	lead: "The peer sessions this directory is holding open, by what carries each one.",
	empty: "No other peer sessions are active.",
};
export const inspectRooms: OpsInspectSection = {
	title: "Rooms",
	lead: "Every room this directory holds, listed or private.",
	empty: "This directory holds no rooms.",
};
export const inspectOccupants: OpsInspectSection = {
	title: "Who is in a room",
	lead: "Each membership a room is holding right now.",
	empty: "Nobody is in a room right now.",
};
export const inspectModerators: OpsInspectSection = {
	title: "Room moderators",
	lead: "Whether a moderator link has been issued, never the link itself.",
	empty: "This server owns no rooms right now.",
};
export const inspectBootstrap: OpsInspectSection = {
	title: "Published bootstrap",
	lead: "What this directory answers to on the wire.",
	empty: "This directory publishes no bootstrap.",
};
export const inspectTrouble: OpsInspectSection = {
	title: "Directory trouble",
	lead: "Recent failures the server recorded while it ran.",
	empty: "No trouble reported.",
};
export const inspectAdmission: OpsInspectSection = {
	title: "Work budgets",
	lead:
		"The rates and caps this directory admits work under, where each setting came from, and how much it admitted, refused, or coalesced.",
	empty: "This directory reports no work budgets.",
};
export const inspectLead =
	"What this directory holds, as the inspect capability sees it. Nothing on this page can be changed from here.";

/** Retained references, on the operator page. */
export const referencesMembership = "Room memberships";
export const referencesLine = "Direct messages";
export const referencesUpload = "Uploads in flight";
export const referencesForeignRoom = "Peered rooms";
export const referencesPendingPeering = "Peerings being set up";
export const referencesRegistration = "Nickname registrations";
export const referencesOfferedInbox = "Offered inboxes";
export const referencesSignaling = "Signaling routes";
export const referencesSignalExchange = "Signaling exchanges";
export const referencesTitle = "Retained references";
export const referencesLead =
	"Live connections this server is holding. Releasing one frees this server's copy and leaves anyone else's alone.";
export const referencesEmpty = "This server holds no independently releasable references.";
export function referencesSearchFor(label: string): string {
	return `Search this directory for ${label}`;
}
export const referenceReleaseEffect = "Frees this server's copy only.";
export const referenceRelease = "Release this server's copy";
export const referencesSweepSubject = "references";
export const referencesSweepEffect = "Only this server's copies are released. Whoever else holds one can still use it.";

/** The operator search box, and what the lists below it count. */
export const operatorSearching = "Searching this directory…";
export function operatorFilteredTo(kind: string): string {
	return `Retained references are filtered to the exact ${kind} kind.`;
}
export const operatorCountsAll = "Every list below counts what this directory holds.";
export function operatorCountsMatching(search: string): string {
	return `Every list below counts what matches “${search}”.`;
}

/** A sweep over a list, and how far it got. */
export function sweepStopped(retired: number, total: number, subject: string): string {
	return `Stopped after ${retired} of ${total} ${subject}.`;
}
export function sweepDone(past: string, retired: number, subject: string): string {
	return `${past} ${retired} ${subject}.`;
}
export function sweepRefused(firstRefusal: string, past: string, retired: number, subject: string): string {
	return `${firstRefusal} ${past} ${retired} ${subject} before the refusal.`;
}
export function sectionCountMore(count: number): string {
	return `${count} read so far, and more remain`;
}

/** The live trace page. */
export const tracePublisherShared = "The shared session publishes every connection it opens";
export const tracePublisherTab = "This tab publishes every session it opens";
export function traceLead(publisher: string): string {
	return `${publisher}, direct messages included, to the live timeline: who it talked to and when, never the words. Room messages show their contents, published by the room server from its side.`;
}
export const traceNowTitle = "Publishing now";
export const traceEndpointLabel = "Endpoint";

/** The listeners page. */
export const listenersLead = "Where this server accepts connections: one listener per transport, switched here.";
export function listenerTakeDown(transport: string): string {
	return `Take the ${transport} listener down`;
}
export function listenerBringUp(transport: string): string {
	return `Bring the ${transport} listener up`;
}
export function listenerCopyLocator(transport: string): string {
	return `Copy the ${transport} listener's locator`;
}

/** The peering page. */
export function peeringListedAs(name: string): string {
	return `Listed here as ${name}.`;
}
export const peeringLead = "List a durable room from another directory here, and revoke what this tab published.";
export const peeringPublishTitle = "Publish a room";
export const peeringNothingToPublish =
	"Nothing to publish yet. Hold a room link on another connected directory, and it will be offered here.";
export const peeringAsHint =
	"Anyone on this directory can enter it under that name. The room itself stays where it lives. The listing lasts until you revoke it or this directory connection ends.";
export const peeringPublishedTitle = "Published by this tab";
export const peeringPublishedEmpty = "No rooms published from this tab yet.";

/** The operations index and its permission note. */
export const opsEditCapabilitySet = "Edit operations links";
export const opsNeedsAdmin = "Only a link that can administer this session can change these.";
export const opsNotFoundTitle = "Nothing answers this address";
export function opsNotFoundSaid(segment: string): string {
	return `/ops/${segment} isn't one of the operations pages.`;
}
/** The sentence naming every pane, whole, so it reads in one place. Each
 * pane is passed through untouched, so the caller can make it a link. */
export function opsPanesSentence<T>(panes: readonly T[]): (T | string)[] {
	const parts: (T | string)[] = ["The pages are "];
	panes.forEach((pane, at) => {
		if (at > 0) parts.push(at < panes.length - 1 ? ", " : panes.length === 2 ? " and " : ", and ");
		parts.push(pane);
	});
	parts.push(". Each opens when this tab holds a link that fills it.");
	return parts;
}
export const opsIndex = "The operations index";
export const opsNothingHeld =
	"Nothing is held yet. Each page below opens when this tab takes its link from the server that issued it.";
export const opsBrowserTroubleTitle = "Browser trouble";

/** The IRC gateway page. Its nouns come from the server's form description,
 * so these sentences take them as arguments. */
export const gatewayPrimaryOnly = "Only the main action on this form is supported.";
export function gatewayNoneYet(connectionsNoun: string): string {
	return `No ${connectionsNoun} yet.`;
}
export function gatewayOpenOneBelow(leaseNoun: string): string {
	return `Open one below. A ${leaseNoun} isn't required.`;
}
export function gatewayNoLeases(leasesNoun: string, connectionNoun: string): string {
	return `No ${leasesNoun}. This ${connectionNoun} is kept, but not connected.`;
}
export function gatewayRemoveLeaseSay(label: string, lease: string, connection: string, say: string): string {
	return `${label} ${lease} from ${connection}? ${say}`;
}
export const gatewayOpenRoom = "Open room";
export function gatewayCloseLabel(connection: string): string {
	return `Close ${connection}`;
}
/** The button that asks before closing, so its label ends in an ellipsis. */
export function gatewayCloseAsk(connectionNoun: string): string {
	return `Close ${connectionNoun}…`;
}
/** Which server flag grants an operations capability. */
export function opsMintedWithFlag(flag: string): string {
	return `The server prints it when started with ${flag}.`;
}
export function gatewayDeleteSavedSay(connection: string, connectionNoun: string): string {
	return `Delete the saved ${connection} ${connectionNoun}?`;
}
export function gatewayDeleteWithLeasesSay(connectionNoun: string, count: number, leasesNoun: string): string {
	return `Delete this ${connectionNoun} and its ${count} bridged ${leasesNoun}?`;
}
export function gatewayKeep(connectionNoun: string): string {
	return `Keep ${connectionNoun}`;
}
export function gatewayClose(connectionNoun: string): string {
	return `Close ${connectionNoun}`;
}
