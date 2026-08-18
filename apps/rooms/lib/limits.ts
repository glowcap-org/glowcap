// Transport-neutral wire shapes the rooms app shares: the caps a room enforces
// on names, lines, files, and the bring-ups it carries between members, the
// waits it will not exceed, and the presence-change shape a room line carries.
// These belong to the room vocabulary, not to any one carrier, so the rendering
// layer (ui/) and the CapTP client (lib/room_client.ts) read them directly.
// (The JSON bridge and its schema were retired with the browser-peer page.)
//
// A few of the rules that *apply* a cap live here too, and only those whose
// subject no single module owns: a name is granted by a room, registered by the
// directory, and offered an inbox by a member, and a line is measured by the
// composer that warns and the room that refuses. Written out in each place
// instead, they were the same sentence three and four times over, which is that
// many authorities for one rule. A cap whose subject does have an owning module
// keeps its rule there — an attachment's is in `attachment.ts` beside the
// record it describes.

/** Hard length caps a room enforces, so an oversize name or line is refused at
 * the edge instead of silently truncated (a lying path that delivered half a
 * line as if it were whole). */
export const MAX_NICK = 32;
export const MAX_ROOM = 32;
/** How many bytes of entropy name a private room.
 *
 * The table a public room is entered from is keyed by folded name; a private
 * room's key is these bytes as hex, so nothing can search that table for one.
 * Sixteen is the shape of a swissnum, and this is the same kind of secret. */
export const PRIVATE_ROOM_KEY_BYTES = 16;
/** The longest durable room record a server keeps: a public room's name, or a
 * private room's key, whichever is longer. Both are durable names — the string
 * a room's sturdyref is minted from — so one bound covers them. */
export const MAX_DURABLE_ROOM = Math.max(MAX_ROOM, 1 + PRIVATE_ROOM_KEY_BYTES * 2);
export const MAX_LINE = 8192;

/** Whether a subscribe that was refused for a held name may present a name
 * voucher, the proof that this reader already holds that name here.
 *
 * A voucher is single-use bytes, and presenting one is being that member on any
 * connection — so what matters is who receives it. Each clause below is one
 * reason the answer is no:
 *
 * `trusted` is the load-bearing one. A room reached by name, or redeemed from a
 * link, is provably the directory's own: it came from the directory, or
 * `enliven` refused a peer mismatch. A room that arrived as a reference over a
 * direct line is hosted by whoever handed it over, which is outside the
 * directory's trust domain, and this app cannot tell such an object from a real
 * room by looking. A voucher goes only to a host inside that domain. The cost
 * is named and small: the same reader arriving on a second connection the
 * server cannot recognise as theirs takes a suffixed name in a handed room
 * rather than their own.
 *
 * The rest keep one attempt honest. Only the first try may present one, because
 * a voucher the room did not accept will not be accepted twice; only one may be
 * presented per attempt; and only for the reader's own registered name, since a
 * voucher proves that name and nothing else.
 *
 * This is client-side policy on purpose. The directory redeems a voucher only
 * when it arrives at one of its own rooms, so binding it tighter server-side
 * would add nothing: every genuine room already sits inside the one trust
 * domain that holds all the names. The decision with anything at stake is the
 * one made here, about whom to hand the bytes to. */
export function mayPresentNameVoucher(at: {
	/** Whether this room reference came by a path that proves it is the
	 * directory's own, rather than one handed over from outside it. */
	trusted: boolean;
	/** Whether the refusal was the room saying the name is already held. */
	nickTaken: boolean;
	/** Which attempt this is. Only the first presents a voucher. */
	attempt: number;
	/** Whether this attempt already carried one. */
	presented: boolean;
	/** Whether the name asked for is the one this directory granted this
	 * reader. A voucher proves that name and no other. */
	ownName: boolean;
}): boolean {
	return at.trusted && at.nickTaken && at.attempt === 0 && !at.presented && at.ownName;
}

/** Why this app will not answer to `nick`, or null when it will.
 *
 * A room grants a name, the directory registers one, and a member offers an
 * inbox to one, and all three hand out or hold the same thing: what somebody is
 * called in front of everyone else. One answer, so three places cannot come to
 * describe one ceiling differently. */
