// The operator capabilities: what each one is, and what holding it does.
//
// These are the one place in Rooms where precision beats plainness. A reader
// here is matching a word against a flag a server printed, and softening the
// vocabulary would only make them guess. What they get instead of simpler
// words is a straight answer about what turning each one on actually does,
// since that is the decision in front of them.
//
// Every row used to open "Holding it …", which is six sentences with the same
// shape and the same subject, and every row carried the same `how` sentence
// word for word. The repetition read as a form letter.

export const opsListenersLabel = "Administer listeners";
export const opsListenersShort = "Listeners";
export const opsListenersLead = "Lists this server's live listeners and lets you bring them up or down.";

export const opsDiagnosticsLabel = "Inspect this server";
export const opsDiagnosticsShort = "Inspect";
export const opsDiagnosticsLead = "Lists what this server is currently holding.";

export const opsIrcLabel = "IRC gateway";
export const opsIrcShort = "IRC";
export const opsIrcLead = "Bridges IRC channels into this server as ordinary rooms.";

export const opsOperatorLabel = "Rooms operator";
export const opsOperatorShort = "Operator";
export const opsOperatorLead = "Lists and changes the authorities, names and live sessions this server has issued.";

export const opsPeeringLabel = "Directory peering";
export const opsPeeringShort = "Peering";
export const opsPeeringLead = "Lists a durable room from another server here, for this connection.";

/** The one toggle with a privacy consequence, so it says so in the sentence
 * somebody reads before flipping it rather than in a doc.
 *
 * What a browser publishes is the field list in
 * `rust/runtime/src/session_service/trace/publish.rs`: who the session talked
 * to, over what, which operations ran and how big they were. Message bytes are
 * not in that list, and saying "not the text" is only honest because of it. If
 * that list ever grows a payload field, this sentence is wrong and has to move
 * with it. */
export const opsTraceLabel = "Live trace";
export const opsTraceShort = "Trace";
export const opsTraceLead =
	"Publishes which peers this session talks to and what it does with them, direct messages included. Not the text of your messages.";

/** How a pasted swiss is redeemed. Five of the six go to the server this page
 * is already talking to; the trace goes to its own endpoint, which is why it
 * is the one that differs. */
export const opsHowSession = "Paste it here and Rooms fetches the capability on this server's session.";
export const opsHowTrace = "Paste it here and Rooms presents it to the trace endpoint.";

/** Holdings, where the toggles live. It draws a line between holding something
 * now and having saved it for next time, and the lead is where that line gets
 * named. */
export const holdingsSharedLead =
	"This shared session is holding live capabilities. The links below are saved so they can be taken again.";
export const holdingsLocalLead =
	"This session is holding live capabilities. The links below are saved so they can be taken again.";
export const holdingsSetChanged = "The saved capability set changed. Your unsaved edits are still here.";
export const holdingsSetSaved = "Capability set saved.";
export const holdingsEditAsText = "Edit capability set as text";
export const holdingsEditAsControls = "Edit capability set as controls";

/** Why a trace endpoint somebody typed cannot be used. The value is never
 * rewritten to make it work: an operator who typed an address wants to know
 * what is wrong with the one they typed. */
export const traceEndpointWhitespace = "The trace endpoint can't start or end with a space.";
export const traceEndpointNotUrl = "The trace endpoint has to be a complete WebSocket URL.";
export const traceEndpointScheme = "The trace endpoint has to use ws:// or wss://.";
export const traceEndpointFragment = "The trace endpoint can't have a # on the end.";
export const traceEndpointSaveRefused = "Couldn't save the trace endpoint.";

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
export const opsOperatorStateLoading = "operator state";
export const opsDirectoryHoldingsLoading = "what this directory holds";
export const opsOperatorPane = "operator pane";
export const opsInspectPane = "inspect pane";

/** Destinations in the operations navigation. */
export const opsPaneListeners = "Listeners";
export const opsPaneDirectory = "Directory";
export const opsPaneIrc = "IRC";
export const opsPanePeering = "Peering";
export const opsPaneVisualizer = "Visualizer";

/** The Inspect pane: each inventory it reads, what it is, and what an empty
 * one says. Inspect sees that a thing stands, never the thing. */
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
	title: "Names and reachability",
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
	title: "Room moderator authority",
	lead:
		"Rooms this server can grant moderation over. Inspect sees whether a capability is out, never the capability.",
	empty: "This server owns no rooms right now.",
};
export const inspectBootstrap: OpsInspectSection = {
	title: "Published bootstrap",
	lead: "What this directory answers to on the wire.",
	empty: "This directory publishes no bootstrap.",
};
export const inspectTrouble: OpsInspectSection = {
	title: "Directory trouble",
	lead: "The same bounded process journal the server writes as it runs.",
	empty: "No trouble reported.",
};
export const inspectLead =
	"What this directory holds, as the inspect capability sees it. Nothing on this page can be changed from here.";

