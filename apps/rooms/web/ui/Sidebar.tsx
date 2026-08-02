// The rail: the rooms that exist, the direct conversations this tab has open,
// and the foot that says what the connection is doing.
//
// The two "+" fields behave identically — open one and the other closes, click
// away or press Escape and it puts itself away and hands focus back — so they
// are one component used twice rather than two sets of handlers kept in step.

import { memo, type ReactNode, Suspense, use, useEffect, useRef, useState } from "react";
import { useDismissOnClickOutside } from "./hooks.ts";
import { roomKey } from "./store.ts";
import { usePeer } from "./peer.ts";
import type { Conv, DmConv, SessionPhase } from "./types.ts";
import { hueOf, initials, tooLong } from "./text.ts";
import { Icon } from "./icons.tsx";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";

/** Which "+" field is open. At most one is, so this is one value rather than a
 * flag per section that could both be true. */
type PanelName = "room" | "dm";

/** One section of the rail: a heading, an optional "+" field under it, and the
 * rows.
 *
 * The two sections differ only in what they are called and what they list, so
 * this is one component used twice. The field sits *after* the heading rather
 * than inside it, which the stylesheet depends on: the heading is a flex row, and
 * a field inside it would land beside the "+" instead of below it.
 *
 * What is typed into that field is this component's own state and nowhere else.
 * It is not a store fact, because nothing outside this section reads a
 * half-typed name; and it is not left in the DOM, because a value the element
 * holds outlives the field being closed, the conversation being switched, and
 * the room being lost — the page would then reopen a field still carrying a name
 * from some earlier intention. */
function RailSection(
	{
		id,
		className,
		title,
		listId,
		open,
		label,
		placeholder,
		max,
		noun,
		canAdd,
		onOpen,
		onSubmit,
		onError,
		children,
	}: {
		id: string;
		className?: string;
		title: string;
		listId: string;
		/** Whether this section's field is the open one. The rail owns the
		 * at-most-one rule, so a section only needs the answer, not the identity
		 * of whichever other section might hold it. */
		open: boolean;
		label: string;
		placeholder: string;
		max: number;
		/** What this section calls the thing being named, for the one message that
		 * needs it. The message itself is built here, so the two sections cannot
		 * word the same refusal differently. */
		noun: string;
		canAdd: boolean;
		onOpen: (open: boolean) => void;
		onSubmit: (value: string) => void;
		onError: (text: string) => void;
		children: ReactNode;
	},
) {
	const button = useRef<HTMLButtonElement>(null);
	const field = useRef<HTMLInputElement>(null);
	const [value, setValue] = useState("");
	const showing = open && canAdd;

	// The field exists to be typed in, so it takes the caret as it opens.
	useEffect(() => {
		if (showing) field.current?.focus();
	}, [showing]);

	useDismissOnClickOutside(showing, `#${id}, #${id}Btn`, () => onOpen(false));

	// Closing empties the field and takes it out of the tab order, so focus goes
	// back to the toggle rather than being left on `<body>` with nowhere to tab
	// from.
	const close = () => {
		setValue("");
		onOpen(false);
		button.current?.focus();
	};

	return (
		<div className={className ? "section " + className : "section"}>
			<div className="section-head">
				<span>{title}</span>
				<button
					type="button"
					id={id + "Btn"}
					ref={button}
					title={label}
					aria-label={label}
					aria-controls={id}
					aria-expanded={showing}
					hidden={!canAdd}
					onClick={() => onOpen(!showing)}
				>
					+
				</button>
			</div>
			<div id={id} className={showing ? "newroom show" : "newroom"}>
				<input
					id={id + "Input"}
					ref={field}
					placeholder={placeholder}
					aria-label={label}
					maxLength={32}
					value={value}
					onChange={(e) => setValue(e.target.value)}
					onBlur={(e) => {
						// Except when focus is going to the toggle, which is about to
						// decide the field's fate and would otherwise find it already
						// closed and open it straight back.
						if (e.relatedTarget !== button.current) onOpen(false);
					}}
					onKeyDown={(e) => {
						if (e.key === "Escape") {
							// This field consumed the key. Say so, or the window handler
							// treats the same press as "close the rooms list" and the
							// phone loses the whole screen the field was sitting on.
							e.stopPropagation();
							close();
							return;
						}
						if (e.key !== "Enter") return;
						// Cancel the default so the Enter cannot fall through to the
						// composer we are about to focus and land as a stray newline.
						e.preventDefault();
						const named = value.trim();
						if (!named) return;
						if (named.length > max) {
							onError(tooLong(noun, max));
							return;
						}
						close();
						onSubmit(named);
					}}
				/>
			</div>
			<ul id={listId}>{children}</ul>
		</div>
	);
}

