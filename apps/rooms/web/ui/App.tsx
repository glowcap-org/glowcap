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

/** How long the "New messages" rule stays up once you have arrived. Long enough
 * to see where you left off, short enough not to become furniture. */
const UNREAD_RULE_MS = 1500;

export function App() {
	const state = useStore();
	const mobile = state.mobile;
	const returns = state.returns;
	const conv = store.getConv(state.activeKey);

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

	// Escape dismisses whichever overlay is up, innermost first. The rail's "+"
	// fields handle their own Escape and stop it there, so this only ever sees a
	// press nothing nearer has claimed.
	useEffect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key !== "Escape") return;
			if (state.rosterSheet) store.closeRosterSheet();
			else if (state.listScreen) store.showRail(false);
		};
		addEventListener("keydown", onKey);
		return () => removeEventListener("keydown", onKey);
	}, [state.rosterSheet, state.listScreen]);

	const appClass = ["app"];
	if (state.joinedRoom !== null) appClass.push("joined");
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
				liveRooms={state.liveRooms}
				dmablePeers={state.dmablePeers}
				joinedRoom={state.joinedRoom}
				activeKey={state.activeKey}
				railShown={railShown}
				session={state.session}
				statusText={state.statusText}
			/>
			<div className="workarea">
				<Topbar
					conv={conv}
					online={conv?.type === "dm" && state.dmablePeers.has(conv.id.toLowerCase())}
					unread={unread}
					mobile={mobile}
					railShown={railShown}
					rosterShown={rosterShown}
					memberCount={roster.online}
					theme={state.theme}
					notifyOn={state.notifyOn}
				/>
				<div className={noMembers ? "content no-members" : "content"} id="content">
					<Stream
						conv={conv}
						nick={state.nick}
						banner={state.banner}
						draft={state.draft}
						draftRoom={state.draftRoom}
						draftNick={state.draftNick}
						composerEnabled={conv !== null && state.session === "connected"}
						mobile={mobile}
					/>
					<ErrorBoundary part="member list">
						<Members
							conv={room}
							roster={roster}
							nick={state.nick}
							dmablePeers={state.dmablePeers}
						/>
					</ErrorBoundary>
				</div>
			</div>
			<div id="sheetScrim" aria-hidden="true" onClick={() => store.closeRosterSheet()} />
		</div>
	);
}
