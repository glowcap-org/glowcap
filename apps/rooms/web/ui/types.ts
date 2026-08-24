// ── Domain types ───────────────────────────────────────────────────────────
// The app's own model. The wire-protocol types — Transport, Presence, and the
// room limits — live in lib/limits.ts.
//
// Everything here is a value. The store replaces records rather than mutating
// them, so React can tell one version from the next by identity, and so a piece
// of the page that did not change does not repaint.

// A chat message carries an optional send state for our own optimistic sends. A
// room message paints as "sending" and clears when the room echoes it back; a DM
// message clears when its direct send settles. A rejected send becomes "failed"
// (tinted, with an explicit retry action). Absent means confirmed — every line
// we did not send ourselves, and every one of ours the wire has acknowledged.
/** Where one of our own messages stands.
 *
 * `failed` and `refused` are both "not sent"; what they differ in is whether
 * pressing again could change that. A line lost with a session may go the
 * moment one comes back, so it keeps a retry. A line typed into a conversation
 * whose member has left never can, because the name is back in the room's hands
 * and the next holder is somebody else — so it is drawn without one. A control
 * that cannot succeed is worse than no control: it invites a reader to try
 * again for as long as they are willing to believe it might work. */
export type SendState = "sending" | "failed" | "refused";

/** Whether a message is one the room never took. Both unsent states answer
 * yes; what a reader is offered about it is the next question. */
export function isUnsent(state: SendState | undefined): boolean {
	return state === "failed" || state === "refused";
}

/** Whether sending it again could work. Asked here rather than decided inside
 * the bubble that draws it, so the rule has one home and a test can reach it:
 * the interface must never offer an action that cannot succeed. */
export function canRetry(state: SendState | undefined): boolean {
	return state === "failed";
}

/** A file on a chat message, as the interface knows it.
 *
 * The capability its bytes come from is not here: `net.ts` holds that, keyed
 * by the file's id, the same way it holds every other live reference. What the
 * store carries is what the page draws — the file's description, how far a
 * fetch has got, and the object URL once the bytes are in hand. */
export interface AttachmentView {
	/** Unique for this tab. A message may carry several files, so the file owns
	 * the identity used for progress, fetching, viewing, and URL lifetime. */
	id: number;
	name: string;
	mime: string;
	size: number;
	/** The picture's declared pixel size, zero when unknown. The log reserves
	 * this shape before the bytes arrive, so a conversation full of images
	 * settles rather than jumping as each one loads. */
	width?: number;
	height?: number;
	/** Set once the bytes are here: what an image renders from and a download
	 * link points at. */
	url?: string;
	/** Bytes so far while a fetch is running; absent when none is. */
	got?: number;
	/** Why the last transfer failed, if it did. */
	error?: string;
	/** Set when nothing is left to try: the room dropped the file to stay under
	 * its media ceiling, the connection that carried the reference ended, or the
	 * upload that would have put the bytes there failed. The reason above still
	 * says what happened; this says the file is not coming, so the row keeps its
	 * sentence and loses its control. */
	lost?: boolean;
}

export type ViewerDirection = "previous" | "next";

/** A directory, as everything above the wire names it: the locator that reached
 * it. One string, so it keys a map and reads in a diagnostic, and stable for as
 * long as this tab holds that directory.
 *
 * It is its own type rather than a bare string because it is the half of a
 * room's identity that used to be assumed. Two directories may each have a room
 * called `general`, and those are two rooms with two rosters; a nickname is one
 * directory's to grant, so the same name on two of them is two people. A `string`
 * in that position carries the name and loses whose namespace it is in, which is
 * the one thing a reader of the key most needs to know. */
export type DirId = string & { readonly __dir: unique symbol };

export type LiveRooms = ReadonlyMap<string, import("../../lib/directory_publications.ts").RoomInfo>;

export function liveRoomNames(rooms: LiveRooms): string[] {
	return [...rooms.values()].map((room) => room.name);
}

export function liveRoomCounts(rooms: LiveRooms): ReadonlyMap<string, number | null> {
	return new Map([...rooms.values()].map((room) => [room.name, room.count]));
}

/** Name a directory by the locator that reaches it. */
export function dirId(locator: string): DirId {
	return locator as DirId;
}

