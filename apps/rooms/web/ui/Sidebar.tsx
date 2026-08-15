// The rail: the rooms that exist, the direct conversations this tab has open,
// and the foot that says what the connection is doing.
//
// The two "+" fields behave identically — open one and the other closes, click
// away or press Escape and it puts itself away and hands focus back — so they
// are one component used twice rather than two sets of handlers kept in step.

import { memo, type ReactNode, useEffect, useRef, useState } from "react";
import { useDismissOnClickOutside } from "./hooks.ts";
import { usePeer } from "./peer.ts";
import {
	type Conv,
	type DirId,
	dirId,
	dirsAreMarked,
	type DirView,
	type DmConv,
	membersHere,
	type RoomConv,
	type SessionPhase,
} from "./types.ts";
import { directoryName, hueOf, initials, tooLong } from "./text.ts";
import { Icon } from "./icons.tsx";
import { PHASE_SAID } from "./DirectoryFacts.tsx";
import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
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
		onElsewhere,
		sigil,
		where,
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
		/** Offered when this section can also reach somewhere this tab does not
		 * hold yet. Absent means the section has no elsewhere: a direct line is
		 * opened from a roster, so there is no address to go and find. */
		onElsewhere?: (value: string) => void;
		/** The mark this section's rows wear, worn by the panel too so the thing
		 * being named looks like the things already named. */
		sigil: string;
		/** Where what is typed here will land, and which mark that directory wears.
		 * Absent when the section has no destination to state — a direct line is
		 * opened on whichever directory the person is already on. */
		where?: { name: string; slot?: number };
		onError: (text: string) => void;
		children: ReactNode;
	},
) {
	const button = useRef<HTMLButtonElement>(null);
	const field = useRef<HTMLInputElement>(null);
	const elsewhere = useRef<HTMLButtonElement>(null);
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
				<IconButton
					id={id + "Btn"}
					ref={button}
					icon="plus"
					label={label}
					size="small"
					variant="ghost"
					tone="accent"
					aria-controls={id}
					aria-expanded={showing}
					hidden={!canAdd}
					onClick={() => onOpen(!showing)}
				/>
			</div>
			<div id={id} className={showing ? "newroom show" : "newroom"} data-dir={where?.slot}>
				<span className="hash" aria-hidden="true">{sigil}</span>
				<input
					id={id + "Input"}
					ref={field}
					placeholder={placeholder}
					aria-label={label}
					maxLength={max}
					value={value}
					onChange={(e) => setValue(e.target.value)}
					onBlur={(e) => {
						// Except when focus is going to this panel's own two controls.
						// The toggle is about to decide the field's fate and would
						// otherwise find it already closed and open it straight back; the
						// step-up link lives *inside* the panel, so closing on the way to
						// it put the panel away before the press could land — which is
						// exactly what a keyboard reader does, since reaching that link
						// means tabbing off the field.
						if (e.relatedTarget !== button.current && e.relatedTarget !== elsewhere.current) {
							onOpen(false);
						}
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
				{where !== undefined && onElsewhere !== undefined && (
					// The same line a room carries under its name, doing the same job for a
					// room that does not exist yet: it says where this one will land, and
					// pressing it is how that is changed. A room's line opens what is known
					// about its directory; this one opens the card where another can be
					// named, which is the one difference between the two skeletons.
					//
					// Whatever has been typed goes with it. Moving between the two surfaces
					// never costs a reader what they were part way through saying, which is
					// the rule this field already holds when it fills the card behind it.
					<Button
						variant="caption"
						ref={elsewhere}
						id={id + "Elsewhere"}
						className="rwhere"
						title={where.name}
						// The visible line states the destination, because that is what a
						// reader needs to see. What pressing it does has to be said too, and
						// only the accessible name has room for both.
						aria-label={"In " + where.name + ". Put this " + noun.replace(/ name$/, "") +
							" in another directory"}
						// The field's blur closes this panel, so a press that moved focus
						// would take its own target away before it landed. Preventing the
						// pointer's default keeps the caret in the field; it suppresses
						// the focus shift and nothing else, so the click still follows.
						//
						// The action belongs on the click and not on the press, because a
						// button reached by keyboard fires click alone — Enter and Space
						// raise no mousedown at all, and neither does a screen reader's
						// activation. Acting on mousedown left this control focusable,
						// visibly focused, and dead.
						onMouseDown={(e) => e.preventDefault()}
						onClick={() => {
							const named = value.trim();
							close();
							onElsewhere(named);
						}}
					>
						<Icon name="directory" size={12} />
						<span className="rwhere-said">in {where.name}</span>
					</Button>
				)}
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
		<IconButton
			className="room-leave"
			icon="close"
			label={said}
			size="small"
			variant="ghost"
			tone="danger"
			title={title}
			onClick={(e) => {
				e.stopPropagation();
				onClose();
			}}
		/>
	);
}

/** One room this tab is in.
 *
 * The rail lists the rooms you hold, not the rooms a directory advertises. Those
 * are two different things, and rendering the second while inferring the first
 * from it is what made this list a catalogue that reordered itself under the
 * pointer whenever a stranger joined something. The catalogue has its own
 * surface now; what is left here is short, stable, and yours.
 *
 * The badge is unread, for the same reason: a head-count is somebody else's
 * activity, and nothing on this list should move or change because of it. */
function RoomRow(
	{ conv, unread, here, directory, slot, phase, onPick, onLeave, onAbout }: {
		conv: RoomConv;
		unread: number;
		here: boolean;
		/** What to call the directory this room is in, or null while this tab holds
		 * only one and saying so would be noise. It is drawn on the row, not only
		 * spoken: the colour beside it is the glance, and this is what carries the
		 * same fact for a reader who cannot use colour. */
		directory: string | null;
		/** Which mark that directory wears, or null when none wears one. Set
		 * together with `directory`, never alone, so a colour is never the only thing
		 * telling two rooms apart. */
		slot: number | null;
		phase: SessionPhase;
		onPick: (conv: RoomConv) => void;
		onLeave: (key: string) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	// The row opens the room and carries a second control beside it to leave.
	// Both are real buttons: an interactive control nested inside another is a
	// structure no assistive software can read out.
	//
	// Leaving lives in the badge's slot, so the row gives up no width to hold it
	// and no name is cut short for a mark that is not showing.
	const where = directory === null ? "" : " in " + directory;
	const unwell = phase === "connected" ? "" : ", directory " + phase;
	// The sigil belongs in the spoken name too. The row draws it, the header
	// draws it, and a reader who hears "annex" where everyone else reads "#annex"
	// is being told about a different thing.
	const named = "#" + conv.id;
	// The badge answers whichever question is live. Unread is the urgent one and
	// takes the slot when there is any; otherwise the slot says how many people
	// are in there, which is what it has always said and what a reader glances at
	// to decide where to go next.
	//
	// The count is free to show now that nothing sorts by it. It used to order
	// the list, so a stranger joining anywhere walked the rows out from under the
	// pointer — but that was the ordering, not the number, and the ordering is
	// gone.
	const people = membersHere(conv.members);
	const said = (here ? named : "Open " + named) + where +
		(unread > 0 ? ", " + unread + " unread" : people > 0 ? ", " + people + " in the room" : "") + unwell;
	return (
		<li className={here ? "here" : ""} data-dir={slot ?? undefined}>
			<button
				type="button"
				className="room-open"
				aria-label={said}
				aria-current={here ? "page" : undefined}
				onClick={() => onPick(conv)}
			>
				<span className="hash" aria-hidden="true">#</span>
				<span className="rname" title={conv.id}>{conv.id}</span>
				{unread > 0
					? <span className="rcount unread">{unread}</span>
					: people > 0
					? <span className="rcount">{people}</span>
					: null}
			</button>
			{directory !== null && (
				// A sibling of the row's own button, never inside it: a control within a
				// control is a shape no assistive software can announce, and this one
				// goes somewhere different from the row it sits under.
				<Button
					variant="caption"
					className="rwhere"
					title={directory}
					aria-label={"About " + directory}
					onClick={() => onAbout(conv.dir)}
				>
					<Icon name="directory" size={12} />
					<span className="rwhere-said">in {directory}</span>
				</Button>
			)}
			<RowClose title="Leave" said={"Leave " + named + where} onClose={() => onLeave(conv.key)} />
		</li>
	);
}

/** A directory this tab is on with nothing open on it.
 *
 * The same row a room gets, because it is the same kind of thing: somewhere you
 * are. Its mark is the directory glyph rather than a room's sigil, the line
 * under it says why it is here, and the way out gives the whole directory back
 * instead of one room. Pressing it opens the join card already aimed here, which
 * is the one thing anybody wants from a server they are on and in no room on. */
function EmptyDirRow(
	{ dir, home, marked, onJoinOn, onLeave, onAbout }: {
		dir: DirView;
		home: DirId | null;
		marked: boolean;
		onJoinOn: (dir: DirId) => void;
		onLeave: (dir: DirId) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	const name = directoryName(dir.id, home);
	const said = dir.session === "connected" ? "no rooms yet" : PHASE_SAID[dir.session];
	return (
		<li className="dirrow" data-dir={marked ? dir.slot : undefined}>
			<button
				type="button"
				className="room-open"
				aria-label={"Join a room on " + name}
				onClick={() => onJoinOn(dir.id)}
			>
				<span className="hash" aria-hidden="true">
					<Icon name="directory" size={14} />
				</span>
				<span className="rname" title={dir.id}>{name}</span>
			</button>
			<Button
				variant="caption"
				className="rwhere"
				aria-label={"About " + name}
				onClick={() => onAbout(dir.id)}
			>
				<span className="rwhere-said">{said}</span>
			</Button>
			<RowClose title="Leave" said={"Leave " + name} onClose={() => onLeave(dir.id)} />
		</li>
	);
}

/** The rooms this tab is in, across every directory, in the order it entered
 * them, and under them the directories it is on with nothing open.
 *
 * Insertion order and nothing else. Nobody else's activity can move a row, and
 * joining appends rather than inserting into the middle, so the list a reader
 * learned stays the list they have. */
function YourRooms(
	{ convs, dirs, home, activeKey, marked, empty, onPick, onLeave, onAbout, onJoinOn, onLeaveDir }: {
		convs: ReadonlyMap<string, Conv>;
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		activeKey: string | null;
		/** Whether rows say which directory they are in. Worth saying only once
		 * there is more than one to be in, and never worth saying past the ramp's
		 * length,
		 * where a mark for some and none for others would claim a sameness that is
		 * not there. */
		marked: boolean;
		/** Directories held with nothing open on them, listed under the rooms so a
		 * connection nobody can see is not a connection nobody can end. */
		empty: DirView[];
		onPick: (conv: RoomConv) => void;
		onLeave: (key: string) => void;
		onAbout: (dir: DirId) => void;
		onJoinOn: (dir: DirId) => void;
		onLeaveDir: (dir: DirId) => void;
	},
) {
	const rows = [...convs.values()].filter((conv): conv is RoomConv => conv.type === "room");
	if (rows.length === 0 && empty.length === 0) {
		return (
			<Empty
				text={dirs.size === 0
					? "Reaching a directory…"
					: "Rooms you join appear here. Name one above to open it."}
			/>
		);
	}
	return (
		<>
			{rows.map((conv) => {
				const held = dirs.get(conv.dir);
				// Every row names its directory once there is more than one, the page's
				// own included. Leaving that one out would make the colour beside a home
				// room the only thing telling it apart, and would leave the line that
				// opens Settings unreachable. The split is that this directory is
				// described by Settings and a foreign one by its own card, not that this
				// one goes undescribed.
				return (
					<RoomRow
						key={conv.key}
						conv={conv}
						unread={conv.unread.kind === "unread" ? conv.unread.count : 0}
						here={activeKey === conv.key}
						directory={marked ? directoryName(conv.dir, home) : null}
						slot={marked ? held?.slot ?? null : null}
						phase={held?.session ?? "disconnected"}
						onPick={onPick}
						onLeave={onLeave}
						onAbout={onAbout}
					/>
				);
			})}
			{empty.map((dir) => (
				<EmptyDirRow
					key={dir.id}
					dir={dir}
					home={home}
					marked={marked}
					onJoinOn={onJoinOn}
					onLeave={onLeaveDir}
					onAbout={onAbout}
				/>
			))}
		</>
	);
}

function DmRow(
	{ conv, online, where, slot, here, onOpen, onClose, onAbout }: {
		conv: DmConv;
		online: boolean;
		/** Which directory this line was introduced on, or null while there is only
		 * one and saying so would be noise. It is said in words as well as worn as
		 * a colour, because two people may hold the same nickname on two
		 * directories and colour alone cannot tell a reader which is which. */
		where: string | null;
		slot: number | null;
		here: boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void;
		onAbout: (dir: DirId) => void;
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
			data-dir={slot ?? undefined}
		>
			<button
				type="button"
				className="dm-open"
				aria-label={(conv.line === "closed"
					? "Open the closed conversation with " + conv.id
					: "Open direct message with " + conv.id) + (where === null ? "" : " on " + where)}
				onClick={() => onOpen(conv.key)}
			>
				<span
					className="dmavatar"
					aria-hidden="true"
					// Seeded by the name alone, deliberately: the same person must wear
					// the same tint here and in the log, and the log knows only the name.
					// Which directory they are on is carried by the ring around this chip
					// and by the line under it, so two people holding one nickname on two
					// directories are still told apart — by the two channels that mean
					// that, rather than by a fill that would then disagree with the
					// conversation it opens.
					style={{ background: hueOf(conv.id) }}
				>
					{initials(conv.id)}
				</span>
				{
					/* Titled like a room's name, because it truncates like one. The row's
				    own label carries the whole name for a reader who is listening; a
				    reader who is looking had nothing. */
				}
				<span className="rname" title={conv.id}>{conv.id}</span>
				<span className="dm-marks">
					<span
						className={online ? "dmpip on" : "dmpip"}
						title={conv.id + (online ? " is online" : " is offline")}
					/>
					{mark}
					{conv.unread.kind === "unread" && <span className="rcount">{conv.unread.count}</span>}
				</span>
			</button>
			{where !== null && (
				// Beside the row's button rather than inside it, and the same control a
				// room row carries: a person's directory is as worth asking about as a
				// room's, and one shape for both means one rule places both.
				<Button
					variant="caption"
					className="rwhere"
					title={where}
					aria-label={"About " + where}
					onClick={() => onAbout(conv.dir)}
				>
					<Icon name="directory" size={12} />
					<span className="rwhere-said">in {where}</span>
				</Button>
			)}
			<RowClose
				title="Close this direct message"
				said={"Close the direct message with " + conv.id}
				onClose={() => onClose(conv)}
			/>
		</li>
	);
}

function DmRows(
	{ convs, activeKey, inARoom, dirs, home, marked, onOpen, onClose, onAbout }: {
		convs: ReadonlyMap<string, Conv>;
		activeKey: string | null;
		/** Whether this tab is in any room at all. A direct line starts from a
		 * roster, so which room it came from does not matter here — only that
		 * there is one. */
		inARoom: boolean;
		/** Every directory, because whether a peer is reachable is one directory's
		 * answer: the same nick on another directory is a different person, and a
		 * merged set of reachable names would say the wrong one is online. */
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		/** Whether to say which directory each line is in, which is worth saying only
		 * once there is more than one to be on. */
		marked: boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	const rows = [...convs.values()]
		.filter((c): c is DmConv => c.type === "dm")
		.sort((a, b) => a.id.localeCompare(b.id));
	if (rows.length === 0) {
		return (
			<Empty
				text={inARoom
					? "Message a member to start one."
					: "Join a room first, then message someone from the roster."}
			/>
		);
	}
	return (
		<>
			{rows.map((conv) => (
				<DmRow
					key={conv.key}
					conv={conv}
					online={dirs.get(conv.dir)?.dmablePeers.has(conv.id.toLowerCase()) ?? false}
					where={marked ? directoryName(conv.dir, home) : null}
					slot={marked ? dirs.get(conv.dir)?.slot ?? null : null}
					here={conv.key === activeKey}
					onOpen={onOpen}
					onClose={onClose}
					onAbout={onAbout}
				/>
			))}
		</>
	);
}

function SidebarPane(
	{
		convs,
		dirs,
		homeDir,
		activeKey,
		railShown,
		mobile,
		session,
		statusText,
		emptyDirs,
	}: {
		convs: ReadonlyMap<string, Conv>;
		/** Every directory this tab holds, in the order it opened them. */
		dirs: ReadonlyMap<DirId, DirView>;
		/** Those of them with nothing open, which get a row of their own: holding
		 * one is a session and a registered name whatever is open on it, and that
		 * state used to have nowhere to appear. */
		emptyDirs: DirView[];
		homeDir: DirId | null;
		activeKey: string | null;
		railShown: boolean;
		mobile: boolean;
		session: SessionPhase;
		statusText: string;
	},
) {
	// Whether this tab is in any room, which is what the direct-message section
	// needs: a direct line starts from a roster, and any room's roster will do.
	const inARoom = [...convs.values()].some((conv) => conv.type === "room");
	// The grouping appears only when it carries information. Holding one
	// directory, the rail draws exactly what it has always drawn: no heading, no
	// colour, nothing to read past the rooms themselves. The structure arrives
	// with the second directory, which is the first moment "which directory is this
	// room on" is a question anybody can have.
	const held = [...dirs.values()];
	// Whether rows name their directory, asked where that rule lives.
	const marked = dirsAreMarked(dirs);
	// Which directory the section's "+" names a room on. "Here" is the directory
	// of the conversation being read, which is the only reading of an unqualified
	// room name that a reader would recognise as their own. Reaching a room on a
	// directory this tab has not opened is the join card's job, and the card is
	// where the locator lives.
	const here = activeKey !== null ? convs.get(activeKey)?.dir ?? held[0]?.id ?? dirId("") : held[0]?.id ?? dirId("");
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
				<IconButton
					id="railToggle"
					className="mark-btn"
					icon="mark"
					label="Rooms and direct messages"
					size={mobile ? "large" : "normal"}
					title={railShown ? "Hide the rooms list" : "Show the rooms list"}
					aria-pressed={railShown}
					onClick={() => peer.showRail(false)}
				/>
				pancake <small>rooms</small>
			</div>
			<RailSection
				id="newRoom"
				title="Your rooms"
				listId="roomList"
				open={open === "room"}
				label={marked ? "Create or open a room in " + directoryName(here, homeDir) : "Create or open a room"}
				placeholder="room name"
				max={MAX_ROOM}
				noun="room name"
				canAdd
				onOpen={opener("room")}
				onSubmit={(name) => peer.pickRoom(here, name)}
				onElsewhere={peer.addDirectory}
				onError={(text) => peer.banner({ kind: "error", text })}
				sigil="#"
				// Stated whether or not this tab holds more than one directory. A room
				// row stays quiet about its directory while there is only one, because
				// there is nothing to tell apart; this panel is the one moment the
				// answer is still open, so it says where the room is going even then.
				where={{ name: directoryName(here, homeDir), slot: dirs.get(here)?.slot }}
			>
				<YourRooms
					convs={convs}
					dirs={dirs}
					home={homeDir}
					activeKey={activeKey}
					marked={marked}
					empty={emptyDirs}
					onPick={(conv) => peer.pickRoom(conv.dir, conv.id)}
					onLeave={peer.leaveRoom}
					onAbout={peer.aboutDirectory}
					onJoinOn={(dir) => peer.addDirectory("", dir)}
					onLeaveDir={peer.leaveDirectory}
				/>
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
				canAdd={inARoom}
				sigil="@"
				onOpen={opener("dm")}
				onSubmit={peer.startDm}
				onError={(text) => peer.banner({ kind: "error", text })}
			>
				<DmRows
					convs={convs}
					activeKey={activeKey}
					inARoom={inARoom}
					dirs={dirs}
					home={homeDir}
					marked={marked}
					onOpen={peer.openConv}
					onClose={peer.closeDm}
					onAbout={peer.aboutDirectory}
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