function Empty({ text }: { text: string }) {
	return <li className="empty">{text}</li>;
}

/** The mark that ends a row, in the slot the row's badge otherwise fills. Both
 * lists carry one and they differ only in what they are called. */
function RowClose({ title, said, onClose }: { title: string; said: string; onClose: () => void }) {
	return (
		<button
			type="button"
			className="room-leave"
			title={title}
			aria-label={said}
			onClick={(e) => {
				e.stopPropagation();
				onClose();
			}}
		>
			<Icon name="close" size={13} />
		</button>
	);
}

function RoomRow(
	{ name, count, joined, here, onPick, onLeave }: {
		name: string;
		count: number;
		joined: boolean;
		here: boolean;
		onPick: (name: string) => void;
		onLeave: () => void;
	},
) {
	// The row opens the room, and the room you are in carries a second control
	// beside it to leave. Both are real buttons: an interactive control nested
	// inside another is a structure no assistive software can read out.
	//
	// Leaving lives in the badge's own slot, so the row gives up no width to hold
	// it and no name is cut short for a mark that is not showing. The count is
	// what a reader wants from this row until the moment they reach for it, and
	// it comes straight back when they leave.
	const said = joined
		? (here
			? "Room " + name + ", " + count + " here, the room you are in"
			: "Back to room " + name + ", " + count + " here, the room you are in")
		: "Open room " + name + ", " + count + " here";
	return (
		<li className={(joined ? "joined" : "") + (here ? " here" : "")}>
			<button
				type="button"
				className="room-open"
				aria-label={said}
				onClick={() => onPick(name)}
			>
				<span className="hash">#</span>
				<span className="rname">{name}</span>
				<span className="rcount">{count}</span>
			</button>
			{joined && (
				<RowClose title={"Leave #" + name} said={"Leave #" + name} onClose={onLeave} />
			)}
		</li>
	);
}