/** How many directories can wear a mark of their own.
 *
 * The ramp's length, and a real ceiling rather than a wrap: past it none wears
 * one at all. Two directories sharing a colour asserts a sameness that is not
 * there, and five coloured beside three grey asserts it just as loudly, so the
 * mark is either complete or absent. */
const DIR_MARKS = 5;

/** Whether a surface says which directory it belongs to.
 *
 * One directory needs nothing said about it: everything on screen is on it, and
 * naming it on every row would be noise. The second one makes "which directory
 * is this" a question a reader can have, and it stays a question however many
 * more arrive, so this has no ceiling. It used to share one predicate with the
 * colors below, and past the ramp a row then lost the words as well. That is
 * exactly backwards: the more directories are in hand, the more a reader needs
 * the name. */
export function dirsAreNamed(dirs: ReadonlyMap<DirId, DirView>): boolean {
	return dirs.size > 1;
}

/** Whether the directories this tab holds also wear their colors.
 *
 * The words' condition and the ramp's ceiling together, because a color is
 * only ever the glance at something the words already say. Asked here rather
 * than counted at each place that draws one, so the rail and the card
 * describing a directory agree: a card wearing a color the rail is not showing
 * would be naming a distinction the reader cannot see anywhere else. Which
 * color that is, when they do wear one, is `dirMark`. */
export function dirsWearMarks(dirs: ReadonlyMap<DirId, DirView>): boolean {
	return dirsAreNamed(dirs) && dirs.size <= DIR_MARKS;
}

/** Which `data-dir` a surface wears for this directory.
 *
 * This page's own directory is not a slot in the ramp: it is the product, and
 * it wears `home` (teal) wherever it is marked. A foreign directory wears its
 * slot. One function so the rail, the join card, and the directory card cannot
 * disagree. Which of them is showing a color at all is `dirsWearMarks`, and
 * `dirMarkIn` is the two asked together. */
export function dirMark(
	dir: DirId,
	home: DirId | null,
	slot: number | null | undefined,
): "home" | string | undefined {
	if (home !== null && dir === home) return "home";
	return slot != null ? String(slot) : undefined;
}

/** The `data-dir` this directory wears among the ones this tab holds, and
 * undefined while none of them is wearing one.
 *
 * The one way a surface asks for a color. Both halves of the answer in one
 * call, because a caller that reaches for `dirMark` alone has skipped the
 * question of whether anything is marked at all, and every surface that did so
 * eventually disagreed with the rail beside it. */
export function dirMarkIn(
	dir: DirId,
	home: DirId | null,
	dirs: ReadonlyMap<DirId, DirView>,
): string | undefined {
	return dirsWearMarks(dirs) ? dirMark(dir, home, dirs.get(dir)?.slot) : undefined;
}

/** One human request to enter a room. `locator` is empty for the directory
 * serving this page; otherwise it names the peer that owns the room. Keeping
 * these as two fields avoids inventing an application URI grammar on top of
 * OCapN's locator grammar. */
export interface RoomDestination {
	room: string;
	locator: string;
	/** Make the room private: opened by reference, in no list, its name only a
	 * label. Offered on the join card so a reader can arrive at a directory —
	 * their own or a foreign one — and go private without first announcing
	 * themselves in a listed room. */
	hidden?: boolean;
}

/** Who a system banner is for.
 *
 * `here` is this tab talking to itself — a refused command, `/help`, a send
 * that never left. `shared` is something everybody in this conversation can
 * see: a join, a leave, a topic change the room announced. */
export type SysAudience = "here" | "shared";

/** One message in a conversation's history.
 *
 * `id` is minted by the store and is unique for the life of the tab. It is what
 * the log keys its bubbles on, and what the data layer uses to reconcile a send
 * with its echo. Files inside it have their own ids because their transfers are
 * independent. */
