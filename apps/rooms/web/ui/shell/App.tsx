import { PRESENTATION, useProgress } from "../presentation.ts";
// The whole page, and the only place that decides what each layout is showing.
//
// Every class on the containers below is derived here from the store, in one
// expression each. Nothing reads a class back: a class is output, never state, so
// no code asks a container what it shows, and crossing the breakpoint is just a
// different answer from `state.mobile`.

import * as store from "../store.ts";
import { openingDirect } from "../../../lib/text/managed_session.ts";
import {
	cannotSendBridgeReadOnly,
	cannotSendDmClosed,
	cannotSendJoining,
	cannotSendNotInPrivateRoom,
	cannotSendNotInRoom,
	cannotSendObserver,
	cannotSendPaused,
	cannotSendReadOnly,
	cannotSendRegistrationEnded,
} from "../../../lib/text/conversation.ts";
import { lazy, Suspense, useCallback, useEffect, useMemo, useReducer } from "react";
import { useLocation } from "react-router";
import { useShallow } from "zustand/react/shallow";
import { useRoomsProjection, useRoomsState } from "../hooks.ts";
import { useRoomsController } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { Sidebar } from "./Sidebar.tsx";
import { Topbar } from "./Topbar.tsx";
import { SessionEffectNotice } from "../panes/SessionEffectNotice.tsx";
import { SessionPausedNotice } from "../panes/SessionPausedNotice.tsx";
import { Stream } from "../panes/Stream.tsx";
import { Members } from "../panes/Members.tsx";
import { ErrorBoundary } from "../ErrorBoundary.tsx";
import { Settings } from "../settings/Settings.tsx";
import { Help } from "../panes/Help.tsx";
import { opsAddressOf } from "../ops/address.ts";
import { DirectoryCard } from "../cards/DirectoryCard.tsx";
import { MemberCard } from "../cards/MemberCard.tsx";
import { ConvCard } from "../cards/ConvCard.tsx";
import { ErrorDetail } from "../panes/ErrorDetail.tsx";
import { Viewer } from "../panes/Viewer.tsx";
import { Toasts } from "../Toast.tsx";
import { type AdministeredBridge, dirMarkIn, type IrcGatewayState, type LiveRooms, sendControlsFor } from "../types.ts";
import { directoryName, dirWhere, roomCalled } from "../text.ts";
import { loadOpsPage } from "../chunks.ts";
import { LoadingSurface } from "../Loading.tsx";
import { directoryDestinationContext, resolveJoin } from "../joining.ts";
import { brandRoomsTitle } from "../../../lib/text/page.ts";
import { operationsLoadingNoun, operationsTitle } from "../../../lib/text/settings.ts";

/** How long the "New messages" rule stays up once you have arrived. Long enough
 * to see where you left off, short enough not to become furniture. */
const UNREAD_RULE_MS = 1500;

/** The four modal layers this shell hosts. Each card reports whether its
 * dialog is still held, animating out, after its content closed, and the
 * block rule below refuses Settings while any layer stands instead of it. */
type ShellLayer = "help" | "dir" | "conv" | "member";
type ShellLayerAction = { kind: "held"; layer: ShellLayer; held: boolean };
type ShellLayerState = Readonly<Record<ShellLayer, boolean>>;
const noLayerHeld: ShellLayerState = { help: false, dir: false, conv: false, member: false };

function shellLayerReducer(state: ShellLayerState, action: ShellLayerAction): ShellLayerState {
	return { ...state, [action.layer]: action.held };
}

// Shared empties, so a directory this tab does not hold yet draws as one with
// nothing in it rather than making every reader below handle null.
const EMPTY_PEERS: ReadonlySet<string> = new Set();
const EMPTY_ROOMS: LiveRooms = new Map();

const OpsMain = lazy(() => loadOpsPage().then((m) => ({ default: m.OpsMain })));

/** The bridge lease this room is, when the reader holds the gateway that owns
 * it: what the room's moderation surface needs to retire it. */
