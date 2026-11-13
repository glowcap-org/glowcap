// The conversation column: the log, the join card, the jump-to-latest button,
// and the composer.
//
// This is where scrolling is owned, and it is owned in one place because the
// region that scrolls is not the same element on both layouts. On a wide screen
// the log is its own overflow area. On a phone the whole document scrolls, the
// way a native chat does. Every read and every write goes through `scroller`, so
// there is one answer to "where are we" rather than one per caller.

import type React from "react";
import { jumpToLatest, subjectChange, subjectClear, subjectCopyLink } from "../../../lib/text/controls.ts";
import { dropToAttach, latestMessages } from "../../../lib/text/page.ts";
import { useCallback, useLayoutEffect, useRef, useState } from "react";
import { CAUGHT_UP, type Conv, conversationTakesFiles, NO_HISTORY } from "../conversation.ts";
import type { DirId, DirView, LiveRooms, SessionPhase } from "../directory.ts";
import type { SendControlPolicy } from "../send_controls.ts";
import type { DirectoryDestinationContext, JoinAnswers, JoinResolution } from "../joining.ts";
import { Log } from "./Log.tsx";
import { Composer } from "./Composer.tsx";
import { JoinCard } from "../cards/JoinCard.tsx";
import { ErrorBoundary } from "../ErrorBoundary.tsx";
import { RichText } from "./RichText.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { IconButton } from "../IconButton.tsx";
import { CopyButton } from "../Copy.tsx";
import type { Subject } from "../../../lib/room/subject.ts";
import { Icon } from "../icons.tsx";
import { useRoomsState } from "../hooks.ts";
import { ScrollMemory } from "../scroll_memory.ts";
import { PRESENTATION, useProgress } from "../presentation.ts";
import { type LogStanding, LogStood, NEAR_END, overhang, travel } from "./log_travel.tsx";

