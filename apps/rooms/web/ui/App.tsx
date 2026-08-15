// The whole page, and the only place that decides what each layout is showing.
//
// Every class on the containers below is derived here from the store, in one
// expression each. The classes used to be the state: code asked the container
// whether it carried `show-list` to decide what a button should announce, and a
// separate handler re-applied a dozen of them whenever the window crossed the
// breakpoint. Nothing reads a class now, and crossing the breakpoint is just a
// different answer from `state.mobile`.

import { useEffect, useMemo } from "react";
import { useStore } from "./hooks.ts";
import * as store from "./store.ts";
import { Sidebar } from "./Sidebar.tsx";
import { Topbar } from "./Topbar.tsx";
import { Stream } from "./Stream.tsx";
import { Members, rosterOf } from "./Members.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { Settings } from "./Settings.tsx";
import { DirectoryCard } from "./DirectoryCard.tsx";
import { Viewer } from "./Viewer.tsx";
import { dirsAreMarked } from "./types.ts";

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
	// Memoised because the roster panes are: rebuilding this array on every store
	// change would make them redraw for a keystroke, which is the one thing the
	// memo above them exists to prevent.
	const room = conv?.type === "room" ? conv : null;
	const roster = useMemo(() => rosterOf(room), [room?.members]);
	const unread = useMemo(() => {
		let total = 0;
		for (const c of state.convs.values()) {
			if (c.unread.kind === "unread") total += c.unread.count;
		}
		return total;
	}, [state.convs]);

	// The remembered theme, stamped where the stylesheet reads it. page.html
	// stamps the same value before the first paint, so a cold load does not flash
	// the other palette on its way here.
	useEffect(() => {
		document.documentElement.dataset.theme = state.theme;
	}, [state.theme]);

	const where = conv ? (conv.type === "dm" ? "@" + conv.id : "#" + conv.id) : "";
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

	// Read live from the line it names, so bytes arriving while the viewer is
	// open reach it rather than settling behind a copy taken when it opened.
	const viewed = store.viewedAttachment(state);
	// The directory this page came from, which is the one Settings describes and
	// the only one it ever describes. Not the one being read: a room somewhere
	// else is described by its own card, and Settings answering about whichever
	// conversation was on screen is how "this directory" came to mean two things.
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

	const appClass = ["app"];
	if (!state.railOpen) appClass.push("rooms-hidden");
	if (state.listScreen) appClass.push("show-list");
	if (state.rosterSheet) appClass.push("members-open");

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
				railShown={railShown}
				mobile={mobile}
				session={acting?.session ?? "connecting"}
				statusText={acting?.statusText ?? "connecting…"}
				emptyDirs={store.emptyDirs(state)}
			/>
			<div className="workarea">
				<Topbar
					conv={conv}
					online={conv?.type === "dm" && dmablePeers.has(conv.id.toLowerCase())}
					unread={unread}
					mobile={mobile}
					railShown={railShown}
					rosterShown={rosterShown}
					memberCount={roster.online}
					settingsOpen={state.settingsOpen}
				/>
				<div className={noMembers ? "content no-members" : "content"} id="content">
					<Stream
						conv={conv}
						nick={nick}
						banner={state.banner}
						draft={draft.text}
						draftFiles={draft.files}
						changing={draft.changing !== undefined}
						liveRooms={acting?.liveRooms ?? EMPTY_ROOMS}
						draftRoom={state.draftRoom}
						draftLocator={state.draftLocator}
						draftNick={state.draftNick}
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
			<div id="sheetScrim" aria-hidden="true" onClick={() => store.closeRosterSheet()} />
			<Settings
				open={state.settingsOpen}
				theme={state.theme}
				notifyOn={state.notifyOn}
				dir={onDir}
				rooms={onDir === null ? 0 : store.joinedRooms(onDir.id).length}
			/>
			<DirectoryCard
				dir={state.aboutDir === null ? null : state.dirs.get(state.aboutDir) ?? null}
				rooms={state.aboutDir === null ? 0 : store.joinedRooms(state.aboutDir).length}
				lines={state.aboutDir === null
					? 0
					: store.convsOn(state.aboutDir).filter((conv) => conv.type === "dm").length}
				marked={dirsAreMarked(state.dirs)}
			/>
			{viewed !== null && state.viewing !== null && <Viewer file={viewed} convKey={state.viewing.key} />}
		</div>
	);
}
