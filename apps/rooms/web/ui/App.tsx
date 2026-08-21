// The whole page, and the only place that decides what each layout is showing.
//
// Every class on the containers below is derived here from the store, in one
// expression each. The classes used to be the state: code asked the container
// whether it carried `show-list` to decide what a button should announce, and a
// separate handler re-applied a dozen of them whenever the window crossed the
// breakpoint. Nothing reads a class now, and crossing the breakpoint is just a
// different answer from `state.mobile`.

import { useCallback, useEffect, useMemo, useState } from "react";
import { useStore } from "./hooks.ts";
import * as store from "./store.ts";
import { Sidebar } from "./Sidebar.tsx";
import { Topbar } from "./Topbar.tsx";
import { Stream } from "./Stream.tsx";
import { Members, rosterOf } from "./Members.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { Settings } from "./Settings.tsx";
import { Help } from "./Help.tsx";
import { Operations } from "./ops/Operations.tsx";
import { OpsTakeModal } from "./ops/Take.tsx";
import { DirectoryCard } from "./DirectoryCard.tsx";
import { Viewer } from "./Viewer.tsx";
import { Toasts } from "./Toast.tsx";
import { awayByPeer, awayOf, dirMarkIn, opsHeldOf } from "./types.ts";
import { directoryName, dirWhere, roomCalled } from "./text.ts";

/** How long the "New messages" rule stays up once you have arrived. Long enough
 * to see where you left off, short enough not to become furniture. */
const UNREAD_RULE_MS = 1500;

// Shared empties, so a directory this tab does not hold yet draws as one with
// nothing in it rather than making every reader below handle null.
const EMPTY_PEERS: ReadonlySet<string> = new Set();
const EMPTY_ROOMS: ReadonlyMap<string, number> = new Map();