export function Stream(
	{
		canInteract,
		conv,
		nick,
		liveRooms,
		reachable,
		join,
		joinResolution,
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
		joinResolution: JoinResolution;
		/** Passed straight through to the join card, which offers the directories
		 * this tab already holds under its address field. */
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
	// Only the line being changed is read here. The rest of the draft changes on every keystroke and is
	// the composer's to read.
	const changing = useRoomsState((state) => conv == null ? undefined : state.drafts.get(conv.key)?.changing);
	const history = useRoomsState((state) => conv == null ? NO_HISTORY : state.histories.get(conv.key) ?? NO_HISTORY);
	const unread = useRoomsState((state) => conv == null ? CAUGHT_UP : state.unreads.get(conv.key) ?? CAUGHT_UP);
	const log = useRef<HTMLElement>(null);
	// Whether the reader was at the end of the conversation before whatever just
	// happened. Content growing does not raise a scroll event, so this is read at
	// scroll time and consulted afterwards: it answers "were they pinned", which is
	// the question, rather than "are they pinned now", which is always false the
	// moment a message lands.
	const pinned = useRef(true);
	// The conversation on screen, read through a ref rather than depended on.
	// A member coming online replaces it; a typing flag and a composer
	// keystroke do not. Its readers below measure the scroll region, which forces
	// layout. Only arriving somewhere new, and a line landing, are worth that.
	const latest = useRef(conv);
	latest.current = conv;
	// Where each recent conversation was left, so coming back returns to the
	// message being read rather than the bottom. Closed conversations leave the
	// store, while ScrollMemory keeps this long-lived view bounded independently.
	const positions = useRef(new ScrollMemory());
	const seen = useRef<{ key: string | null; count: number }>({ key: null, count: 0 });
	// Where the log's rows stood before the commit that just changed it.
	const stood = useRef<LogStanding | null>(null);
	const [showJump, setShowJump] = useState(false);
	// A read of earlier history says so once it has run long enough to be a
	// wait, as every other wait on the page does. A read that ends sooner
	// draws nothing, so the log is not built around a placeholder and then
	// rebuilt without it.
	const readingEarlier = useProgress(
		conv?.type === "room" && conv.earlierHistory === "loading",
		PRESENTATION.busy,
		conv?.key,
	);

	const scroller = useCallback((): Element | null => {
		return mobile ? document.scrollingElement ?? document.documentElement : log.current;
	}, [mobile]);

	// How far the scroll region reports itself past its end. A row of the log
	// on its way to its place can be drawn past the end, and the region counts
	// it until it arrives. The page that scrolls whole cuts such a row off.
	const past = useCallback((e: Element): number => e === log.current ? overhang(e) : 0, []);

	const atBottom = useCallback((): boolean => {
		const e = scroller();
		return !e || e.scrollHeight - past(e) - e.scrollTop - e.clientHeight < NEAR_END;
	}, [scroller, past]);

	const toEnd = useCallback((e: Element): void => {
		const reach = past(e);
		e.scrollTop = reach === 0 ? e.scrollHeight : e.scrollHeight - reach - e.clientHeight;
	}, [past]);

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
		toEnd(e);
		pinned.current = true;
		setShowJump(false);
	}, [scroller, toEnd]);

	// One listener for both scroll regions. It records where this conversation has
	// been left and whether the reader is still at the end.
	useLayoutEffect(() => {
		const onScroll = () => {
			const e = scroller();
			if (!e) return;
			pinned.current = atBottom();
			if (seen.current.key) positions.current.remember(seen.current.key, e.scrollTop);
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
	// Both are the same question, what should be on screen now, so they are one
	// effect rather than an append path and a switch path that have to agree.
	const key = conv?.key ?? null;
	const count = history.length;
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
		const last = history[count - 1];
		const mine = last?.kind === "chat" && last.mine;
		if (seen.current.key !== key) {
			const saved = positions.current.recall(key);
			if (saved === undefined) toEnd(e);
			else e.scrollTop = saved;
			// A long conversation may not have finished laying out yet, especially
			// on the phone's page scroll, so a second pass on the next frame actually
			// reaches the end instead of falling a screen short.
			if (saved === undefined) requestAnimationFrame(() => keepLatestInView(true));
		} else if (count !== seen.current.count && (pinned.current || mine)) {
			toEnd(e);
		}
		seen.current = { key, count };
		pinned.current = atBottom();
		setShowJump(!pinned.current && count > 0);
	}, [key, count, history, scroller, atBottom, toEnd, keepLatestInView]);

	// What the log is given to draw. Its rows are read before a commit that
	// replaces one of these values, and before no other.
	const drawn = { conv, history, unread, nick, sendControls, ignored, changing, readingEarlier };

	// This effect follows the one that writes the scroll position, so `travel`
	// measures each row where it ends. It runs at every commit and does
	// nothing unless the log changed: the reading it answers is taken only
	// then.
	useLayoutEffect(() => {
		const was = stood.current;
		stood.current = null;
		if (was != null && log.current != null) travel(log.current, was);
	});

	// Dropping a file anywhere over the conversation posts it, which is where a
	// person aims. The counter is what makes the highlight survive dragging over
	// a child element: `dragleave` fires as the pointer crosses into one, so a
	// boolean would flicker off under the cursor.
	const [dragDepth, setDragDepth] = useState(0);
	// A drop is caught wherever the composer is live, so the browser never
	// opens the file and throws the page away. The invitation to drop is
	// drawn only where the file can actually go; elsewhere the drop lands on
	// the same admission the picker uses, which says why in the log.
	const dropEnabled = composerEnabled && conv?.type !== "directory";
	const dropInvited = dropEnabled && conversationTakesFiles(conv);
	const carriesFiles = (e: React.DragEvent): boolean => [...e.dataTransfer.types].includes("Files");

	const subjectDraft = conv?.type === "room" && conv.subject !== undefined ? subjectCommand(conv.subject) : null;
	return (
		<div
			className={dragDepth > 0 ? "stream dropping" : "stream"}
			onDragEnter={(e) => {
				if (!dropEnabled || !carriesFiles(e)) return;
				e.preventDefault();
				if (dropInvited) setDragDepth((depth) => depth + 1);
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
				<span className="drop-hint-chip">
					<Icon name="clip" size={16} />
					{dropToAttach}
				</span>
			</div>
			{
				/* What the room is about, above what is being said in it. Drawn only
			    when there is one, because a bar reserving space for nothing is a
			    permanent reminder that a room has said nothing.

			    The description reads as rich text like any other line, so a URL in
			    it is a link here as everywhere else. A subject's own link names an
			    object hosted elsewhere, and the bar offers it to copy: the room
			    shares it and never calls it.

			    The way to change it appears for a reader the room handed that
			    ability to, and for nobody else. Not a permission being checked:
			    the button is drawn from what this membership was answered with,
			    which is the same reason `/subject` is on their list of commands and
			    missing from somebody else's. Both buttons write the command rather than
			    acting on their own, so a subject is amended, or taken down, where text is
			    written, and there is one path rather than two. */
			}
			{conv?.type === "room" && conv.subject !== undefined && (
				<div id="subject" className="subject">
					<div className="subject-said" title={conv.subject.description}>
						<RichText text={conv.subject.description} nick={nick} />
					</div>
					{conv.subject.link !== undefined && (
						<CopyButton text={conv.subject.link} label={subjectCopyLink} size="small" variant="ghost" />
					)}
					{canInteract && conv.grants.has("subject") && (
						<>
							{subjectDraft !== null && (
								<IconButton
									icon="pencil"
									label={subjectChange}
									size="small"
									variant="ghost"
									onClick={() => session.setDraft(subjectDraft)}
								/>
							)}
							<IconButton
								icon="close"
								label={subjectClear}
								size="small"
								variant="ghost"
								onClick={() => session.setDraft("/subject -")}
							/>
						</>
					)}
				</div>
			)}
			<LogStood log={log} conversation={key} drawn={drawn} into={stood} />
			<ErrorBoundary part="message log">
				<Log ref={log} {...drawn} hidden={conv === null} />
			</ErrorBoundary>
			{conv === null && (
				<JoinCard
					canInteract={canInteract}
					answers={join}
					resolved={joinResolution}
					dirs={dirs}
					directoryContext={directoryContext}
				/>
			)}
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
				aria-label={jumpToLatest}
				onClick={() => keepLatestInView(true)}
			>
				<span>{latestMessages}</span>
			</button>
			<Composer
				canInteract={canInteract}
				conv={conv}
				nick={nick}
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

/** The `/subject` command that sets `subject` again, or null when typing
 * cannot reproduce it: the command trims what it reads, and a lone `-` takes
 * the subject down. Offering a draft that changes the subject on Enter would
 * be worse than offering none. */
function subjectCommand(subject: Subject): string | null {
	const { description, link } = subject;
	if (description !== description.trim() || (link === undefined && description === "-")) return null;
	return link === undefined ? `/subject ${description}` : `/subject ${link} ${description}`;
}
