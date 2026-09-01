// The whole page, and the only place that decides what each layout is showing.
//
// Every class on the containers below is derived here from the store, in one
// expression each. The classes used to be the state: code asked the container
// whether it carried `show-list` to decide what a button should announce, and a
// separate handler re-applied a dozen of them whenever the window crossed the
// breakpoint. Nothing reads a class now, and crossing the breakpoint is just a
// different answer from `state.mobile`.

import * as store from "./store.ts";
import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useLocation } from "react-router";
import { useShallow } from "zustand/react/shallow";
import { useRoomsProjection, useRoomsState } from "./hooks.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { Sidebar } from "./Sidebar.tsx";
import { Topbar } from "./Topbar.tsx";
import { SessionEffectNotice } from "./SessionEffectNotice.tsx";
import { SessionPausedNotice } from "./SessionPausedNotice.tsx";
import { Stream } from "./Stream.tsx";
import { Members } from "./Members.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { Settings } from "./Settings.tsx";
import { Help } from "./Help.tsx";
import { opsAddressOf } from "./ops/address.ts";
import { DirectoryCard } from "./DirectoryCard.tsx";
import { MemberCard } from "./MemberCard.tsx";
import { ConvCard } from "./ConvCard.tsx";
import { ErrorDetail } from "./ErrorDetail.tsx";
import { Viewer } from "./Viewer.tsx";
import { Toasts } from "./Toast.tsx";
import { dirMarkIn, type LiveRooms, opsHeldOf, sendControlsFor } from "./types.ts";
import { directoryName, dirWhere, roomCalled } from "./text.ts";
import { useCapabilitySetModel } from "./settings/CapabilitySetModel.tsx";
import { mayInteract, mayObserve } from "../../lib/session/client.ts";
import { effectiveRoomsSessionAccess } from "./controller/access.ts";
import { loadOpsPage } from "./chunks.ts";
import { LoadingSurface } from "./Loading.tsx";
import { directoryDestinationContext } from "./joining.ts";

/** How long the "New messages" rule stays up once you have arrived. Long enough
 * to see where you left off, short enough not to become furniture. */
const UNREAD_RULE_MS = 1500;

// Shared empties, so a directory this tab does not hold yet draws as one with
// nothing in it rather than making every reader below handle null.
const EMPTY_PEERS: ReadonlySet<string> = new Set();
const EMPTY_ROOMS: LiveRooms = new Map();

const OpsMain = lazy(() => loadOpsPage().then((m) => ({ default: m.OpsMain })));

/** Unread total for the window title. Subscribes here so a line in another room
 * does not rebuild the shell. */