export type Item =
	| {
		kind: "chat";
		id: number;
		from: string;
		text: string;
		mine: boolean;
		at: number;
		state?: SendState;
		/** What the room calls this line, once it has said. An edit or a
		 * withdrawal names a line by this, which is why it is kept: our own line is
		 * painted before the room has named it, and learns its name from the echo. */
		lineId?: number;
		/** Changed since it was said. Worth showing, because a reader who replied
		 * to what it used to say should be able to tell that it moved. */
		edited?: boolean;
		/** Taken back by whoever posted it. The line stays in place rather than
		 * vanishing: a conversation that silently loses a line leaves everything
		 * answering it looking like a non-sequitur. */
		withdrawn?: boolean;
		/** Whether this tab still holds the reference that governs this line.
		 *
		 * Holding one is the authority to change or withdraw it, which is exactly
		 * what the pencil and the close beside a message act on. A room answers a
		 * post with one; a direct message has nothing to answer with, and the
		 * connection a reference came over is where it dies. So the controls follow
		 * this rather than authorship: drawn where they cannot work, they invite a
		 * reader to press for as long as they are willing to believe it might. */
		held?: boolean;
		/** One send is one message even when it carries several independently
		 * transferable files. Absent avoids allocating an empty array for the
		 * ordinary text-only case. */
		attachments?: readonly AttachmentView[];
	}
	/** A line this tab wrote to itself, or a line the room (or the other
	 * person on a direct message) said about the conversation. The log draws
	 * both as banners; `audience` is what tells a reader which is which. */
	| { kind: "sys"; id: number; text: string; at: number; audience: SysAudience }
	| { kind: "action"; id: number; from: string; text: string; at: number };
export type ChatItem = Extract<Item, { kind: "chat" }>;

/** Whether the reader does not hear this line, given who they are ignoring.
 *
 * One answer for every consumer — the log's draw filter, the unread count, and
 * the notification gates — because three copies of this rule drifted apart is
 * exactly the shape of bug it exists to end: a line that never draws must not
 * light a badge or ring a bell either.
 *
 * Never the reader's own line. Ignoring is about not hearing somebody else,
 * and a name is a claim a room grants and takes back — so the reader's own
 * current name can sit in their ignore list, put there against a previous
 * holder or by a slip, and their own lines still draw, count, and confirm.
 * Filtering them too is how a tab once became a silent failure: typed, sent,
 * delivered to everybody else, and invisible only at home. */
export function silencedByIgnore(item: Item, ignored: ReadonlySet<string>): boolean {
	if (item.kind === "sys") return false;
	return silencedFrom(item.from, item.kind === "chat" && item.mine, ignored);
}

/** The same rule for a consumer holding a sender rather than an item: the
 * notification gates and the typing indicator ask before any item exists. */
export function silencedFrom(from: string, mine: boolean, ignored: ReadonlySet<string>): boolean {
	return !mine && ignored.has(from.toLowerCase());
}

/** Where a conversation stands with its reader.
 *
 * A count and the line the rule hangs on are one fact, not two, so they are one
 * value. Spelled as a number beside a nullable id, two of the four combinations
 * mean nothing — a count with nowhere to draw the rule, and a rule with no run
 * behind it — and both were reachable. Here neither is spellable. */
export type Unread =
	| { kind: "caught-up" }
	/** Read, but the rule is still up: you have just arrived and it says where
	 * you left off for a moment longer. */
	| { kind: "rule-only"; from: number }
	| { kind: "unread"; count: number; from: number };

export interface ConvBase {
	/** What to call this conversation: a room's name, or a member's nick. Only a
	 * label, and not unique on its own — see `key` and `dir`. */
	id: string;
	/** What this conversation *is*. A room is its name within its directory. A
	 * direct conversation is the introduction that opened it, and nothing else —
	 * two introductions to the same nick are two conversations, because a nick is
	 * a claim the room hands out and hands back, not a person. */
	key: string;
	/** The directory this conversation lives on, and the half of a room's
	 * identity that used to be assumed because there was only ever one.
	 *
	 * A direct line carries it too, even though its key is already unique,
	 * because the nickname it reaches is that directory's grant: the line ends
	 * when the session that introduced it does, and the same nick on another
	 * directory is somebody else. */
	dir: DirId;
	/** Read-only to every holder: the store replaces this array rather than
	 * appending to it, which is how React tells one version from the next. */
	history: readonly Item[];
	unread: Unread;
}
// A conversation is either a public room or a direct message, and the two carry
// different state: a room has members, a DM has an introduction that is or is
// not yet live; both carry typing indicators. Modelling them as a discriminated
// union keeps each kind's fields off the other — a DM can't hold a member map,
// a room can't be "ready" — so the compiler enforces at every use what a mode
// flag would only ask a reader to remember.
/** Where a member stands in a room: whether they are here, and why they stepped
 * away if they said.
 *
 * Two facts rather than three states, because they are independent — somebody
 * who set a reason and then left is away *and* gone, and coming back in should
 * not have to restate it. An empty reason is simply not away. */
