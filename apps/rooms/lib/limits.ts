// Transport-neutral wire shapes the rooms app shares: the length caps a room
// enforces on names and lines, and the presence-change shape a room line
// carries. These belong to the room vocabulary, not to any one carrier, so the
// rendering layer (ui/) and the CapTP client (lib/room_client.ts) read them
// directly. (The JSON bridge and its schema were retired with the
// browser-peer page.)

/** Hard length caps a room enforces, so an oversize name or line is refused at
 * the edge instead of silently truncated (a lying path that delivered half a
 * line as if it were whole). */
export const MAX_NICK = 32;
export const MAX_ROOM = 32;
export const MAX_LINE = 8192;
/** The longest topic a room accepts. Shorter than a line because a topic is
 * read at a glance, above every message, on a phone as well as a screen. */
export const MAX_TOPIC = 300;
/** The longest reason a member may leave when they step away. Short because it
 * sits beside a name in the member list, where a sentence would push the names
 * off the edge. */
export const MAX_AWAY = 120;

/** How many room names one server will make durable by minting links for them.
 * Live rooms remain ephemeral and unbounded in count; a link is different
 * because its name survives every disconnect and restart. The server therefore
 * refuses the durable allocation once this ceiling is full. */
export const MAX_ROOM_LINKS = 4096;

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