/** The names a line addresses a whole room by. Mentions understand every
 * spelling, completion proposes two of them, and granting reserves all of
 * them, so the words stay vocabulary rather than becoming people. */
export const ROOM_MENTIONS: readonly string[] = ["here", "room", "channel", "everyone", "all"];

export function nickRefusal(nick: string): string | null {
	if (nick.length === 0) return "a name may not be empty";
	if (nick.length > MAX_NICK) return `a name may be at most ${MAX_NICK} characters`;
	// The room speaks under the sender name "room", and every client renders
	// that sender as the room's own voice: no avatar, no attribution, drawn as
	// a system banner — and exempt from ignoring, because a system line is
	// nobody's to silence. A member granted the name would wear all of that:
	// their lines would read as the room announcing things, and the one abuse
	// tool the app has could not reach them. Folded, so the reservation does
	// not depend on which spelling a renderer happens to compare.
	const folded = nick.toLowerCase();
	if (folded === "room") return `the name "room" is the room's own voice`;
	// The rest of the room-wide vocabulary addresses everyone at once. A member
	// wearing one of these words could never be addressed apart from the room:
	// a mention of their name reaches everybody, and a direct line or an
	// invitation toward them names a word instead of a person. Same folding as
	// "room", for the same reason.
	if (ROOM_MENTIONS.includes(folded)) return `the name "${nick}" addresses everyone in a room`;
	// A granted name flows unescaped into every client's display and, in the
	// terminal clients, straight to stdout — so a control character in a name is
	// an ANSI escape injected into every reader's terminal (`clients/deno/chat`
	// prints `${from}: ${text}`), and a text-direction override is one name
	// worn to look like another. Refuse exactly the categories that do that;
	// letters of every script, combining marks, and the emoji joiners stay, so
	// an international or emoji name is untouched.
	//   \u0000-\u001F,\u007F-\u009F  C0/C1 controls, incl. ESC, newline, tab, DEL
	//   \u200E,\u200F                 LTR/RTL marks
	//   \u2028,\u2029                 line / paragraph separators
	//   \u202A-\u202E,\u2066-\u2069  bidi embeddings, overrides, isolates
	// The control characters are the subject, so matching them is the point
	// rather than an oversight the linter should keep asking about.
	// deno-lint-ignore no-control-regex
	if (/[\u0000-\u001F\u007F-\u009F\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]/.test(nick)) {
		return "a name may not contain control or text-direction characters";
	}
	return null;
}

/** What a line spends of that allowance: its UTF-8 bytes.
 *
 * Bytes rather than characters because that is what the wire counts. An emoji is
 * one thing to type, a `length` of two in JavaScript, and four bytes on the
 * wire, so a line measured any other way passes one side and is refused by the
 * other. It lives beside the cap because both sides count with it: the composer
 * that warns while somebody types, and the room that refuses — and the room is
 * the one that has to, since a client's own check is a courtesy to its reader
 * and nothing a room may rely on. */
export function lineCost(text: string): number {
	return new TextEncoder().encode(text).length;
}
/** The longest topic a room accepts. Shorter than a line because a topic is
 * read at a glance, above every message, on a phone as well as a screen. */
/** How many lines of one conversation this window keeps.
 *
 * A log grew with whatever arrived, for as long as the tab was open, and every
 * new line copied the whole of it. Neither end of that is this window's choice:
 * how much a room says is the room's, and a tab left open in a busy one spends
 * the afternoon getting slower. What is kept is what a reader scrolls back
 * through, and this app keeps nothing across a reload anyway, so the oldest
 * going is the ordinary end of a line's life here rather than a loss.
 *
 * Lines that leave take what they were holding with them: a picture's object
 * URL, the capability its bytes come from, and the reference that governed one
 * of our own. */
export const MAX_SCROLLBACK = 2000;

export const MAX_TOPIC = 300;
/** The longest reason a member may leave when they step away. Short because it
 * sits beside a name in the member list, where a sentence would push the names
 * off the edge. */
