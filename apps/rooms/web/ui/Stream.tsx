// The conversation column: the log, the join card, the jump-to-latest button,
// and the composer.
//
// This is where scrolling is owned, and it is owned in one place because the
// region that scrolls is not the same element on both layouts. On a wide screen
// the log is its own overflow area; on a phone the whole document scrolls, the
// way a native chat does. Every read and every write goes through `scroller`, so
// there is one answer to "where are we" rather than one per caller.

import type React from "react";
import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { Conv, DirId, DirView, LiveRooms, SendControlPolicy, SessionPhase } from "./types.ts";
import type { DirectoryDestinationContext, JoinAnswers } from "./joining.ts";
import { Log } from "./Log.tsx";
import { Composer } from "./Composer.tsx";
import { JoinCard } from "./JoinCard.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { RichText } from "./RichText.tsx";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { IconButton } from "./IconButton.tsx";
import { useRoomsState } from "./hooks.ts";
import { NO_DRAFT } from "./store.ts";

// How close to the end still counts as "reading the newest message".
const AT_BOTTOM_SLACK = 80;

export function Stream(
	{
		canInteract,
		conv,
		nick,
		liveRooms,
		reachable,
		join,
		dirs,
		directoryContext,
		composerEnabled,
		composerPhase,
		composerAvailability,
		ignored,
		sendControls,
		mobile,
	}: {
		canInteract: boolean;
		conv: Conv | null;
		nick: string;
		liveRooms: LiveRooms;
		reachable: ReadonlySet<string>;
		/** Every join-card field with the evidence behind it, resolved from the
		 * act the reader arrived by. */
		join: JoinAnswers;
		/** Passed straight through to the join card, which offers the directories
		 * this tab already holds under its locator field. */
		dirs: ReadonlyMap<DirId, DirView>;
		directoryContext: DirectoryDestinationContext;
		composerEnabled: boolean;
		/** What the conversation's directory is doing, for the field to say when it
		 * cannot be used. */
		composerPhase: SessionPhase;
		composerAvailability: string;
		/** Names this window is not showing, straight through to the log. */
		ignored: ReadonlySet<string>;
		sendControls: SendControlPolicy;
		mobile: boolean;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const draft = useRoomsState((state) => conv == null ? NO_DRAFT : state.drafts.get(conv.key) ?? NO_DRAFT);
	const log = useRef<HTMLElement>(null);
	// Whether the reader was at the end of the conversation before whatever just
	// happened. Content growing does not raise a scroll event, so this is read at
	// scroll time and consulted afterwards: it answers "were they pinned", which is
	// the question, rather than "are they pinned now", which is always false the
	// moment a message lands.
	const pinned = useRef(true);
	// The conversation on screen, read through a ref rather than depended on.
	// Every store change replaces it — a member coming online, a keystroke in the
	// composer — and its readers below measure the scroll region, which forces
	// layout. Only arriving somewhere new, and a line landing, are worth that.
	const latest = useRef(conv);
	latest.current = conv;
	// Where each conversation was left, so coming back to one returns you to the
	// message you were reading rather than to the bottom. One number per
	// conversation this tab has visited, and nothing removes a row when a
	// conversation is closed: the cost is bounded by how many conversations a
	// person opens in one sitting, which is not a number worth sweeping for.
	const positions = useRef(new Map<string, number>());
	const seen = useRef<{ key: string | null; count: number }>({ key: null, count: 0 });
	const [showJump, setShowJump] = useState(false);

	const scroller = useCallback((): Element | null => {
		return mobile ? document.scrollingElement ?? document.documentElement : log.current;
	}, [mobile]);

	const atBottom = useCallback((): boolean => {
		const e = scroller();
		return !e || e.scrollHeight - e.scrollTop - e.clientHeight < AT_BOTTOM_SLACK;
	}, [scroller]);

	// Everything that puts the end of the conversation back on screen comes
	// through here: the composer changing height, the keyboard settling, the jump
	// button, and arriving somewhere new.
	//
	// With no conversation there is no end to go to, and this must do nothing at
	// all. The composer's own resize observer calls it as the composer goes away
	// with the room being left, and on the phone the scroll region is the page
	// itself, so the join screen standing in for the conversation was sent to the
	// end of a document taller than the window and its card started above the
	// fold.
	const keepLatestInView = useCallback((force?: boolean) => {
		const e = scroller();
		if (!e || latest.current === null || !(force || pinned.current)) return;
		e.scrollTop = e.scrollHeight;
		pinned.current = true;
		setShowJump(false);
	}, [scroller]);

	// One listener for both scroll regions. It records where this conversation has
	// been left and whether the reader is still at the end.
	useLayoutEffect(() => {
		const onScroll = () => {
			const e = scroller();
			if (!e) return;
			pinned.current = atBottom();
			if (seen.current.key) positions.current.set(seen.current.key, e.scrollTop);
			if (pinned.current) setShowJump(false);
		};
		const region = log.current;
		region?.addEventListener("scroll", onScroll, { passive: true });
		addEventListener("scroll", onScroll, { passive: true });
		return () => {
			region?.removeEventListener("scroll", onScroll);
			removeEventListener("scroll", onScroll);
		};
	}, [scroller, atBottom]);

	// Arriving at a conversation, and every line that lands while you are in one.
	// Both are the same question — what should be on screen now — so they are one
	// effect rather than an append path and a switch path that have to agree.
	const key = conv?.key ?? null;
	const count = conv?.history.length ?? 0;
	useLayoutEffect(() => {
		const e = scroller();
		if (!e) return;
		// Same answer as `keepLatestInView`, because this writes the position
		// itself: leaving a conversation changes the key exactly as arriving at
		// one does, and there is nothing here to arrive at.
		if (key === null) {
			seen.current = { key, count };
			pinned.current = true;
			setShowJump(false);
			return;
		}
		const last = latest.current?.history[count - 1];
		const mine = last?.kind === "chat" && last.mine;
		if (seen.current.key !== key) {
			const saved = key === null ? undefined : positions.current.get(key);
			if (saved === undefined) e.scrollTop = e.scrollHeight;
			else e.scrollTop = saved;
			// A long conversation may not have finished laying out yet, especially
			// on the phone's page scroll, so a second pass on the next frame actually
			// reaches the end instead of falling a screen short.
			if (saved === undefined) requestAnimationFrame(() => keepLatestInView(true));
		} else if (count !== seen.current.count && (pinned.current || mine)) {
			e.scrollTop = e.scrollHeight;
		}
		seen.current = { key, count };
		pinned.current = atBottom();
		setShowJump(!pinned.current && count > 0);
	}, [key, count, scroller, atBottom, keepLatestInView]);

	// Dropping a file anywhere over the conversation posts it, which is where a
	// person aims. The counter is what makes the highlight survive dragging over
	// a child element: `dragleave` fires as the pointer crosses into one, so a
	// boolean would flicker off under the cursor.
	const [dragDepth, setDragDepth] = useState(0);
	const dropEnabled = composerEnabled;
	const carriesFiles = (e: React.DragEvent): boolean => [...e.dataTransfer.types].includes("Files");

	return (
		<div
			className={dragDepth > 0 ? "stream dropping" : "stream"}
			onDragEnter={(e) => {
				if (!dropEnabled || !carriesFiles(e)) return;
				e.preventDefault();
				setDragDepth((depth) => depth + 1);
			}}
			onDragOver={(e) => {
				// Without this the browser keeps its own default, which is to open the
				// file and throw the page away.
				if (dropEnabled && carriesFiles(e)) e.preventDefault();
			}}
			onDragLeave={() => setDragDepth((depth) => Math.max(0, depth - 1))}
			onDrop={(e) => {
				if (!dropEnabled || !carriesFiles(e)) return;
				e.preventDefault();
				setDragDepth(0);
				browser.addFiles([...e.dataTransfer.files]);
			}}
		>
			<div id="dropHint" className="drop-hint" aria-hidden="true">
				<span>Drop to post</span>
			</div>
			{
				/* What the room is about, above what is being said in it. Drawn only
			    when there is one, because a bar reserving space for nothing is a
			    permanent reminder that a room has said nothing.

			    Read as rich text like any other line, because a topic is where a
			    room puts the link everyone needs, and a topic that showed its URL
			    as text would be the one place in this page a link is not one.

			    The way to change it appears for a reader the room handed that
			    ability to, and for nobody else. Not a permission being checked:
			    the button is drawn from what this membership was answered with,
			    which is the same reason `/topic` is on their list of commands and
			    missing from somebody else's. Both buttons write the command rather than
			    acting on their own, so a topic is amended, or taken down, where text is
			    written, and there is one path rather than two. */
			}
			{conv?.type === "room" && conv.topic !== undefined && conv.topic !== "" && (
				<div id="topic" className="topic">
					<span className="topic-said" title={conv.topic}>
						<RichText text={conv.topic} nick={nick} />
					</span>
					{canInteract && conv.grants.has("topic") && (
						<>
							<IconButton
								icon="pencil"
								label="Change the topic"
								size="small"
								variant="ghost"
								onClick={() => session.setDraft(`/topic ${conv.topic}`)}
							/>
							<IconButton
								icon="close"
								label="Take the topic down"
								size="small"
								variant="ghost"
								onClick={() =>
									session.setDraft("/topic -")}
							/>
						</>
					)}
				</div>
			)}
			<ErrorBoundary part="message log">
				<Log
					ref={log}
					conv={conv}
					nick={nick}
					sendControls={sendControls}
					ignored={ignored}
					changing={draft.changing}
					hidden={conv === null}
				/>
			</ErrorBoundary>
			<JoinCard
				canInteract={canInteract}
				shown={conv === null}
				answers={join}
				dirs={dirs}
				directoryContext={directoryContext}
			/>
			{
				/* Where the conversation stops being visible. It is not the
				   composer and it is not the log: it is the one surface whose job
				   is to end the reading area, so the messages look like they pass
				   behind the field rather than stopping at a line somebody drew.
				   Its geometry is in workarea.css beside the log it belongs to. */
			}
			<div className="log-fade" aria-hidden="true" />
			<button
				type="button"
				id="jump"
				className={showJump ? "jump show" : "jump"}
				aria-label="Jump to latest messages"
				onClick={() => keepLatestInView(true)}
			>
				<span>Latest messages</span>
			</button>
			<Composer
				conv={conv}
				nick={nick}
				draft={draft.text}
				draftFiles={draft.files}
				changing={draft.changing}
				draftKeeping={draft.keeping}
				liveRooms={liveRooms}
				reachable={reachable}
				mobile={mobile}
				enabled={composerEnabled}
				phase={composerPhase}
				availability={composerAvailability}
				keepLatestInView={keepLatestInView}
			/>
		</div>
	);
}