export function App() {
	const state = useStore();
	const mobile = state.mobile;
	const returns = state.returns;
	const conv = state.activeKey === null ? null : state.convs.get(state.activeKey) ?? null;
	// What is half-written here, which belongs to this conversation and not to the
	// page: switching rooms leaves it behind and coming back finds it again.
	const draft = state.activeKey === null ? store.NO_DRAFT : state.drafts.get(state.activeKey) ?? store.NO_DRAFT;

	// Each layout reads its own field, so neither has to be told what the other
	// did and crossing between them needs no repair.
	const railShown = mobile ? state.listScreen : state.railOpen;
	const rosterShown = mobile ? state.rosterSheet : state.rosterOpen;
	const room = conv?.type === "room" ? conv : null;
	const unread = useMemo(() => {
		let total = 0;
		for (const c of state.convs.values()) {
			if (c.unread.kind === "unread") total += c.unread.count;
		}
		return total;
	}, [state.convs]);
	// The rosters' one word each on who is away, for the direct header's chip.
	const awayWords = useMemo(() => awayByPeer(state.convs), [state.convs]);

	// The remembered theme, stamped where the stylesheet reads it. page.html
	// stamps the same value before the first paint, so a cold load does not flash
	// the other palette on its way here.
	useEffect(() => {
		document.documentElement.dataset.theme = state.theme;
	}, [state.theme]);

	const where = conv ? (conv.type === "dm" ? "@" + conv.id : roomCalled(conv.id, conv.held)) : "";
	useEffect(() => {
		document.title = (unread > 0 ? "(" + unread + ") " : "") +
			(where ? where + " · " : "") + "pancake rooms";
	}, [unread, where]);

	// Coming back to the tab catches you up on the conversation you left open.
	useEffect(() => {
		if (returns === 0 || state.activeKey === null) return;
		store.markRead(state.activeKey);
	}, [returns, state.activeKey]);

	// The rule retires a moment after you arrive, however you arrived. This is its
	// own effect because arriving and coming back are different events: folding
	// the two together behind the return counter meant a tab that was never put
	// in the background never retired a rule at all, and it stayed up for the
	// life of the tab.
	useEffect(() => {
		const key = state.activeKey;
		if (key === null) return;
		const done = setTimeout(() => store.clearUnreadRule(key), UNREAD_RULE_MS);
		return () => clearTimeout(done);
	}, [returns, state.activeKey]);

	// Native dialogs own their Escape lifecycle. This chain covers the two
	// responsive layers that are part of the application layout rather than
	// dialogs. The rail's "+" fields consume their own Escape first.
	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key !== "Escape") return;
			if (state.rosterSheet) store.closeRosterSheet();
			else if (state.listScreen) store.showRail(false);
		};
		addEventListener("keydown", onKey);
		return () => removeEventListener("keydown", onKey);
	}, [state.rosterSheet, state.listScreen]);

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
	const viewed = store.viewedAttachment(state);
	const [helpLayer, setHelpLayer] = useState(false);
	const [opsLayer, setOpsLayer] = useState(false);
	const [opsTakeLayer, setOpsTakeLayer] = useState(false);
	const [dirLayer, setDirLayer] = useState(false);
	const onHelpLayer = useCallback((held: boolean) => setHelpLayer(held), []);
	const onOpsLayer = useCallback((held: boolean) => setOpsLayer(held), []);
	const onOpsTakeLayer = useCallback((held: boolean) => setOpsTakeLayer(held), []);
	const onDirLayer = useCallback((held: boolean) => setDirLayer(held), []);
	// The store state blocks Settings in the same commit that opens the next
	// layer. The held state keeps it blocked while that layer animates out.
	// Waiting for a child layout effect alone briefly leaves two modal dialogs
	// open, which gives the browser two competing focus traps.
	const settingsBlocked = state.helpOpen || state.opsOpen || state.opsTake !== null ||
		helpLayer || opsLayer || opsTakeLayer || state.aboutDir !== null || dirLayer;
	// The toggles and the Operations control mirror possession, whose one
	// authority is the three row fields the data layer sets and clears.
	const opsHeld = opsHeldOf(state.listeners, state.diagnostics, state.viz);
	// The directory this page came from: Settings still names its locator, and
	// a button there opens the same card a room caption would. Null when this
	// tab does not hold that session — before it has answered, or after Leave.
	const onDir = state.homeDir === null ? null : state.dirs.get(state.homeDir) ?? null;

	// Everything a directory says belongs to one directory, so the page reads it
	// from the one the open conversation is on. The join card, with nothing open,
	// reads the first this tab holds.
	const acting = store.actingDir(state);
	const activeDir = conv === null ? acting : state.dirs.get(conv.dir) ?? null;
	const dmablePeers = activeDir?.dmablePeers ?? EMPTY_PEERS;
	// The name is the directory's grant, so "am I this line's author" is answered
	// by the directory the conversation is in and by no other. Two directories
	// may each have granted an `alice`, and they are two people.
	const nick = activeDir?.nick ?? "";
	// Below the name, because the roster is read with the reader at the top of it
	// and the name is the directory's to grant. Memoised because the roster panes
	// are: rebuilding this array on every store change would make them redraw for
	// a keystroke, which is the one thing the memo above them exists to prevent.
	const roster = useMemo(() => rosterOf(room, nick), [room?.members, nick]);
	// What the join card would show, resolved once here from the act the reader
	// arrived by rather than read as fields. The rail's room panel is a second
	// view of the same card while the card is up, so both are given the one
	// answer instead of each reaching for the state behind it.
	//
	// Held across renders that cannot have changed it, because resolving builds
	// a fresh object and the rail is memoised on its props: recomputed every
	// render, the answers would be a new identity on every composer keystroke
	// and would redraw the whole rail with them. The three fields it reads are
	// replaced only by the verbs that own them, so their identity is the exact
	// test for whether the answers can have moved.
	const joining = useMemo(
		() => store.answers(state),
		[state.reaching, state.edits, state.remembered, state.homeDir],
	);

	const appClass = ["app"];
	if (!state.railOpen) appClass.push("rooms-hidden");
	if (state.listScreen) appClass.push("show-list");
	if (state.rosterSheet) appClass.push("members-open");
	// With no conversation open the join card is the workarea, and its own top
	// stripe stands in for the topbar's; the stylesheet reads this to put the
	// topbar's away rather than draw the same flourish twice on one screen.
	if (conv === null) appClass.push("joining");

	// The member column is the wide layout's preference, and a direct line has no
	// roster to show at all. The phone always leaves the column expanded here and
	// uses the sheet instead, which `members-open` above drives.
	const noMembers = conv?.type === "dm" ||
		(conv?.type === "room" && !mobile && !state.rosterOpen);

	return (
		<div className={appClass.join(" ")}>
			<Sidebar
				convs={state.convs}
				dirs={state.dirs}
				homeDir={state.homeDir}
				activeKey={state.activeKey}
				acting={acting?.id ?? null}
				join={joining}
				railShown={railShown}
				mobile={mobile}
				session={acting?.session ?? "connecting"}
				emptyDirs={store.emptyDirs(state)}
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
				   marks a room. What the colour answers is which directory a thing
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
				data-dir={conv === null ? "unknown" : dirWhere(conv.dir, state.homeDir, state.dirs).mark}
				inert={mobile && state.listScreen ? true : undefined}
			>
				<Topbar
					conv={conv}
					online={conv?.type === "dm" && dmablePeers.has(conv.id.toLowerCase())}
					away={conv?.type === "dm" ? awayOf(awayWords, conv.dir, conv.id) : null}
					unread={unread}
					mobile={mobile}
					railShown={railShown}
					rosterShown={rosterShown}
					memberCount={roster.online}
					settingsOpen={state.settingsOpen}
					standing={conv === null ? "" : store.standingFor(conv.key, state)}
					follows={conv === null ? "" : directoryName(conv.dir, state.homeDir)}
				/>
				<div className={noMembers ? "content no-members" : "content"} id="content">
					<Stream
						conv={conv}
						nick={nick}
						draft={draft.text}
						draftFiles={draft.files}
						changing={draft.changing}
						draftKeeping={draft.keeping}
						liveRooms={acting?.liveRooms ?? EMPTY_ROOMS}
						reachable={dmablePeers}
						join={joining}
						dirs={state.dirs}
						homeDir={state.homeDir}
						composerEnabled={conv !== null && activeDir?.session === "connected"}
						composerPhase={activeDir?.session ?? "disconnected"}
						ignored={state.ignored}
						mobile={mobile}
					/>
					<ErrorBoundary part="member list">
						<Members
							conv={room}
							roster={roster}
							nick={nick}
							dmablePeers={dmablePeers}
						/>
					</ErrorBoundary>
				</div>
			</div>
			<div
				id="cover"
				aria-hidden="true"
				onClick={() => {
					if (state.rosterSheet) store.closeRosterSheet();
					else if (state.listScreen) store.showRail(false);
				}}
			/>
			<Settings
				open={state.settingsOpen && !settingsBlocked}
				retain={state.settingsOpen}
				theme={state.theme}
				notifyOn={state.notifyOn}
				dir={onDir}
				opsHeld={opsHeld}
				opsOpen={state.opsOpen}
				tab={state.settingsTab}
			/>
			<Help
				open={state.helpOpen}
				theme={state.theme}
				notifyOn={state.notifyOn}
				onLayer={onHelpLayer}
			/>
			<Operations
				open={state.opsOpen}
				held={opsHeld}
				tab={state.opsTab}
				diagnostics={state.diagnostics}
				listeners={state.listeners}
				viz={state.viz}
				onLayer={onOpsLayer}
			/>
			<OpsTakeModal cap={state.opsTake} onLayer={onOpsTakeLayer} />
			<DirectoryCard
				dir={state.aboutDir === null ? null : state.dirs.get(state.aboutDir) ?? null}
				rooms={state.aboutDir === null ? 0 : store.joinedRooms(state.aboutDir).length}
				lines={state.aboutDir === null
					? 0
					: store.convsOn(state.aboutDir).filter((conv) => conv.type === "dm").length}
				mark={state.aboutDir === null ? undefined : dirMarkIn(state.aboutDir, state.homeDir, state.dirs)}
				standing={state.standing}
				homeDir={state.homeDir}
				onLayer={onDirLayer}
			/>
			<Viewer
				open={viewed !== null && state.viewing !== null}
				file={viewed}
				convKey={state.viewing?.key ?? ""}
			/>
			<Toasts toasts={state.toasts} />
		</div>
	);
}