export const MAX_AWAY = 120;
/** How many name vouchers one registration may have outstanding, and how many
 * bytes each carries.
 *
 * A voucher is the single-use proof that a subscribe arriving on another
 * connection is the name's own holder, minted by the name capability
 * `register` answers with. Sized like a gift-id, because it is the same move:
 * unguessable bytes standing in for a reference that cannot be recognised
 * across sessions. Bounded per registration so a holder cannot grow another
 * process's memory by asking forever. */
export const MAX_NAME_VOUCHERS = 8;
export const NAME_VOUCHER_BYTES = 32;
/** How many room offers a tab keeps waiting for an answer.
 *
 * An offer arrives from a peer and sits until the reader answers it, and a
 * handed one holds a live reference while it sits — so without a ceiling, one
 * chatty peer grows this tab's memory for as long as the reader is away. Past
 * it, a new offer is declined on arrival and the reader is told, which loses
 * nothing that answering the queue would not recover. */
export const MAX_PENDING_INVITES = 16;
/** How many departed members a room's roster keeps as "seen".
 *
 * The roster deliberately remembers who has been here, but who joins is not
 * this window's choice: a room cycling join-and-leave under fresh names grew
 * the map — and the rendered list — for the life of the membership. Past the
 * ceiling the oldest offline rows go; the online rows are bounded by the
 * server's live connections and are never evicted. */
export const MAX_ROSTER_SEEN = 512;
/** What a reader who steps away without writing a reason is away for.
 *
 * One word said in two places — the menu that sets a standing and the `/away`
 * command — so the two cannot come to mean different things. */
export const PLAIN_AWAY = "away";

/** How many room names one server will make durable by minting links for them.
 * Live rooms remain ephemeral and unbounded in count; a link is different
 * because its name survives every disconnect and restart. The server therefore
 * refuses the durable allocation once this ceiling is full. */
export const MAX_ROOM_LINKS = 4096;
/** How many rooms one connection may have open at once.
 *
 * `open` is the one room-making verb a peer drives, and a private open never
 * collides and a public open with a generated name never does either — so a
 * connection could call it in a loop, each call a room record and a spawned
 * export reclaimed only when that connection ends. Every other peer-drivable
 * table here carries a ceiling; this is the one that did not. Generous, because
 * a legitimate host (a bot serving many rooms) is a real shape; past it, `open`
 * refuses by name. */
export const MAX_ROOMS_PER_CREATOR = 256;

/** Attachment caps.
 *
 * A blob read and an upload write each carry at most `BLOB_CHUNK` bytes, well
 * under the 1 MiB session frame, so a file of any admitted size crosses in
 * bounded frames. `MAX_ATTACHMENT_BYTES` is the largest single file a message
 * accepts, and it is also what a reader will allocate for a size the record
 * claims — the reader holds that bound rather than trusting the number.
 * `MAX_FILE_NAME` and `MAX_MIME` cap the describing strings. */
export const BLOB_CHUNK = 64 * 1024;
export const MAX_ATTACHMENT_BYTES = 16 * 1024 * 1024;
export const MAX_FILE_NAME = 160;
export const MAX_MIME = 80;

/** How large a picture will load itself when it arrives.
 *
 * Pictures appear in a chat log rather than waiting behind a button, but the
 * bytes cross a session, and a reader scrolling past a photograph the size of
 * a video should not spend them without asking. Above this, the line reserves
 * the picture's shape and offers to load it. One authority, because the
 * client that decides and the component that draws the offer must agree. */
export const AUTO_IMAGE_BYTES = 2 * 1024 * 1024;

/** The largest pixel dimension a sender may declare for a picture. The number
 * only reserves layout space, so this is a sanity bound on a claim rather
 * than a limit on anything real. */
export const MAX_IMAGE_DIM = 65_535;

/** What one room will hold in media, and how many files that may be spread
 * across. The room hosts the bytes so a picture outlives the tab that posted
 * it, which means the room needs a ceiling it enforces rather than a promise
 * it hopes nobody tests. Passing either bound drops the oldest file: its
 * reference then breaks on `read` with `blob-expired`, because a stale
 * reference that answered zero bytes would look like an empty file. */
export const MAX_ROOM_ATTACHMENT_BYTES = 64 * 1024 * 1024;
export const MAX_ROOM_ATTACHMENTS = 128;

