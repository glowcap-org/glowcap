// Transport-neutral wire shapes the rooms app shares: the caps a room enforces
// on names, lines, files, and the bring-ups it carries between members, the
// waits it will not exceed, and the presence-change shape a room line carries.
// These belong to the room vocabulary, not to any one carrier, so the rendering
// layer (ui/) and the CapTP client (lib/room/client.ts) read them directly.
//
// A few rules that apply a cap live here too, where no single module owns the
// subject. A name is granted by a room, registered by the directory, and offered
// an inbox by a member, and a line is measured by the composer that warns and
// the room that refuses. Written in each place, they would be one rule with
// several authorities. A cap whose subject has an owning module keeps its rule
// there. An attachment's is in `attachment.ts` beside the record it describes.

import { WEBRTC_MAX_SIGNAL_BYTES } from "@glowcap/abi";
import * as APPLICATION_DATA from "./application_data.ts";

/** Hard length caps a room enforces, so an oversize name or line is refused at
 * the edge instead of silently truncated (which would deliver half a line as
 * if it were whole). */
export const MAX_NICK = APPLICATION_DATA.MAX_NICK;
export const MAX_ROOM = APPLICATION_DATA.MAX_ROOM;
/** How many bytes of entropy identify a managed room independently of its
 * human name and admission policy. Sixteen is the size of a swissnum. This is
 * opaque application identity, never a directory lookup key. */
export const ROOM_ID_BYTES = APPLICATION_DATA.ROOM_ID_BYTES;
/** The longest durable room identifier a server keeps: an unmanaged room's
 * public name, or a managed room's opaque id, whichever is longer. */
export const MAX_DURABLE_ROOM = APPLICATION_DATA.MAX_DURABLE_ROOM;

/** Whether a durable room identifier is in the opaque managed-room namespace.
 * Length decides it: public names are at least one character shorter, so a
 * baseline room beginning with `~` cannot be mistaken for managed identity. */
export function isManagedRoomId(value: string): boolean {
	if (value.length !== 1 + ROOM_ID_BYTES * 2 || value[0] !== "~") return false;
	for (let at = 1; at < value.length; at += 1) {
		const code = value.charCodeAt(at);
		if (!((code >= 48 && code <= 57) || (code >= 97 && code <= 102))) return false;
	}
	return true;
}

/** Create opaque identity for one managed-room creation. Repeating a private
 * open with this value recovers the same room. Ordinary managed opens create
 * it inside the directory. */