export interface Standing {
	online: boolean;
	away: string;
}

/** How many of a room's members are in it now.
 *
 * A room's roster keeps everyone it has seen: leaving turns a member offline
 * rather than removing them, because the name has to stay on the list for the
 * pane that shows who has been here. So counting the map counts the departed
 * too, and the rail's badge said "3 in the room" while the members pane beside
 * it said "1 online · 3 seen". Both read this. */
export function membersHere(members: ReadonlyMap<string, Standing>): number {
	let here = 0;
	for (const standing of members.values()) if (standing.online) here++;
	return here;
}

/** The rooms' word on who has stepped away, and why, per directory.
 *
 * A standing is room-scoped on the wire — `away` is something a member says to
 * a room — so a direct line, which has no roster of its own, can only relay
 * what the shared rooms on its directory say. Away everywhere they are online
 * is the nearest observable thing to the person having stepped away; present
 * in any one room means the person is at their desk, whatever another room
 * has been told, so a present word beats any reason. Keyed by directory and
 * then lowercased nick, because the same nick on another directory is a
 * different person. An entry holds the reason, or null for someone seen
 * present; a name with no entry has no roster word at all.
 *
 * One walk over every roster serves every direct row and the open
 * conversation's header, so callers derive it once per `convs` value (it is a
 * new map each store change) rather than re-walking per row. */
export function awayByPeer(convs: ReadonlyMap<string, Conv>): ReadonlyMap<DirId, ReadonlyMap<string, string | null>> {
	const dirs = new Map<DirId, Map<string, string | null>>();
	for (const conv of convs.values()) {
		if (conv.type !== "room") continue;
		let words = dirs.get(conv.dir);
		if (words === undefined) {
			words = new Map();
			dirs.set(conv.dir, words);
		}
		for (const [member, standing] of conv.members) {
			if (!standing.online) continue;
			const name = member.toLowerCase();
			if (standing.away === "") words.set(name, null);
			else if (!words.has(name)) words.set(name, standing.away);
		}
	}
	return dirs;
}

/** One person's word out of `awayByPeer`'s answer: the reason they are away,
 * or null while they are here or no shared roster says. */
export function awayOf(
	words: ReadonlyMap<DirId, ReadonlyMap<string, string | null>>,
	dir: DirId,
	name: string,
): string | null {
	return words.get(dir)?.get(name.toLowerCase()) ?? null;
}