/** What one TypeScript process will retain for direct-message recipients that
 * have not fetched their files yet. Direct files have no room server to own
 * this budget, so the sender-side attachment module applies one process-wide
 * oldest-first ceiling instead. */
export const MAX_DIRECT_ATTACHMENT_BYTES = 64 * 1024 * 1024;
export const MAX_DIRECT_ATTACHMENTS = 128;

/** How many files one message may carry, which is the same number as how many
 * uploads one connection may stage into its next message. Published uploads
 * may still be streaming independently; their declared bytes remain covered
 * by the server-wide pending budget. */
export const MAX_MESSAGE_FILES = 8;

/** What the whole server will hold, across every room.
 *
 * The per-room ceilings above bound one room, which is a fairness rule and not
 * a resource one: rooms and connections are both unbounded, so a per-room
 * budget times unbounded rooms is unbounded memory. These are the ceilings
 * that actually hold, and the per-room ones sit under them so no single room
 * can take the lot.
 *
 * Held media is evicted oldest-first across every room when it fills.
 * In-flight uploads are not evictable — nobody has seen those bytes and there
 * is no owner to tell — so an upload that would not fit is refused at
 * `attach`, before a byte moves, against the size it declares there. */
export const MAX_SERVER_ATTACHMENT_BYTES = 256 * 1024 * 1024;
export const MAX_SERVER_PENDING_BYTES = 64 * 1024 * 1024;

/** How long an upload may sit without being written to or posted.
 *
 * A reservation is taken against the size an upload *declares*, so without
 * this a member could declare the largest file the room takes, write nothing,
 * and hold that share of the server's in-flight budget until it disconnected.
 * An upload that has gone quiet this long is dropped, its reservation
 * released and its capability handed back; the member sees its next `write`
 * refused and can start again. The window is generous next to the round trips
 * a real upload makes, because re-arming happens on every chunk. */
export const UPLOAD_IDLE_MS = 30_000;

/** How long one chunk of a transfer may take before the side waiting on it
 * gives up.
 *
 * A read for bytes the room does not have yet waits rather than answering
 * short, so a parked read is ordinary and a deadline here has to sit above the
 * longest honest one. `UPLOAD_IDLE_MS` is what makes that finite: a conforming
 * room settles every parked read within it, by finishing the upload or by
 * dropping one that has gone quiet. This sits well above that, so it never
 * fires against a room behaving itself.
 *
 * It has to exist because neither side of a transfer is trusted. A room is
 * whatever directory a reader typed, and the blob behind a file on a direct
 * line is hosted by the peer who sent it. Either can accept a read and simply
 * never answer, and the waiting side has no other way out: the row is drawn as
 * still arriving, and a row that is arriving is one nothing will restart.
 * The same bound covers the writing direction, where an answer that never comes
 * would otherwise make Stop a promise the composer cannot keep — a stop is
 * checked between chunks, so a chunk that never lands is never between. */
export const TRANSFER_STALL_MS = 60_000;

/** How long a request to a room or directory may go unanswered.
 *
 * Every verb this client sends is answered in one round trip: no handler on the
 * other side waits on anything before answering, and the two that do wait — a
 * read parked on bytes that have not arrived, and the write behind it — are
 * transfers and carry `TRANSFER_STALL_MS` instead. So a request still pending
 * this long is a partner that is not going to answer, and the shapes that
 * leaves behind are the ones nothing else recovers from: a line that says it is
 * sending, a Join that says it is joining, an edit that never lands. */
export const REQUEST_TIMEOUT_MS = 15_000;

/** How many reads one file will hold parked at once.
 *
 * A read that asks for bytes the room does not have yet waits rather than
 * answering short, because a reader could not tell a short answer from the end
 * of a file. That wait is a live object per read, and a member chooses how many
 * reads to make, so without a ceiling the one structure in this server that
 * nothing else bounds grows with what a peer sends. A member fetching a file
 * keeps one read outstanding on it, so this is far above a whole room opening
 * the same picture the moment it lands; past it the room refuses, and a refused
 * read is one the reader can ask for again.
 */
export const MAX_BLOB_READERS = 256;