/** Retained references, on the operator pane. */
export const referencesMembership = "Room memberships";
export const referencesLine = "Direct lines";
export const referencesUpload = "Uploads in flight";
export const referencesForeignRoom = "Peered rooms";
export const referencesPendingPeering = "Peerings being set up";
export const referencesRegistration = "Nickname registrations";
export const referencesOfferedInbox = "Offered inboxes";
export const referencesSignaling = "Signaling routes";
export const referencesSignalExchange = "Signaling exchanges";
export const referencesTitle = "Retained references";
export const referencesLead =
	"These are individual live references held by this server. Releasing one updates its owner here without revoking copies held by remote peers.";
export const referencesEmpty = "This server holds no independently releasable references.";
export function referencesSearchFor(label: string): string {
	return `Search this directory for ${label}`;
}
export const referenceReleaseEffect =
	"Only this server's copy is released. Remote holders keep their copies and their authority.";
export const referenceRelease = "Release retained reference";
export const referencesSweepSubject = "references";
export const referencesSweepEffect =
	"Only this server's copies are released. Remote holders keep their copies and their authority.";

/** The operator search box, and what the inventories below it count. */
export const operatorSearching = "Searching this directory…";
export function operatorFilteredTo(kind: string): string {
	return `Retained references are filtered to the exact ${kind} kind.`;
}
export const operatorCountsAll = "Every inventory below counts what this directory holds.";
export function operatorCountsMatching(search: string): string {
	return `Every inventory below counts what matches “${search}”.`;
}

/** A sweep over an inventory, and how far it got. */
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

/** The live trace pane. */
export const tracePublisherShared = "The shared session publishes every connection it opens";
export const tracePublisherTab = "This tab publishes every session it opens";
export function traceLead(publisher: string): string {
	return `${publisher}, direct messages included, to the live timeline. What leaves here is who it talked to and when, never the words. Room messages still show their contents on the timeline, published by the room server from its own side. A direct message has no server in the middle, so its words go nowhere.`;
}
export const traceNowTitle = "Publishing now";
export const traceEndpointLabel = "Endpoint";
export const traceElsewhereTitle = "Publish somewhere else";
export const traceEndpointHint =
	"Leave blank to publish to this page's own endpoint (/trace). Saving reloads this window, and the new endpoint asks for its own capability.";

/** The listeners pane. */
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

/** The peering pane. */
export function peeringListedAs(name: string): string {
	return `Listed here as ${name}.`;
}
export const peeringLead = "List a durable room from another directory here, and revoke what this tab published.";
export const peeringPublishTitle = "Publish a room";
export const peeringNothingToPublish =
	"Nothing to publish yet. Join a room on another directory first, and it will be offered here.";
export const peeringAsHint =
	"Anyone on this directory can enter it under that name. The room itself stays where it lives. The listing lasts until you revoke it or this directory connection ends.";
export const peeringPublishedTitle = "Published by this tab";
export const peeringPublishedEmpty = "No rooms published from this tab yet.";

/** The operations index and its gate. */
export const opsEditCapabilitySet = "Edit capability set";
export const opsNeedsAdmin = "An administrator session capability is required to change this set.";
export const opsNotFoundTitle = "Nothing answers this address";
export function opsNotFoundSaid(segment: string): string {
	return `/ops/${segment} names no operations pane.`;
}
export const opsPanesAre = "The panes are";
export const opsPanesJoin = ", ";
export const opsPanesJoinLast = ", and ";
export const opsPanesEach = ". Each opens when this tab holds a capability that fills it.";
export const opsIndex = "The operations index";
export const opsNothingHeld =
	"Nothing is held yet. Each pane below opens when this tab takes its capability from the server that minted it.";
export const opsBrowserTroubleTitle = "Browser trouble";

/** The IRC gateway pane. Its nouns come from the server's own form
 * description, so these sentences take them as words. */
export const gatewayPrimaryOnly = "Only the main action on this form works yet.";
export function gatewayNoneYet(connectionsNoun: string): string {
	return `No ${connectionsNoun} yet.`;
}
export function gatewayOpenOneBelow(leaseNoun: string): string {
	return `Open one below. A ${leaseNoun} is not required.`;
}
export function gatewayNoLeases(leasesNoun: string, connectionNoun: string): string {
	return `No ${leasesNoun}. This ${connectionNoun} is retained without a live transport.`;
}
export function gatewayRemoveLeaseSay(label: string, lease: string, connection: string, say: string): string {
	return `${label} ${lease} from ${connection}? ${say}`;
}
export const gatewayOpenRoom = "Open room";
export function gatewayCloseLabel(connection: string): string {
	return `Close ${connection}`;
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
