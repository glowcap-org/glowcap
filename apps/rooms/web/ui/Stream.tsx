// The conversation column: the banner, the log, the join card, the
// jump-to-latest button, and the composer.
//
// This is where scrolling is owned, and it is owned in one place because the
// region that scrolls is not the same element on both layouts. On a wide screen
// the log is its own overflow area; on a phone the whole document scrolls, the
// way a native chat does. Every read and every write goes through `scroller`, so
// there is one answer to "where are we" rather than one per caller.

import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { Conv } from "./types.ts";
import { Log } from "./Log.tsx";
import { Composer } from "./Composer.tsx";
import { JoinCard } from "./JoinCard.tsx";
import { ErrorBoundary } from "./ErrorBoundary.tsx";

// How close to the end still counts as "reading the newest message".
const AT_BOTTOM_SLACK = 80;

export function Stream(
	{ conv, nick, banner, draft, draftRoom, draftNick, composerEnabled, mobile }: {
		conv: Conv | null;
		nick: string;
		banner: string;
		draft: string;
		draftRoom: string;
		draftNick: string;
		composerEnabled: boolean;
		mobile: boolean;
	},
) {
	const log = useRef<HTMLElement>(null);
	// Whether the reader was at the end of the conversation before whatever just
	// happened. Content growing does not raise a scroll event, so this is read at
	// scroll time and consulted afterwards: it answers "were they pinned", which is
	// the question, rather than "are they pinned now", which is always false the
	// moment a message lands.
	const pinned = useRef(true);
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

	const keepLatestInView = useCallback((force?: boolean) => {
		const e = scroller();
		if (!e || !(force || pinned.current)) return;
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
	// Read through a ref rather than depending on the conversation itself. Every
	// store change replaces it — a member coming online, a keystroke in the
	// composer — and this effect measures the scroll region, which forces layout.
	// Only arriving somewhere new, and a line landing, are worth that.
	const latest = useRef(conv);
	latest.current = conv;
	useLayoutEffect(() => {
		const e = scroller();
		if (!e) return;
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

	return (
		<div className="stream">
			<div
				id="banner"
				className={banner ? "banner show" : "banner"}
				role="status"
				aria-live="polite"
			>
				{banner}
			</div>
			<ErrorBoundary part="message log">
				<Log
					ref={log}
					conv={conv}
					nick={nick}
					hidden={conv === null}
				/>
			</ErrorBoundary>
			<JoinCard shown={conv === null} room={draftRoom} nick={draftNick} />
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
				draft={draft}
				mobile={mobile}
				enabled={composerEnabled}
				keepLatestInView={keepLatestInView}
			/>
		</div>
	);
}