/** How many direct-message inboxes one member will hold. Nothing withdraws a
 * host giftable, so each inbox a member offers costs a bootstrap row and an
 * export on every session it ever opens, for the life of the process. The peer
 * asking is the one who chose the name, so the count needs a ceiling that peer
 * cannot argue with. `max_dm_inboxes` in `cli/app/rooms_peer/common.zig` and in
 * `conformance/goblins-peer/racket/rooms-dm.rkt` are the same bound for the Zig
 * peer and the Goblins one. */
export const MAX_DM_INBOXES = 256;

/** How many WebRTC signaling exchanges the directory holds at once. An
 * exchange is transient scratch for one channel bring-up; the oldest is
 * evicted when the cap is hit, so a flood of offers cannot pin unbounded
 * routing rows. A candidate for an evicted exchange is dropped, which a
 * caller experiences as a failed dial, not a wedged directory. */
export const MAX_SIGNAL_EXCHANGES = 64;

/** How much of a bring-up the directory will carry between two members.
 *
 * An offer, an answer, and each candidate pass through the directory verbatim,
 * which makes the room the one place a member can reach another member with a
 * string of their choosing. The exchange itself is bounded and expires, and the
 * ownership rules say who may put what into it — but nothing said how large it
 * could be, so one registered member could push whatever they liked at another
 * and make the room carry it both ways.
 *
 * A session description is a few kilobytes of text with its candidates bundled
 * in; one candidate is a line. Both are set well above what a browser produces
 * and far below what a room should relay, and the candidate bound is the one the
 * browser binding already holds its own staging to. */
export const MAX_SIGNAL_SDP = 16 * 1024;
export const MAX_SIGNAL_CANDIDATE = 4096;

/** How long the directory's own handle for a bring-up may be, and the key
 * designator naming its other side. Both are short identifiers, minted here or
 * validated elsewhere; this is what keeps one from arriving as a megabyte of
 * text to be held as a map key. */
export const MAX_SIGNAL_ID = 128;

/** Whether one relayed signaling message is one to act on.
 *
 * Both ends ask. The directory asks because it carries this between two members
 * and its size is the room's to bound rather than a sender's to choose; a member
 * asks because a directory is whatever answered the address they typed, and what
 * it relays is only as bounded as the directory felt like being. The answers
 * differ — the room refuses out loud, a member drops a message it cannot use —
 * but the rule does not. */
export function relayedSignalFits(kind: "description" | "candidate", id: string, payload: string): boolean {
	if (id.length === 0 || id.length > MAX_SIGNAL_ID) return false;
	if (payload.length === 0) return false;
	return payload.length <= (kind === "description" ? MAX_SIGNAL_SDP : MAX_SIGNAL_CANDIDATE);
}

/** A directory exchange that has not been explicitly retired by its offerer
 * cannot retain routing capability state forever. */
export const SIGNAL_EXCHANGE_TIMEOUT_MS = 30_000;

/** How long a member may pause mid-draft before we stop telling the room they
 * are typing. */
export const TYPING_IDLE_MS = 4_000;

/** How long another member's typing flag stands, unrefreshed, before a reader
 * clears it themselves — the guard against a dropped "stopped" leaving an
 * indicator up for good.
 *
 * Derived rather than chosen, because the two are one decision. A reader has to
 * wait longer than a sender pauses: shorter, and the indicator would clear while
 * the sender still believes it is showing, then flick back on their next
 * keystroke. Written as a sum, raising the pause raises the wait with it, which
 * is the only relationship between them that has to hold. */
export const TYPING_CLEAR_MS = TYPING_IDLE_MS + 2_000;

/** Which transport a session holds to the room server, named for the UI so it
 * can label a direct-message path ("encrypted iroh QUIC" vs "a direct TCP
 * connection"). */
export type Transport = "tcp" | "iroh";

/** A presence change carried on a room line: the full roster, or one member
 * coming or going. */
export type Presence =
	| { kind: "roster"; names: string[] }
	| { kind: "join" | "leave"; name: string }
	/** A member's own standing. An empty reason is them saying they are back,
	 * which is a thing somebody does on purpose and so is a change rather than
	 * nothing said. */
	| { kind: "away"; name: string; reason: string };