function administeredBridgeFor(
	gateway: IrcGatewayState | null,
	publicationId: string | undefined,
): AdministeredBridge | null {
	// An empty publication id is "no room yet" on a lease, not an identity, so it
	// must never match a room that also has none.
	if (gateway == null || publicationId == null || publicationId === "") return null;
	for (const connection of gateway.connections) {
		for (const lease of connection.leases) {
			if (lease.publicationId === publicationId) {
				return { connectionId: connection.id, leaseId: lease.id, publicationId };
			}
		}
	}
	return null;
}

/** Unread total for the window title. Subscribes here so a line in another room
 * does not rebuild the shell. */
function DocumentTitle({ where }: { where: string }) {
	const unread = useRoomsState(store.unreadTotal);
	useEffect(() => {
		document.title = (unread > 0 ? "(" + unread + ") " : "") +
			(where ? where + " · " : "") + brandRoomsTitle;
	}, [unread, where]);
	return null;
}

export function App() {
	// Drafts, last-sent recall, typing flags, room rosters, and the conversation
	// map subscribe where they are drawn. Including them here rebuilds Settings
	// and overlays for a peer's keystroke, a join, or a line in another room.
	const state = useRoomsState(useShallow(store.appShellState));
	const conv = useRoomsState(store.activeConvOf);
	const projection = useRoomsProjection();
	const session = useRoomsSession();
	// Where the address stands: on /ops the content cell shows the operations
	// surface instead of the conversation, and the rest of the shell stays
	// exactly what it was.
	const ops = opsAddressOf(useLocation().pathname);
	const mobile = state.mobile;
	const controller = useRoomsController();
	const directoryContext = useMemo(
		() =>
			directoryDestinationContext(
				state.homeDir,
				session.directoryLocator(),
				(locator) => session.directoryId(locator),
			),
		// The locator this asks the session for lives on the live checkpoint, not
		// in the store, so React cannot see it move and no dependency can name
		// it. `state.dirs` and `controller.kind` are what move when that
		// checkpoint's directory list does, which makes them the signal; they are
		// listed because they are the invalidation key, not because the body
		// reads them.
		// eslint-disable-next-line react-hooks/exhaustive-deps -- keyed on what moves the session's own directory list
		[state.homeDir, state.dirs, controller.kind],
	);
	const returns = state.returns;
	// What is half-written here, which belongs to this conversation and not to the
	// page: switching rooms leaves it behind and coming back finds it again.
	// Each layout reads its own field, so neither has to be told what the other
	// did and crossing between them needs no repair.
	const railShown = mobile ? state.listScreen : state.railOpen;
	const rosterShown = mobile ? state.rosterSheet : state.rosterOpen;
	const room = conv?.type === "room" ? conv : null;

	// The remembered theme, stamped where the stylesheet reads it. page.html
	// stamps the same value before the first paint, so a cold load does not flash
	// the other palette on its way here.
	useEffect(() => {
		document.documentElement.dataset.theme = state.theme;
		// The phone paints its own chrome around this page, and it takes the
		// colour from here. Read it back off the token the page paints with
		// rather than naming a colour twice: a palette that moves takes the
		// browser's bar with it, and the two cannot drift apart.
		const tint = document.querySelector('meta[name="theme-color"]');
		if (tint !== null) {
			const paper = getComputedStyle(document.documentElement).getPropertyValue("--paper").trim();
			if (paper !== "") tint.setAttribute("content", paper);
		}
	}, [state.theme]);

	const where = ops.on
		? operationsTitle
		: conv
		? (conv.type === "dm"
			? "@" + conv.id
			: conv.type === "directory"
			? directoryName(conv.dir, state.homeDir)
			: roomCalled(conv.id, conv.held))
		: "";

	// Coming back to the tab catches you up on the conversation you left open.
	useEffect(() => {
		if (returns === 0 || state.activeKey === null) return;
		store.markRead(projection, state.activeKey);
	}, [projection, returns, state.activeKey]);

	// The rule retires a moment after you arrive, however you arrived. This is its
	// own effect because arriving and coming back are different events: folding
	// the two together behind the return counter meant a tab that was never put
	// in the background never retired a rule at all, and it stayed up for the
	// life of the tab.
	useEffect(() => {
		const key = state.activeKey;
		if (key === null) return;
		const done = setTimeout(() => store.clearUnreadRule(projection, key), UNREAD_RULE_MS);
		return () => clearTimeout(done);
	}, [projection, returns, state.activeKey]);

	// Native dialogs own their Escape lifecycle. This chain covers the two
	// responsive layers that are part of the application layout rather than
	// dialogs. The rail's "+" fields consume their own Escape first.
	useEffect(() => {
		if (!mobile) return;
		const onKey = (e: KeyboardEvent) => {
			if (e.key !== "Escape") return;
			if (state.rosterSheet) store.closeRosterSheet(projection);
			else if (state.listScreen) store.showRail(projection, false);
		};
		addEventListener("keydown", onKey);
		return () => removeEventListener("keydown", onKey);
	}, [projection, mobile, state.rosterSheet, state.listScreen]);

	// Opening the list makes the conversation inert. If focus was in it, the
	// rail's own hide control is the named way back, `#cover` is a tap target,
	// not a third tab stop.
	useEffect(() => {
		if (!mobile || !state.listScreen) return;
		const active = document.activeElement;
		if (active instanceof HTMLElement && active.closest(".workarea")) {
			document.getElementById("railToggle")?.focus();
		}
	}, [mobile, state.listScreen]);

	const [layersHeld, dispatchLayer] = useReducer(shellLayerReducer, noLayerHeld);
	const onHelpLayer = useCallback((held: boolean) => dispatchLayer({ kind: "held", layer: "help", held }), []);
	const onDirLayer = useCallback((held: boolean) => dispatchLayer({ kind: "held", layer: "dir", held }), []);
	const onMemberLayer = useCallback((held: boolean) => dispatchLayer({ kind: "held", layer: "member", held }), []);
	const onConvLayer = useCallback((held: boolean) => dispatchLayer({ kind: "held", layer: "conv", held }), []);
	// A layer that stands *instead of* Settings blocks it in the same commit
	// that opens it, and the held state keeps it blocked while that layer
	// animates out. Waiting for a child layout effect alone briefly leaves two
	// modal dialogs open, which gives the browser two competing focus traps.
	//
	// The error card is not one of those. It is opened from a refusal inside
	// whichever layer the reader is already in, and it closes back onto that
	// refusal. Closing the layer under it would put that layer back into the
	// top layer *after* the card it opened from, so Settings would come back
	// standing over its own open manager card. Nested dialogs need no such
	// dance: the browser already makes everything under the topmost one inert.
	const settingsBlocked = state.helpOpen || layersHeld.help || state.aboutDir !== null || layersHeld.dir ||
		state.aboutConv || layersHeld.conv || state.aboutMember !== null || layersHeld.member;
	const opsHeld = state.opsHeld;
	// What the peering pane could publish: rooms joined on a directory other
	// than this one. Memoised on the maps it reads, the same reason the roster
	// is: the pane sits behind a modal, and a keystroke must not rebuild it.
	// The directory this page came from: Settings still names its locator, and
	// a button there opens the same card a room caption would. Null when this
	// tab does not hold that session, before it has answered, or after Leave.
	const onDir = state.homeDir === null ? null : state.dirs.get(state.homeDir) ?? null;

	// Everything a directory says belongs to one directory, so the page reads it
	// from the one the open conversation is on. The join card, with nothing open,
	// reads the first this tab holds.
	const acting = store.directoryHere(conv, state.dirs);
	const activeDir = conv === null ? acting : state.dirs.get(conv.dir) ?? null;
	const peerRegistrations = activeDir?.dmablePeers;
	const dmablePeers = useMemo(
		() => peerRegistrations == null ? EMPTY_PEERS : new Set(peerRegistrations.keys()),
		[peerRegistrations],
	);
	const currentDirectRegistration = conv?.type === "dm"
		? activeDir?.dmablePeers.get(conv.id.toLowerCase()) ?? null
		: null;
	const directOnline = conv?.type === "dm" &&
		currentDirectRegistration?.registrationId === conv.peerRegistrationId;
	const directRegistrationChanged = conv?.type === "dm" && currentDirectRegistration != null &&
		currentDirectRegistration.registrationId !== conv.peerRegistrationId;
	// The name is the directory's grant, so "am I this line's author" is answered
	// by the directory the conversation is in and by no other. Two directories
	// may each have granted an `alice`, and they are two people.
	const nick = activeDir?.nick ?? "";
	// What the join card would show, resolved once here from the act the reader
	// arrived by rather than read as fields. The rail's room panel is a second
	// view of the same card while the card is up, so both are given the one
	// answer instead of each reaching for the state behind it.
	//
	// Held across renders that cannot have changed it, because resolving builds
	// a fresh object and the rail is memoised on its props: recomputed every
	// render, the store.answers would be a new identity on every composer keystroke
	// and would redraw the whole rail with them.
	//
	// The fields go in one at a time rather than as the whole `state`, because
	// the dependency list below is the claim that nothing else can move the
	// answer. Passing `state` made that a claim about another function's body,
	// kept true by a comment; `answers` already declares what it reads in its
	// own signature, so handing it exactly that makes the compiler the one
	// holding the two in step. Widening what `answers` reads fails here
	// instead of quietly returning a held answer.
	const { homeDir, reaching, edits, remembered } = state;
	const joining = useMemo(
		() => store.answers(projection, { homeDir, reaching, edits, remembered }, directoryContext),
		[projection, homeDir, reaching, edits, remembered, directoryContext],
	);
	const joinResolution = useMemo(
		() => resolveJoin(joining, state.dirs, state.homeDir, (locator) => session.directoryId(locator)),
		[joining, state.dirs, state.homeDir, session],
	);

	// Leave persists `none` and reloads. That write can notify this tree before
	// the document unloads. Every hook above has already run, so drawing nothing
	// is not a crash card and not a change in hook order. The cover is already up.
	const openingHere = conv?.type === "dm" && state.navigationTarget?.kind === "direct" &&
		state.navigationTarget.peer === conv.id;
	const openingProgress = useProgress(openingHere, PRESENTATION.busy, conv?.key);
	const joiningProgress = useProgress(
		conv?.type === "room" && conv.membership === "joining",
		PRESENTATION.connection,
		conv?.key,
	);
	if (controller.kind === "none") return null;
	const permissions = state.managedAccess.status === "active"
		? state.managedAccess.effective?.permissions
		: undefined;
	const canInteract = permissions?.includes("interactWorkspace") === true;
	const sendControls = sendControlsFor(controller.kind);

	const appClass = ["app"];
	if (!state.railOpen) appClass.push("rooms-hidden");
	if (mobile && state.listScreen) appClass.push("show-list");
	if (mobile && state.rosterSheet) appClass.push("members-open");
	// Something is over the page. Each overlay above says which one it is, for
	// the rules that draw it; this says only that one is up, which is all the
	// page needs to know to hold still underneath. A new overlay adds itself
	// here and inherits that without going looking for what covering entails:
	// `settings.css`, beside the cover's own paint, is where that is decided.
	if (mobile && (state.listScreen || state.rosterSheet)) appClass.push("covered");
	// With no conversation open the join card is the workarea, and its own top
	// stripe stands in for the topbar's; the stylesheet reads this to put the
	// topbar's away rather than draw the same flourish twice on one screen.
	if (conv === null && !ops.on) appClass.push("joining");

	// The member column is the wide layout's preference, and a direct line has no
	// roster to show at all. The phone always leaves the column expanded here and
	// uses the sheet instead, which `members-open` above drives.
	const noMembers = ops.on || conv?.type === "dm" || conv?.type === "directory" ||
		(conv?.type === "room" && !mobile && !state.rosterOpen);
	// A direct line still being opened has no route yet, so only its own
	// composer waits; every other conversation stays open to write in.
	const composerAvailability = permissions?.includes("observeWorkspace") !== true
		// Paused is not read-only, so this does not say read-only. Nor does it
		// repeat the bar standing above it: that one carries the state and the
		// reason it was given, and this one says what this control cannot do. Two
		// surfaces saying one sentence reads as the page saying it twice, rather
		// than as each answering for what it owns.
		? cannotSendPaused
		: openingHere
		? openingProgress ? openingDirect(conv.id) : ""
		: !canInteract
		? cannotSendReadOnly
		: conv?.type === "dm" && conv.line === "closed"
		? cannotSendDmClosed
		: directRegistrationChanged
		? cannotSendRegistrationEnded
		: conv?.type === "directory" && activeDir != null && activeDir.session !== "connected" &&
				activeDir.statusText !== ""
		? activeDir.statusText
		: conv?.type === "directory"
		? ""
		// An observer seat on a bridged room is the bridge running one way, so
		// it is said in the bridge's terms: no invitation would change it.
		: conv?.type === "room" && conv.membership === "joined" && conv.membershipKind === "observer"
		? (conv.bridge === undefined ? cannotSendObserver : cannotSendBridgeReadOnly(conv.bridge.badge))
		: conv?.type !== "room" || conv.membership === "joined"
		? ""
		: conv.membership === "unavailable"
		? conv.membershipIssue !== ""
			? conv.membershipIssue
			: conv.held && conv.linkToken == null
			? cannotSendNotInPrivateRoom
			: cannotSendNotInRoom
		: joiningProgress
		? cannotSendJoining
		: "";

	return (
		<div className={appClass.join(" ")}>
			<DocumentTitle where={where} />
			<Sidebar
				canInteract={canInteract}
				cardUp={conv === null && !ops.on}
				dirs={state.dirs}
				homeDir={state.homeDir}
				directoryContext={directoryContext}
				activeKey={ops.on ? null : state.activeKey}
				acting={acting?.id ?? null}
				join={joining}
				joinResolution={joinResolution}
				railShown={railShown}
				mobile={mobile}
				standing={state.standing}
				invites={state.invites}
				settingsOpen={state.settingsOpen}
			/>
			{
				/* The colour the chat side is drawn in, which is the colour the rail
				   row that opened it wears. Read through the same `dirWhere` that row
				   reads, so the two cannot come to disagree rather than merely
				   agreeing today: a reader picks a row and the conversation arrives
				   in the colour they just pressed.

				   A direct line is included, because the rail marks one exactly as it
				   marks a room. What the colour store.answers is which directory a thing
				   is on, and a direct line is on one. Undefined whenever the rail is
				   showing no colours at all, so the chat side never draws a
				   distinction a reader cannot also see beside it.

				   With no conversation open there is no directory to name, which is
				   the same "unknown" the join card wears when it is aimed at an
				   address this tab does not hold. Saying so rather than saying
				   nothing is what lets the bar keep its stripe on the way in. */
			}
			<div
				className="workarea"
				data-dir={ops.on || conv === null ? "unknown" : dirWhere(conv.dir, state.homeDir, state.dirs).mark}
				inert={mobile && state.listScreen ? true : undefined}
			>
				<Topbar
					canInteract={canInteract}
					conv={conv}
					ops={ops.on}
					online={directOnline}
					mobile={mobile}
					railShown={railShown}
					rosterShown={rosterShown}
					settingsOpen={state.settingsOpen}
					standing={conv == null
						? ""
						: conv.type === "room"
						? conv.standing ?? state.dirs.get(conv.dir)?.standing ?? state.standing
						: state.standing}
					follows={conv === null ? "" : directoryName(conv.dir, state.homeDir)}
					aboutConv={state.aboutConv}
					aboutDir={state.aboutDir !== null}
				/>
				<SessionPausedNotice />
				<SessionEffectNotice />
				<div className={noMembers ? "content no-members" : "content"} id="content">
					{ops.on
						? (
							<ErrorBoundary part="operations">
								<Suspense fallback={<LoadingSurface what={operationsLoadingNoun} layout="page" />}>
									<OpsMain segment={ops.segment} />
								</Suspense>
							</ErrorBoundary>
						)
						: (
							<>
								<Stream
									canInteract={canInteract}
									conv={conv}
									nick={nick}
									liveRooms={acting?.liveRooms ?? EMPTY_ROOMS}
									reachable={dmablePeers}
									join={joining}
									joinResolution={joinResolution}
									dirs={state.dirs}
									directoryContext={directoryContext}
									composerEnabled={canInteract && conv !== null && !openingHere &&
										(conv.type === "directory" ||
											(conv.type === "room"
												? conv.membership === "joined"
												: !directRegistrationChanged && conv.line === "live"))}
									composerPhase={activeDir?.session ?? "disconnected"}
									composerAvailability={composerAvailability}
									ignored={state.ignored}
									sendControls={sendControls}
									mobile={mobile}
								/>
								<ErrorBoundary part="member list">
									<Members
										canInteract={canInteract}
										conv={room}
										nick={nick}
										dmablePeers={dmablePeers}
									/>
								</ErrorBoundary>
							</>
						)}
				</div>
			</div>
			<div
				id="cover"
				aria-hidden="true"
				onClick={() => {
					if (!mobile) return;
					if (state.rosterSheet) store.closeRosterSheet(projection);
					else if (state.listScreen) store.showRail(projection, false);
				}}
			/>
			<Settings
				open={state.settingsOpen && !settingsBlocked}
				retain={state.settingsOpen}
				theme={state.theme}
				notifyOn={state.notifyOn}
				dir={onDir}
				opsHeld={opsHeld}
				keepHistory={state.keepHistory}
				archiveTarget={state.archiveTarget}
				tab={state.settingsTab}
			/>
			<Help
				open={state.helpOpen}
				retain={state.helpOpen}
				theme={state.theme}
				notifyOn={state.notifyOn}
				onLayer={onHelpLayer}
			/>
			<DirectoryCard
				canInteract={canInteract}
				dir={state.aboutDir === null ? null : state.dirs.get(state.aboutDir) ?? null}
				mark={state.aboutDir === null ? undefined : dirMarkIn(state.aboutDir, state.homeDir, state.dirs)}
				standing={state.standing}
				homeDir={state.homeDir}
				askingLeave={state.aboutDirLeave}
				onLayer={onDirLayer}
			/>
			<MemberCard
				canInteract={canInteract}
				about={state.aboutMember}
				onLayer={onMemberLayer}
			/>
			<ErrorDetail
				title={state.errorDetail?.title ?? null}
				text={state.errorDetail?.text ?? null}
			/>
			<ConvCard
				canInteract={canInteract}
				conv={state.aboutConv && conv != null && conv.type !== "directory" ? conv : null}
				archiveShares={conv == null || conv.type === "directory"
					? []
					: state.archiveShares.filter((share) => share.conversationKey === conv.key)}
				initialPane={state.aboutConvPane}
				request={state.aboutConvRequest}
				administeredBridge={conv?.type === "room" && conv.dir === state.homeDir
					? administeredBridgeFor(state.irc, conv.publicationId)
					: null}
				dir={conv === null ? null : state.dirs.get(conv.dir) ?? null}
				homeDir={state.homeDir}
				mark={conv === null ? undefined : dirMarkIn(conv.dir, state.homeDir, state.dirs)}
				standing={conv == null || conv.type !== "room"
					? ""
					: conv.standing ?? state.dirs.get(conv.dir)?.standing ?? state.standing}
				follows={conv === null ? "" : directoryName(conv.dir, state.homeDir)}
				online={directOnline}
				open={state.aboutConv && conv?.type !== "directory" && state.aboutDir === null && !layersHeld.dir}
				retain={state.aboutConv}
				askingLeave={state.aboutConvLeave}
				onLayer={onConvLayer}
			/>
			<Viewer />
			<Toasts toasts={state.toasts} />
		</div>
	);
}