export type Conv =
	| (ConvBase & {
		type: "room";
		/** Exact list/watch generation used to enter this room, when it was
		 * discoverable. */
		publicationId?: string;
		members: ReadonlyMap<string, Standing>;
		typers: ReadonlySet<string>; // nicks currently typing (auto-cleared by net.ts)
		/** The longest line this room will carry, in bytes, when it caps them
		 * tighter than this app does. Absent means it does not.
		 *
		 * A fact the room states about itself rather than a mode anybody turns on,
		 * which is what lets it differ per room in one tab: a room bridged to IRC
		 * has to fit a line into a protocol that allows 512 bytes for the whole
		 * thing, envelope included, while the room beside it has no such
		 * neighbour. Carried here so the composer can say so before a message is
		 * sent rather than after it is truncated somewhere the reader cannot see.
		 *
		 * Bytes and not characters, because that is what the limit downstream
		 * counts: an emoji is one thing to type and four bytes to carry, and a
		 * message measured the other way would pass here and be cut there. */
		lineBytes?: number;
		/** What this room is about, as the room says it. Absent when nothing has
		 * been set.
		 *
		 * The one piece of a room's own state, besides who is in it, that outlives
		 * everybody's session: a person arriving reads what the room is for
		 * without anyone having to say it again. Held here rather than as a line in
		 * the history because it is a standing fact and not something said at a
		 * moment — a hundred lines later it is still true, and a reader who
		 * scrolled past it should not have to go looking. */
		topic?: string;
		/** The commands this room has handed this membership, by name.
		 *
		 * Possession rather than permission: a command is here because the room
		 * answered with the reference that performs it, so two members of one room
		 * can hold different sets and neither client contains a rank. Empty
		 * against a room that offers none, which is what an older room is. */
		grants: ReadonlySet<string>;
		/** Whether this room is reached by a reference this tab holds rather than
		 * by its name.
		 *
		 * A private room has no name anybody can enter, so this conversation
		 * exists exactly as long as the reference does: it cannot be re-entered
		 * after the connection carrying it goes, the way a named room is. Its
		 * `id` is a label two rooms may share, which is why its key is minted
		 * here rather than derived from the name. */
		held: boolean;
		/** The sturdyref this tab holds for this room, when it has one.
		 *
		 * Present after `/link`, or after `/join` of a room link. Opening the
		 * conversation card never mints one: a mint is durable server state, and
		 * looking at a room is not asking for that. */
		link?: string;
		/** This room's own word for where this reader stands, or null while the
		 * room follows the directory (and through it, the reader).
		 *
		 * The innermost of the three levels `standingFor` reads. What the roster
		 * shows is the room's word, which is right: a standing is the room's to
		 * state. But a membership is a connection's, so a reconnect hands this
		 * reader a fresh one with nobody away — they are back in front of everyone
		 * else while their screen still says they stepped out, and neither side is
		 * told. This is the intention rather than the standing: kept because it
		 * outlives the membership that carried it, and said again to the room this
		 * tab re-enters. */
		standing: string | null;
	})
	| (ConvBase & {
		type: "dm";
		line: DmLine;
		typers: ReadonlySet<string>; // the peer, while typing (auto-cleared by net.ts)
	});

/** Where a direct line stands.
 *
 * Closed is terminal, and that is the point of naming these three rather than
 * carrying two booleans: the room takes a member's nick back when they leave, so
 * a closed conversation can never become live again — a later holder of the name
 * is a different person. As two flags, "closed and live" was spellable, and an
 * arriving line on a conversation the directory had already closed could set it. */
export type DmLine = "introducing" | "live" | "closed";
export type RoomConv = Extract<Conv, { type: "room" }>;
export type DmConv = Extract<Conv, { type: "dm" }>;

/** How a page notice reads. The icon and colour carry the kind; the words do
 * not restate it. */
export type ToastKind = "success" | "failure" | "warning";

/** One notice in the page stack. `id` is tab-local and unique for as long as
 * the notice is up, which is what the stack keys on and what dismiss names. */
export interface ToastNotice {
	id: number;
	kind: ToastKind;
	text: string;
}

/** One directory this tab holds, as the interface draws it.
 *
 * A directory is not a place you switch to: holding one means a live session, a
 * nickname registered on it, and everyone reachable through that nickname. So
 * each of these belongs to one directory and to no other, and a tab holding two
 * has two of them side by side rather than one that changes.
 *
 * The rooms this tab is *in* are not here. Those are conversations, keyed by
 * this directory and a name, because they carry history and unread counts that
 * outlive a session. What is here is only what the directory itself says. */