export function newManagedRoomId(): string {
	const bytes = crypto.getRandomValues(new Uint8Array(ROOM_ID_BYTES));
	return "~" + [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
export const MAX_LINE = APPLICATION_DATA.MAX_LINE;

/** Whether a subscribe that was refused for a held name may present a name
 * voucher, the proof that this reader already holds that name here.
 *
 * A voucher is single-use bytes, and presenting one is being that member on any
 * connection, so what matters is who receives it. Each clause below is one
 * reason the answer is no.
 *
 * `trusted` matters most. A room reached by name, or redeemed from a link, is
 * the directory's own: it came from the directory, or `enliven` refused a peer
 * mismatch. A room that arrived as a reference over a direct line is hosted by
 * whoever handed it over, which is outside the directory's trust domain, and
 * this app cannot tell such an object from a real room by looking. A voucher
 * goes only to a host inside that domain. A handed room that cannot recognize
 * the reader refuses their requested name and may suggest another. It never
 * changes their identity silently.
 *
 * The other clauses bound one attempt. Only the first try may present a
 * voucher, because a voucher the room did not accept will not be accepted
 * twice. Only one may be presented per attempt, and it goes only for the
 * reader's registered name, since a voucher proves that name and nothing else.
 *
 * This is client-side policy. The directory redeems a voucher only when it
 * arrives at one of its own rooms, so binding it tighter server-side would add
 * nothing: every genuine room already sits inside the one trust domain that
 * holds all the names. The decision with anything at stake is the one made
 * here, about whom to hand the bytes to. */
export function mayPresentNameVoucher(at: {
	/** Whether this room reference came by a path that proves it is the
	 * directory's own, not one handed over from outside it. */
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

/** The names a line addresses a whole room by. Mentions understand every
 * spelling, completion proposes two of them, and granting reserves all of
 * them, so the words stay vocabulary and never become people. */
export const ROOM_MENTIONS = APPLICATION_DATA.ROOM_MENTIONS;

/** Why a room will not take a file described this way, or null when it will.
 *
 * Both sides ask: a sender so it fails before a byte moves, and the room
 * because it cannot trust a sender. The checks run in both places and the
 * sentences live here, so the two cannot give different answers. An archived
 * line asks too, and holds the same file rules without holding a session.
 *
 * Each sentence names its file, because a message may carry several and a
 * reader looking at eight chips cannot act on a rule stated in the abstract. */
export function attachmentRefusal(name: string, mime: string, size: number): string | null {
	const shown = name.length > 60 ? name.slice(0, 57) + "…" : name;
	if (name.length === 0) return "a file needs a name";
	if (name.length > MAX_FILE_NAME) {
		return `a file name may be at most ${MAX_FILE_NAME} characters, and this one is ${name.length}`;
	}
	if (mime.length > MAX_MIME) return `"${shown}" declares a media type longer than ${MAX_MIME} characters`;
	if (!Number.isSafeInteger(size) || size < 0) return `"${shown}" declares a size that is not a file size`;
	if (size > MAX_ATTACHMENT_BYTES) {
		const cap = MAX_ATTACHMENT_BYTES / (1024 * 1024);
		return `a file may be at most ${cap} MB, and "${shown}" is ${(size / (1024 * 1024)).toFixed(1)} MB`;
	}
	return null;
}

/** Why this app will not answer to `nick`, or null when it will.
 *
 * A room grants a name, the directory registers one, and a member offers an
 * inbox to one. All three hand out or hold what somebody is called in front of
 * everyone else, so one answer keeps the three from describing one ceiling
 * differently. */
export function nickRefusal(nick: string): string | null {
	if (nick.length === 0) return "a name may not be empty";
	if (nick.length > MAX_NICK) return `a name may be at most ${MAX_NICK} characters`;
	// The room speaks under the sender name "room", and every client renders
	// that sender as the room's own voice: no avatar, no attribution, drawn as
	// a system banner, and exempt from ignoring because a system line is
	// nobody's to silence. A member granted the name would wear all of that.
	// Their lines would read as the room announcing things, and the app's
	// only abuse tool could not reach them. The check folds the name so the
	// reservation does not depend on which spelling a renderer compares.
	const folded = nick.toLowerCase();
	if (folded === "room") return `the name "room" is the room's own voice`;
	// The rest of the room-wide vocabulary addresses everyone at once. A member
	// wearing one of these words could never be addressed apart from the room:
	// a mention of their name reaches everybody, and a direct line or an
	// invitation toward them names a word instead of a person. Same folding as
	// "room".
	if (ROOM_MENTIONS.includes(folded)) return `the name "${nick}" addresses everyone in a room`;
	// A granted name flows unescaped into every client's display and, in the
	// terminal clients, straight to stdout. A control character in a name is
	// an ANSI escape injected into every reader's terminal (`rooms-chat`
	// prints `${from}: ${text}`), and a text-direction override makes one name
	// look like another. Refuse those categories. Letters of every script,
	// combining marks, and the emoji joiners stay, so an international or emoji
	// name is untouched.
	//   \u0000-\u001F,\u007F-\u009F  C0/C1 controls, incl. ESC, newline, tab, DEL
	//   \u200E,\u200F                 LTR/RTL marks
	//   \u2028,\u2029                 line / paragraph separators
	//   \u202A-\u202E,\u2066-\u2069  bidi embeddings, overrides, isolates
	// The control characters are the subject, so matching them is intended.
	// deno-lint-ignore no-control-regex
	if (/[\u0000-\u001F\u007F-\u009F\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]/.test(nick)) {
		return "a name may not contain control or text-direction characters";
	}
	return null;
}

/** What room-carried text spends on the wire: its UTF-8 bytes. */
export function lineCost(text: string): number {
	return utf8ByteLengthUpTo(text);
}
/** How many lines of one conversation this window keeps.
 *
 * Without a cap, a log grows with whatever arrives for as long as the tab is
 * open, and every new line copies the whole of it. How much a room says is the
 * room's choice, and a tab left open in a busy one would spend the afternoon
 * getting slower. What is kept is what a reader scrolls back through. This app
 * keeps nothing across a reload anyway, so the oldest line going is the
 * ordinary end of a line's life here.
 *
 * Lines that leave take what they were holding with them: a picture's object
 * URL, the capability its bytes come from, and the reference that governed one
 * of our own. */
export const MAX_SCROLLBACK = 2000;

/** Live room messages awaiting a consumer. The web client normally has one
 * read pending, so this is outage and flood protection, not scrollback. */
export const MAX_ROOM_MESSAGE_BACKLOG = APPLICATION_DATA.MAX_ROOM_MESSAGE_BACKLOG;

/** The longest topic a room accepts. Shorter than a line because a topic is
 * read at a glance, above every message, on a phone as well as a screen. */
export const MAX_TOPIC = APPLICATION_DATA.MAX_TOPIC;
/** The longest reason a member may leave when they step away. Short because it
 * sits beside a name in the member list, where a sentence would push the names
 * off the edge. */
export const MAX_AWAY = APPLICATION_DATA.MAX_AWAY;

/** The longest attribution prefix a bridge may claim on this room's roster.
 *
 * A prefix is a namespace, not a decoration. `irc/bo` is a name in the room's
 * namespace and `bo` is a name in the service's, and the prefix keeps a foreign
 * member from taking a Rooms member's name. Short because it is carried on
 * every roster row a reader sees. */
export const MAX_SEAT_PREFIX = APPLICATION_DATA.MAX_SEAT_PREFIX;

/** What a bridge may write into a form it asks Rooms to draw.
 *
 * A form is a peer's description of an interface, so every part of it is
 * admitted the way inbound text is. The bounds come from what the real form
 * needs and a little over. A bridge that wants a longer label is asking for a
 * different interface and should say so instead of discovering the ceiling.
 *
 * A value is bounded well above a nick because a token or a passphrase is a
 * credential for somebody else's service, and this is not the place that
 * decides what shape those take. */
export const MAX_FORM_TITLE = APPLICATION_DATA.MAX_FORM_TITLE;
export const MAX_FORM_SAID = APPLICATION_DATA.MAX_FORM_SAID;
/** A label sits on a control, so it is short. Sixty instead of forty because
 * the real case names its service inside the label ("Disconnect from libera")
 * and a service name is itself bounded at `MAX_ROOM`. A bridge that shortened
 * that to fit would truncate the word telling a reader where they are about to
 * stop appearing. */
export const MAX_FORM_LABEL = APPLICATION_DATA.MAX_FORM_LABEL;
export const MAX_FORM_HINT = APPLICATION_DATA.MAX_FORM_HINT;
export const MAX_FORM_VALUE = APPLICATION_DATA.MAX_FORM_VALUE;
export const MAX_FORM_FIELDS = APPLICATION_DATA.MAX_FORM_FIELDS;
export const MAX_FORM_ACTIONS = APPLICATION_DATA.MAX_FORM_ACTIONS;

/** The JSON one form, or one set of answers to it, may cross as.
 *
 * Derived from the other bounds. The widest form they allow is a title, a
 * sentence, eight fields carrying a label, a hint and a value each, and three
 * actions, which is a few kilobytes with its punctuation. This is that with
 * room to spare, and it is still a ceiling. */
export const MAX_FORM_JSON = APPLICATION_DATA.MAX_FORM_JSON;

/** The JSON one whole gateway description may cross as.
 *
 * A gateway carries its two forms plus every connection with its leases, so
 * `MAX_FORM_JSON` is far too small for a loaded one, and the schema's
 * theoretical product (a thousand connections of a thousand leases) is not a
 * deployment size. A quarter mebibyte holds hundreds of fully loaded
 * connections and is checked before the description is parsed. */
export const MAX_GATEWAY_JSON = APPLICATION_DATA.MAX_GATEWAY_JSON;

/** What a bridge may name as the reach of one form's answers. Sized like a
 * room or a network name, because on every bridge so far it is one of those. */
export const MAX_FORM_SCOPE = APPLICATION_DATA.MAX_FORM_SCOPE;
/** The longest badge a bridge may put on one of its members, and the longest
 * sentence it may say under their name.
 *
 * A bridge writes its own words, so they are untrusted inbound text. They are
 * bounded here and rendered as text, never markup. The badge is short because
 * it sits in a chip beside a name that must not be pushed out of the sidebar.
 * The sentence has the second roster line to itself and is capped near an away
 * reason, the neighbouring line it must not out-shout. */
export const MAX_SEAT_BADGE = APPLICATION_DATA.MAX_SEAT_BADGE;
export const MAX_SEAT_SAID = APPLICATION_DATA.MAX_SEAT_SAID;
/** How many features one `carries` statement may name, and how long one name
 * may be. These bound a peer's line, not the vocabulary, which is shorter. A
 * room naming more than this has said something malformed. */
export const MAX_ROOM_FEATURES = APPLICATION_DATA.MAX_ROOM_FEATURES;
export const MAX_ROOM_FEATURE = APPLICATION_DATA.MAX_ROOM_FEATURE;

/** How many name vouchers one registration may have outstanding, and how many
 * bytes each carries.
 *
 * A voucher is the single-use proof that a subscribe arriving on another
 * connection is the name's holder, created by the name capability `register`
 * answers with. It is sized like a gift id: unguessable bytes standing in for a
 * reference that cannot be recognized across sessions. The count is bounded per
 * registration so a holder cannot grow another process's memory by asking
 * forever. */
export const MAX_NAME_VOUCHERS = APPLICATION_DATA.MAX_NAME_VOUCHERS;
export const NAME_VOUCHER_BYTES = APPLICATION_DATA.NAME_VOUCHER_BYTES;
/** How many room offers a tab keeps waiting for an answer.
 *
 * An offer arrives from a peer and sits until the reader answers it, and a
 * handed one holds a live reference while it sits. Without a ceiling, one
 * chatty peer grows this tab's memory for as long as the reader is away. Past
 * the ceiling, a new offer is declined on arrival and the reader is told,
 * which loses nothing that answering the queue would not recover. */
export const MAX_PENDING_INVITES = 16;
/** Read-only archive occurrences one browser will retain from peers before the
 * reader must use or decline one. Each row holds a live imported capability. */
export const MAX_PENDING_ARCHIVE_SHARES = 16;
/** Maximum online and disconnected names in one room's display roster.
 *
 * Explicit leaves remove names. Connection loss retains bounded offline rows
 * while the room remains occupied. At the display ceiling, offline rows give
 * way to live membership. Online rows are never evicted. */
export const MAX_ROSTER_SEEN = APPLICATION_DATA.MAX_ROSTER_SEEN;
/** Live memberships one room admits. The server enforces this before seating
 * a new member, and separately checks the actual UTF-8 roster line so long
 * Unicode names cannot turn a valid count into an oversized notification. */
export const MAX_ROOM_MEMBERS = APPLICATION_DATA.MAX_ROOM_MEMBERS;
/** Disconnected display names one occupied room keeps, oldest first. */
export const MAX_ROOM_OFFLINE = APPLICATION_DATA.MAX_ROOM_OFFLINE;
export const MAX_SESSION_DIRECTORY_ROWS = APPLICATION_DATA.MAX_SESSION_DIRECTORY_ROWS;
export const MAX_DIRECTORY_DISCOVERY_ROWS = APPLICATION_DATA.MAX_DIRECTORY_DISCOVERY_ROWS;
/** What a reader who steps away without writing a reason is away for.
 *
 * Both the menu that sets a standing and the `/away` command use this word, so
 * the two mean the same thing. */
export const PLAIN_AWAY = "away";

/** How many room names one server will make durable by creating links for
 * them. Live rooms remain ephemeral and unbounded in count, but a link is
 * different because its name survives every disconnect and restart. The server
 * refuses the durable allocation once this ceiling is full. */
export const MAX_ROOM_LINKS = APPLICATION_DATA.MAX_ROOM_LINKS;
export const MAX_TROUBLE_SOURCE_BYTES = APPLICATION_DATA.MAX_TROUBLE_SOURCE_BYTES;
export const MAX_TROUBLE_REASON_BYTES = APPLICATION_DATA.MAX_TROUBLE_REASON_BYTES;
export const MAX_OPERATOR_PAGE = APPLICATION_DATA.MAX_OPERATOR_PAGE;
/** How long a search over an operator list may be. A search is scanned
 * against every row, so its length is peer-influenced work per row. */
export const MAX_OPERATOR_QUERY = APPLICATION_DATA.MAX_OPERATOR_QUERY;
/** How many rows one bulk retire may take in a single call. The operator's
 * client runs again for what remains, so this bounds the turn, not the act,
 * and keeps a hundred-thousand-row sweep interruptible. */
export const MAX_OPERATOR_RETIRE_BATCH = APPLICATION_DATA.MAX_OPERATOR_RETIRE_BATCH;
/** Largest low-frequency operations list accepted from one capability. */
export const MAX_OPERATIONS_ROWS = APPLICATION_DATA.MAX_OPERATIONS_ROWS;
export const MAX_OPERATOR_MEMBERS_PER_ROOM = APPLICATION_DATA.MAX_OPERATOR_MEMBERS_PER_ROOM;
/** How many rooms one connection may have open at once.
 *
 * A private `open` never collides, a public open with a generated name need
 * not, and each durable room link can reconstruct an empty room. A connection
 * could drive any of those in a loop, each call leaving a room record
 * reclaimed only when its membership ends or the connection leaves. Every
 * room-creation path spends this registry-owned budget. It is generous because
 * a legitimate host (a bot serving many rooms) is a real shape. Past it,
 * creation refuses by name. */
export const MAX_ROOMS_PER_CREATOR = APPLICATION_DATA.MAX_ROOMS_PER_CREATOR;
export const MAX_ROOM_INVITATIONS = APPLICATION_DATA.MAX_ROOM_INVITATIONS;

/** Foreign rooms one directory retains in total and from one source session.
 * Both counts include the held room capability and its directory metadata. */
export const MAX_PEERED_ROOMS = APPLICATION_DATA.MAX_PEERED_ROOMS;
export const MAX_PEERED_ROOMS_PER_SOURCE = APPLICATION_DATA.MAX_PEERED_ROOMS_PER_SOURCE;
/** How long a foreign-room namespace and quota reservation may wait for the
 * handed capability to resolve. A source that never settles it must not hold
 * destination capacity for the life of its connection. */
export const PEERED_ROOM_READY_TIMEOUT_MS = APPLICATION_DATA.PEERED_ROOM_READY_TIMEOUT_MS;

/** Attachment caps.
 *
 * A blob read and an upload write each carry at most `BLOB_CHUNK` bytes, well
 * under the 1 MiB session frame, so a file of any admitted size crosses in
 * bounded frames. `MAX_ATTACHMENT_BYTES` is the largest single file a message
 * accepts, and it is also what a reader will allocate for a size the record
 * claims, so the reader holds that bound instead of trusting the number.
 * `MAX_FILE_NAME` and `MAX_MIME` cap the describing strings. */
export const BLOB_CHUNK = APPLICATION_DATA.BLOB_CHUNK;
export const MAX_ATTACHMENT_BYTES = APPLICATION_DATA.MAX_ATTACHMENT_BYTES;
export const MAX_FILE_NAME = APPLICATION_DATA.MAX_FILE_NAME;
export const MAX_MIME = APPLICATION_DATA.MAX_MIME;

/** How large a picture will load itself when it arrives.
 *
 * Pictures appear in a chat log without waiting behind a button, but the bytes
 * cross a session, and a reader scrolling past a photograph the size of a
 * video should not spend them without asking. Above this, the line reserves
 * the picture's shape and offers to load it. The client that decides and the
 * component that draws the offer share this constant so they agree. */
export const AUTO_IMAGE_BYTES = 2 * 1024 * 1024;

/** The largest pixel dimension a sender may declare for a picture. The number
 * only reserves layout space, so this is a sanity bound on a claim, not a
 * limit on anything real. */
export const MAX_IMAGE_DIM = APPLICATION_DATA.MAX_IMAGE_DIM;

/** What one room will hold in media, and how many files that may be spread
 * across. The room hosts the bytes so a picture outlives the tab that posted
 * it, so the room needs a ceiling it enforces. Passing either bound drops the
 * oldest file. Its reference then breaks on `read` with `blob-expired`,
 * because a stale reference that answered zero bytes would look like an empty
 * file. */
export const MAX_ROOM_ATTACHMENT_BYTES = APPLICATION_DATA.MAX_ROOM_ATTACHMENT_BYTES;
export const MAX_ROOM_ATTACHMENTS = APPLICATION_DATA.MAX_ROOM_ATTACHMENTS;
export const MAX_ARCHIVE_PENDING_ATTACHMENT_BYTES = APPLICATION_DATA.MAX_ARCHIVE_PENDING_ATTACHMENT_BYTES;

/** What one TypeScript process will retain for direct-message recipients that
 * have not fetched their files yet. Direct files have no room server to own
 * this budget, so the sender-side attachment module applies one process-wide
 * oldest-first ceiling. */
export const MAX_DIRECT_ATTACHMENT_BYTES = 64 * 1024 * 1024;
export const MAX_DIRECT_ATTACHMENTS = 128;

/** How many files one message may carry, which is also how many uploads one
 * connection may stage into its next message. Published uploads may still be
 * streaming independently, and their declared bytes remain covered by the
 * server-wide pending budget. */
export const MAX_MESSAGE_FILES = APPLICATION_DATA.MAX_MESSAGE_FILES;

/** What the whole server will hold, across every room.
 *
 * The per-room ceilings above are a fairness rule, not a resource bound. Rooms
 * and connections are both unbounded, so a per-room budget times unbounded
 * rooms is unbounded memory. These ceilings hold, and the per-room ones sit
 * under them so no single room can take the lot.
 *
 * Held media is evicted oldest-first across every room when it fills.
 * In-flight uploads are not evictable, since nobody has seen those bytes and
 * there is no owner to tell. An upload that would not fit is refused at
 * `attach`, before a byte moves, against the size it declares there. */
export const MAX_SERVER_ATTACHMENT_BYTES = APPLICATION_DATA.MAX_SERVER_ATTACHMENT_BYTES;
export const MAX_SERVER_PENDING_BYTES = APPLICATION_DATA.MAX_SERVER_PENDING_BYTES;

/** How long an upload may sit without being written to or posted.
 *
 * A reservation is taken against the size an upload declares. Without this
 * limit a member could declare the largest file the room takes, write nothing,
 * and hold that share of the server's in-flight budget until it disconnected.
 * An upload that has gone quiet this long is dropped, its reservation
 * released and its capability handed back. The member sees its next `write`
 * refused and can start again. The window is generous next to the round trips
 * of a real upload, because every chunk re-arms it. */
export const UPLOAD_IDLE_MS = APPLICATION_DATA.UPLOAD_IDLE_MS;

/** How long one chunk of a transfer may take before the side waiting on it
 * gives up.
 *
 * A read for bytes the room does not have yet waits instead of answering
 * short, so a parked read is ordinary and this deadline has to sit above the
 * longest legitimate one. `UPLOAD_IDLE_MS` makes that finite: a conforming room
 * settles every parked read within it, by finishing the upload or by dropping
 * one that has gone quiet. This sits well above that, so it never fires
 * against a well-behaved room.
 *
 * The deadline must exist because neither side of a transfer is trusted. A
 * room is whatever directory a reader typed, and the blob behind a file on a
 * direct line is hosted by the peer who sent it. Either can accept a read and
 * never answer, and the waiting side has no other way out: the row is drawn as
 * still arriving, and nothing restarts a row that is arriving. The same bound
 * covers the writing direction, where an answer that never comes would make
 * Stop a promise the composer cannot keep. A stop is checked between chunks,
 * so a chunk that never lands is never between. */
export const TRANSFER_STALL_MS = 60_000;

/** How long a request to a room or directory may go unanswered.
 *
 * Every verb this client sends is answered in one round trip. No handler on
 * the other side waits on anything before answering, except the two that
 * wait: a read parked on bytes that have not arrived, and the write behind it.
 * Those are transfers and carry `TRANSFER_STALL_MS` instead. So a request
 * still pending this long belongs to a partner that is not going to answer.
 * Nothing else recovers the states that leaves behind: a line that says it is
 * sending, a Join that says it is joining, an edit that never lands. */
export const REQUEST_TIMEOUT_MS = APPLICATION_DATA.REQUEST_TIMEOUT_MS;

/** How many reads one file will hold parked at once.
 *
 * A read that asks for bytes the room does not have yet waits instead of
 * answering short, because a reader could not tell a short answer from the end
 * of a file. That wait is a live object per read, and a member chooses how many
 * reads to make. Without a ceiling, the one structure in this server that
 * nothing else bounds grows with what a peer sends. A member fetching a file
 * keeps one read outstanding on it, so this is far above a whole room opening
 * the same picture the moment it lands. Past it the room refuses, and a
 * refused read is one the reader can ask for again.
 */
export const MAX_BLOB_READERS = APPLICATION_DATA.MAX_BLOB_READERS;

/** How many direct-message inboxes one member will hold live. Each inbox costs
 * a Host publication and an export on every session that projects it. Leaving
 * retires the alias, and already-issued capabilities keep their old actor
 * until their roots disappear. The peer asking chose the name, so the count
 * needs a ceiling that peer cannot argue with. The shared application owns
 * this bound, and the Goblins fixture checks the same contract. */
export const MAX_DM_INBOXES = APPLICATION_DATA.MAX_DM_INBOXES;
/** Repeated requests for the same reciprocal direct route inside this window
 * produce one notification. Expired rows are removed lazily, so the bound is
 * on active request pressure, not on every peer seen by a registration. */
export const DIRECT_REQUEST_COALESCE_MS = APPLICATION_DATA.DIRECT_REQUEST_COALESCE_MS;
/** A successful reciprocal request must produce a route inside the same
 * bounded interaction window as other Rooms requests. */
export const DIRECT_CONVERSATION_ROUTE_TIMEOUT_MS = APPLICATION_DATA.DIRECT_CONVERSATION_ROUTE_TIMEOUT_MS;

/** How many WebRTC signaling exchanges the directory holds at once. An
 * exchange is transient scratch for one channel bring-up. The oldest is
 * evicted when the cap is hit, so a flood of offers cannot pin unbounded
 * routing rows. A candidate for an evicted exchange is dropped, which a
 * caller experiences as a failed dial, not a wedged directory. */
export const MAX_SIGNAL_EXCHANGES = APPLICATION_DATA.MAX_SIGNAL_EXCHANGES;

/** Durable attenuated grants issued by one Rooms session. Active grants cost a
 * Host publication. Lifetime rows include revocation tombstones so no old
 * sturdyref can return through identifier reuse. */
export const MAX_ACTIVE_SESSION_GRANTS = APPLICATION_DATA.MAX_ACTIVE_SESSION_GRANTS;
export const MAX_LIFETIME_SESSION_GRANTS = APPLICATION_DATA.MAX_LIFETIME_SESSION_GRANTS;
/** Bridge credential rows one durable Rooms session keeps, one per directory
 * and bridge scope a reader answered a secret field for. A directory rarely
 * bridges more than a couple of networks, so this is two per directory the
 * workspace may hold. */
export const MAX_BRIDGE_SECRET_SCOPES = 64;
export const MAX_SESSION_GRANT_LABEL = APPLICATION_DATA.MAX_SESSION_GRANT_LABEL;
/** Room for a sentence saying why a link has gone quiet, and no more. It is
 * read by whoever holds that link, in place of the session. */
export const MAX_SESSION_GRANT_NOTE = APPLICATION_DATA.MAX_SESSION_GRANT_NOTE;

/** Durable attenuated archive-peer shares. Active shares cost a Host
 * publication. Lifetime rows include revocation tombstones so no old sturdyref
 * can return through identifier reuse. */
export const MAX_ACTIVE_ARCHIVE_SHARES = APPLICATION_DATA.MAX_ACTIVE_ARCHIVE_SHARES;
export const MAX_LIFETIME_ARCHIVE_SHARES = APPLICATION_DATA.MAX_LIFETIME_ARCHIVE_SHARES;

/** How much WebRTC bring-up text the directory will carry between two members.
 * A description follows the signal bound of the WebRTC package, and one ICE
 * candidate stays a smaller room relay policy. Both limits are bytes, not
 * UTF-16 code units. */
export const MAX_SIGNAL_SDP = WEBRTC_MAX_SIGNAL_BYTES;
export const MAX_SIGNAL_CANDIDATE = APPLICATION_DATA.MAX_SIGNAL_CANDIDATE;

/** How long the directory's handle for a bring-up may be, and the key
 * designator naming its other side. Both are short identifiers, created here or
 * validated elsewhere. The bound keeps one from arriving as a megabyte of text
 * to be held as a map key. */
export const MAX_SIGNAL_ID = APPLICATION_DATA.MAX_SIGNAL_ID;

/** Whether one relayed signaling message is one to act on.
 *
 * Both ends ask. The directory asks because it carries this between two members
 * and its size is the room's to bound, not a sender's to choose. A member asks
 * because a directory is whatever answered the address they typed, and what it
 * relays is only as bounded as that directory chose to be. The answers differ,
 * since the room refuses out loud and a member drops a message it cannot use,
 * but the rule is the same. */
export function relayedSignalFits(kind: "description" | "candidate", id: string, payload: string): boolean {
	if (id.length === 0 || !utf8Fits(id, MAX_SIGNAL_ID)) return false;
	if (payload.length === 0) return false;
	return utf8Fits(payload, kind === "description" ? MAX_SIGNAL_SDP : MAX_SIGNAL_CANDIDATE);
}

export function utf8Fits(text: string, maxBytes: number): boolean {
	return utf8ByteLengthUpTo(text, maxBytes) <= maxBytes;
}

/** UTF-8 bytes of `text`, stopping early once `stopAfter` is passed. The same
 * counter lives in `bindings/ts/webrtc/signal.ts`. Rooms keeps its own because
 * a chat app's line budget must not depend on the WebRTC package's internals
 * for a pure string measurement. */
function utf8ByteLengthUpTo(text: string, stopAfter?: number): number {
	let bytes = 0;
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 0x80) bytes += 1;
		else if (code < 0x800) bytes += 2;
		else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
			const next = text.charCodeAt(i + 1);
			if (next >= 0xdc00 && next <= 0xdfff) {
				bytes += 4;
				i++;
			} else {
				bytes += 3;
			}
		} else {
			bytes += 3;
		}
		if (stopAfter != null && bytes > stopAfter) return bytes;
	}
	return bytes;
}

/** A directory exchange that has not been explicitly retired by its offerer
 * cannot retain routing capability state forever. */
export const SIGNAL_EXCHANGE_TIMEOUT_MS = APPLICATION_DATA.SIGNAL_EXCHANGE_TIMEOUT_MS;

/** How long a member may pause mid-draft before we stop telling the room they
 * are typing. */
export const TYPING_IDLE_MS = 4_000;

/** How long another member's typing flag stands, unrefreshed, before a reader
 * clears it themselves. This guards against a dropped "stopped" leaving an
 * indicator up for good.
 *
 * Derived from the pause, because the two are one decision. A reader has to
 * wait longer than a sender pauses. Shorter, and the indicator would clear
 * while the sender still believes it is showing, then flick back on their next
 * keystroke. Written as a sum, raising the pause raises the wait with it, the
 * one relationship between them that has to hold. */
export const TYPING_CLEAR_MS = TYPING_IDLE_MS + 2_000;

/** Which transport a session holds to the room server, named for the UI so it
 * can label a direct-message path ("encrypted iroh QUIC" vs "a direct TCP
 * connection"). */
export type Transport = "tcp" | "iroh";