function DocumentTitle({ where }: { where: string }) {
	const unread = useRoomsState(store.unreadTotal);
	useEffect(() => {
		document.title = (unread > 0 ? "(" + unread + ") " : "") +
			(where ? where + " · " : "") + "pancake rooms";
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
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	// Where the address stands: on /ops the content cell shows the operations
	// surface instead of the conversation, and the rest of the shell stays
	// exactly what it was.
	const ops = opsAddressOf(useLocation().pathname);
	const mobile = state.mobile;
	const controller = browser.roomsController();
	const directoryContext = useMemo(
		() =>
			directoryDestinationContext(
				state.homeDir,
				session.directoryLocator(),
				(locator) => session.directoryId(locator),
			),
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
		? "Operations"
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
		const onKey = (e: KeyboardEvent) => {
			if (e.key !== "Escape") return;
			if (state.rosterSheet) store.closeRosterSheet(projection);
			else if (state.listScreen) store.showRail(projection, false);
		};
		addEventListener("keydown", onKey);
		return () => removeEventListener("keydown", onKey);
	}, [projection, state.rosterSheet, state.listScreen]);

	// Opening the list makes the conversation inert. If focus was in it, the
	// rail's own hide control is the named way back — `#cover` is a tap target,
	// not a third tab stop.
	useEffect(() => {
		if (!mobile || !state.listScreen) return;
		const active = document.activeElement;
		if (active instanceof HTMLElement && active.closest(".workarea")) {
			document.getElementById("railToggle")?.focus();
		}
	}, [mobile, state.listScreen]);

	// Read live from the line it names, so bytes arriving while the viewer is
	// open reach it rather than settling behind a copy taken when it opened.
	const capabilitySet = useCapabilitySetModel();
	const [helpLayer, setHelpLayer] = useState(false);
	const [dirLayer, setDirLayer] = useState(false);
	const [convLayer, setConvLayer] = useState(false);
	const [memberLayer, setMemberLayer] = useState(false);
	const onHelpLayer = useCallback((held: boolean) => setHelpLayer(held), []);
	const onDirLayer = useCallback((held: boolean) => setDirLayer(held), []);
	const onMemberLayer = useCallback((held: boolean) => setMemberLayer(held), []);
	const onConvLayer = useCallback((held: boolean) => setConvLayer(held), []);
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
	const settingsBlocked = state.helpOpen || capabilitySet.editing !== null || capabilitySet.modalLayer ||
		helpLayer || state.aboutDir !== null || dirLayer || state.aboutConv || convLayer ||
		state.aboutMember !== null || memberLayer;
	// The toggles and the Operations control mirror possession, whose one
	// authority is the row fields the data layer sets and clears.
	const opsHeld = opsHeldOf(
		state.listeners,
		state.diagnostics,
		state.irc,
		state.operator,
		state.peering,
		state.viz,
	);
	// What the peering pane could publish: rooms joined on a directory other
	// than this one. Memoised on the maps it reads, the same reason the roster
	// is: the pane sits behind a modal, and a keystroke must not rebuild it.
	// The directory this page came from: Settings still names its locator, and
	// a button there opens the same card a room caption would. Null when this
	// tab does not hold that session — before it has answered, or after Leave.
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
	// and would redraw the whole rail with them. The three fields it reads are
	// replaced only by the verbs that own them, so their identity is the exact
	// test for whether the store.answers can have moved.
	const joining = useMemo(
		() => store.answers(projection, state, directoryContext),
		[projection, state.reaching, state.edits, state.remembered, directoryContext],
	);

	// Leave persists `none` and reloads. That write can notify this tree before
	// the document unloads. Every hook above has already run, so drawing nothing
	// is not a crash card and not a change in hook order. The cover is already up.
	if (controller.kind === "none") return null;
	const access = effectiveRoomsSessionAccess(controller, state.sessionAccess);
	const canInteract = mayInteract(access);
	const sendControls = sendControlsFor(controller.kind);

	const appClass = ["app"];
	if (!state.railOpen) appClass.push("rooms-hidden");
	if (state.listScreen) appClass.push("show-list");
	if (state.rosterSheet) appClass.push("members-open");
	// Something is over the page. Each overlay above says which one it is, for
	// the rules that draw it; this says only that one is up, which is all the
	// page needs to know to hold still underneath. A new overlay adds itself
	// here and inherits that without going looking for what covering entails:
	// `settings.css`, beside the cover's own paint, is where that is decided.
	if (state.listScreen || state.rosterSheet) appClass.push("covered");
	// With no conversation open the join card is the workarea, and its own top
	// stripe stands in for the topbar's; the stylesheet reads this to put the
	// topbar's away rather than draw the same flourish twice on one screen.
	if (conv === null && !ops.on) appClass.push("joining");

	// The member column is the wide layout's preference, and a direct line has no
	// roster to show at all. The phone always leaves the column expanded here and
	// uses the sheet instead, which `members-open` above drives.
	const noMembers = ops.on || conv?.type === "dm" || conv?.type === "directory" ||
		(conv?.type === "room" && !mobile && !state.rosterOpen);
	const composerAvailability = !mayObserve(access)
		// Paused is not read-only, so this does not say read-only. Nor does it
		// repeat the bar standing above it: that one carries the state and the
		// reason it was given, and this one says what this control cannot do. Two
		// surfaces saying one sentence reads as the page saying it twice, rather
		// than as each answering for what it owns.
		? "You cannot send while your access is paused."
		: !canInteract
		? "This session capability is read only."
		: conv?.type === "dm" && conv.line === "closed"
		? "This direct conversation is closed."
		: directRegistrationChanged
		? "This nickname registration ended. Start a new conversation with its current holder."
		: activeDir != null && activeDir.session !== "connected" && activeDir.statusText !== ""
		? activeDir.statusText
		: conv?.type === "directory"
		? ""
		: conv?.type === "room" && conv.membership === "joined" && conv.membershipKind === "observer"
		? "You are here as an observer. An invitation to take part is what lets you post."
		: conv?.type !== "room" || conv.membership === "joined"
		? ""
		: conv.membership === "unavailable"
		? conv.membershipIssue !== ""
			? conv.membershipIssue
			: conv.held && conv.link == null
			? "You are not in this private room. Restore access with a current link."
			: "You are not in this room."
		: "Joining this room…";

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
				railShown={railShown}
				mobile={mobile}
				session={acting?.session ?? "connecting"}
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
								<Suspense fallback={<LoadingSurface what="operations" layout="page" />}>
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
									dirs={state.dirs}
									directoryContext={directoryContext}
									composerEnabled={canInteract && conv !== null &&
										(conv.type === "directory" ||
											(activeDir?.session === "connected" &&
												(conv.type === "room"
													? conv.membership === "joined"
													: !directRegistrationChanged && conv.line !== "closed")))}
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
				sessionAccess={state.sessionAccess}
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
					? state.irc?.bridged.find((bridge) => bridge.publicationId === conv.publicationId) ?? null
					: null}
				dir={conv === null ? null : state.dirs.get(conv.dir) ?? null}
				homeDir={state.homeDir}
				mark={conv === null ? undefined : dirMarkIn(conv.dir, state.homeDir, state.dirs)}
				standing={conv == null || conv.type !== "room"
					? ""
					: conv.standing ?? state.dirs.get(conv.dir)?.standing ?? state.standing}
				follows={conv === null ? "" : directoryName(conv.dir, state.homeDir)}
				online={directOnline}
				open={state.aboutConv && conv?.type !== "directory" && state.aboutDir === null && !dirLayer}
				retain={state.aboutConv}
				askingLeave={state.aboutConvLeave}
				onLayer={onConvLayer}
			/>
			<Viewer />
			<Toasts toasts={state.toasts} />
		</div>
	);
}