function RoomRows(
	{ ready, liveRooms, joinedRoom, activeKey, onPick, onLeave }: {
		ready: Promise<void>;
		liveRooms: ReadonlyMap<string, number>;
		joinedRoom: string | null;
		activeKey: string | null;
		onPick: (name: string) => void;
		onLeave: () => void;
	},
) {
	// Wait for the directory's first answer before saying anything about which
	// rooms exist. "No rooms yet." while the session is still opening is not a
	// small inaccuracy: it is the one thing this list is for. The promise settles
	// once and is never replaced, so a later reconnect keeps the last list on
	// screen instead of blanking it.
	use(ready);
	const rows = [...liveRooms.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
	if (rows.length === 0) return <Empty text="No rooms yet." />;
	const joined = joinedRoom?.toLowerCase() ?? null;
	return (
		<>
			{rows.map(([name, count]) => (
				<RoomRow
					key={name}
					name={name}
					count={count}
					joined={name.toLowerCase() === joined}
					here={activeKey === roomKey(name)}
					onPick={onPick}
					onLeave={onLeave}
				/>
			))}
		</>
	);
}

function DmRow(
	{ conv, online, here, onOpen, onClose }: {
		conv: DmConv;
		online: boolean;
		here: boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void;
	},
) {
	// Every trailing mark hangs off one group, because the close button takes the
	// whole group's slot rather than a slot of its own. Naming the marks one by
	// one in the stylesheet is what let a closed row keep its "closed" label under
	// the button and draw the two on top of each other.
	//
	// A closed row is one whose member left, which puts their name back in the
	// room's hands. The conversation stays, its history is yours, but it reaches
	// nobody, and the row says so rather than looking like someone merely offline.
	//
	// The close button is on every conversation, not only the one on screen: the
	// room you are in can be left while you are reading a direct message, and the
	// reverse has to be true too.
	const mark = conv.line === "closed"
		? <span className="closed-mark">closed</span>
		: conv.line === "live"
		? (
			<span className="lock" title="Direct, peer-to-peer">
				<Icon name="lock" size={12} />
			</span>
		)
		: null;
	return (
		<li
			className={(here ? "here" : "") + (online ? "" : " off") +
				(conv.line === "closed" ? " closed" : "")}
		>
			<button
				type="button"
				className="dm-open"
				aria-label={conv.line === "closed"
					? "Open the closed conversation with " + conv.id
					: "Open direct message with " + conv.id}
				onClick={() => onOpen(conv.key)}
			>
				<span
					className="dmavatar"
					aria-hidden="true"
					style={{ background: hueOf(conv.id) }}
				>
					{initials(conv.id)}
				</span>
				<span className="rname">{conv.id}</span>
				<span className="dm-marks">
					<span
						className={online ? "dmpip on" : "dmpip"}
						title={conv.id + (online ? " is online" : " is offline")}
					/>
					{mark}
					{conv.unread.kind === "unread" && (
						<span className="rcount">{conv.unread.count}</span>
					)}
				</span>
			</button>
			<RowClose
				title="Close this direct message"
				said={"Close the direct message with " + conv.id}
				onClose={() => onClose(conv)}
			/>
		</li>
	);
}

function DmRows(
	{ convs, activeKey, joinedRoom, dmablePeers, onOpen, onClose }: {
		convs: ReadonlyMap<string, Conv>;
		activeKey: string | null;
		joinedRoom: string | null;
		dmablePeers: ReadonlySet<string>;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void;
	},
) {
	const rows = [...convs.values()]
		.filter((c): c is DmConv => c.type === "dm")
		.sort((a, b) => a.id.localeCompare(b.id));
	if (rows.length === 0) {
		return (
			<Empty
				text={joinedRoom
					? "Message a member to start one."
					: "Join a room first — then message someone from the roster."}
			/>
		);
	}
	return (
		<>
			{rows.map((conv) => (
				<DmRow
					key={conv.key}
					conv={conv}
					online={dmablePeers.has(conv.id.toLowerCase())}
					here={conv.key === activeKey}
					onOpen={onOpen}
					onClose={onClose}
				/>
			))}
		</>
	);
}

function SidebarPane(
	{
		convs,
		liveRooms,
		dmablePeers,
		joinedRoom,
		activeKey,
		railShown,
		session,
		statusText,
	}: {
		convs: ReadonlyMap<string, Conv>;
		liveRooms: ReadonlyMap<string, number>;
		dmablePeers: ReadonlySet<string>;
		joinedRoom: string | null;
		activeKey: string | null;
		railShown: boolean;
		session: SessionPhase;
		statusText: string;
	},
) {
	// At most one "+" field is open, which is the rail's rule to keep rather than
	// each section's, so it is one value here instead of a flag in each.
	const peer = usePeer();
	const [open, setOpen] = useState<PanelName | null>(null);
	const opener = (panel: PanelName) => (shown: boolean) => setOpen(shown ? panel : null);
	// Switching conversations, or losing the room, puts an open panel away.
	useEffect(() => setOpen(null), [activeKey]);

	return (
		<nav className="sidebar" aria-label="Rooms">
			<div className="workspace">
				<button
					type="button"
					id="railToggle"
					className="mark-btn"
					title={railShown ? "Hide the rooms list" : "Show the rooms list"}
					aria-label="Rooms and direct messages"
					aria-pressed={railShown}
					onClick={() => peer.showRail(false)}
				/>
				pancake <small>rooms</small>
			</div>
			<RailSection
				id="newRoom"
				title="Rooms"
				listId="roomList"
				open={open === "room"}
				label="Create or open a room"
				placeholder="new-room-name"
				max={MAX_ROOM}
				noun="room name"
				canAdd
				onOpen={opener("room")}
				onSubmit={peer.pickRoom}
				onError={peer.banner}
			>
				<Suspense fallback={<Empty text="Looking for rooms…" />}>
					<RoomRows
						ready={peer.directoryReady}
						liveRooms={liveRooms}
						joinedRoom={joinedRoom}
						activeKey={activeKey}
						onPick={peer.pickRoom}
						onLeave={peer.leaveRoom}
					/>
				</Suspense>
			</RailSection>
			<RailSection
				id="newDm"
				className="dms"
				title="Direct messages"
				listId="dmList"
				open={open === "dm"}
				label="Start a direct message"
				placeholder="member name"
				max={MAX_NICK}
				noun="name"
				canAdd={joinedRoom !== null}
				onOpen={opener("dm")}
				onSubmit={peer.startDm}
				onError={peer.banner}
			>
				<DmRows
					convs={convs}
					activeKey={activeKey}
					joinedRoom={joinedRoom}
					dmablePeers={dmablePeers}
					onOpen={peer.openConv}
					onClose={peer.closeDm}
				/>
			</RailSection>
			<div className="sidebar-foot">
				<span id="dot" className={"dot " + session} />
				<span id="status" role="status" aria-live="polite">{statusText}</span>
			</div>
		</nav>
	);
}

// Memoised: see `useStore`. None of these props change with a keystroke.
export const Sidebar = memo(SidebarPane);