export interface DirView {
	id: DirId;
	/** Current public-room generations, keyed by case-folded name. */
	liveRooms: LiveRooms;
	/** Nicks (lowercased) this directory says are reachable for direct messages.
	 * A nick means someone else under another directory. */
	dmablePeers: ReadonlySet<string>;
	/** The name this directory granted, or empty until it has.
	 *
	 * Per directory, and this is the field the whole IRC-network argument rests
	 * on: a directory hands out a name for as long as you stay connected and
	 * takes it back when you go, so two of them may each have an `alice` and they
	 * are two people. Held once for the tab it was a lie with consequences: a
	 * second directory suffixing you to `alice-2` rewrote what the tab believed
	 * it was called everywhere, so your own messages coming back from the first
	 * stopped reading as yours and sat unconfirmed for good. */
	nick: string;
	/** Which of the ramp's marks this directory wears, from one.
	 *
	 * Handed out by the store when the directory is opened, and held for as long
	 * as this tab holds it, so nothing recolours when an unrelated directory
	 * goes. A number rather than a colour derived from the name, because a hash
	 * owns nothing and cannot promise two directories differ: at three of them it
	 * gave two of them the same mark almost half the time, which is worse than no
	 * mark, since a repeated colour claims they are the same place. */
	slot: number;
	/** Whether this directory has ever answered in this tab.
	 *
	 * It is what tells a first attempt from a reconnection, and a correctable
	 * mistake from a directory that has gone away: an address typed once and never
	 * reached is most likely wrong, and retrying it forever turns a typo into a
	 * permanent row nothing can remove. */
	reached: boolean;
	/** This directory's connection, which is what its own dot reports. One
	 * directory reconnecting says nothing about the others. */
	session: SessionPhase;
	/** What this directory is doing, which is the sentence beside its dot. */
	statusText: string;
	/** Why nobody can reach this tab for direct messages on this directory, and
	 * empty while they can.
	 *
	 * Being reachable is a registration this tab makes and the directory can
	 * refuse, most often because the name is held by a connection it has not
	 * reaped yet. That clears on its own, so it is retried; when the retries are
	 * spent the name belongs to somebody else, and this window stays in every
	 * roster looking perfectly ordinary while no message can arrive. Nothing said
	 * so, which made it the one failure here a reader could not find out about at
	 * all — not from the interface, and not from the person who could not reach
	 * them either. */
	dmUnreachable: string;
	/** This directory's own word for where this reader stands, or null while it
	 * follows the reader's own. The middle of the three levels `standingFor`
	 * reads, and the one an IRC client would call the whole answer: away is a
	 * thing you are on a server, in every channel on it at once. */
	standing: string | null;
}

/** A room somebody has offered this tab, waiting to be taken up or let go.
 *
 * Two ways an offer arrives, told apart by `way` because their lifetimes
 * differ and the reader deserves the truth about each:
 *
 *   `handed`  the room itself, a live reference the sender's runtime carried
 *             across as a handoff. It lives as long as live references live —
 *             the sessions under it — so one that has gone stale is reported
 *             when taking it up fails, and the answer is to ask for another.
 *             The reference is held in `net.ts` with the connections; this row
 *             is what the rail draws.
 *   `link`    durable data the room minted (a sturdyref), which survives every
 *             connection under it. Taking it up redeems the string.
 *
 * Declining a handed room releases the reference; declining a link forgets a
 * string. */
export interface Invitation {
	/** This tab's name for the offer, which is also how it is answered. */
	id: string;
	/** The directory whose line it arrived on, which is where it is drawn and
	 * whose session redeems a link. */
	dir: DirId;
	way: "handed" | "link";
	/** What the person offering it calls the room. A label, not a way in: two
	 * private rooms may share one. */
	label: string;
	/** Who offered it. */
	from: string;
	/** The sturdyref that is a `link` offer, and empty for a handed room. */
	link: string;
}

// The operations-capability vocabulary lives beside its panes; re-exported
// here so the page vocabulary keeps one import surface.
export * from "./ops/types.ts";

/** How the foot of the sidebar reads the connection.
 *
 * This is the session and nothing else. What the application is doing — entering
 * a room, picking one, refusing a name — is a sentence beside it, not a phase:
 * carried in one field, "connecting" was being written over a healthy session
 * and the dot went amber while everything worked. */
export type SessionPhase = "connecting" | "connected" | "disconnected" | "reconnecting";

/** Which panel Settings is showing. Locators is the ordinary opening,
 * Capabilities holds the operations toggles, and Advanced holds preferences
 * that save by reload. Help is its own modal and Operations its own page,
 * not panels here. */
/** One entry in the page's bounded trouble journal: a failure that had no
 * reader-facing surface of its own, kept where an operator can read it
 * instead of dying in the console. Repeats of the same trouble fold into
 * `count` rather than growing the ring. */
export interface TroubleRow {
	readonly source: string;
	readonly reason: string;
	readonly count: number;
}

export type SettingsTab = "overview" | "capabilities" | "settings";
