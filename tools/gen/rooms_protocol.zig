//! The Rooms wire grammar, declared once for the application and every client.
//!
//! This table owns the core method and notification spellings plus the
//! machine-shaped grammar the clients read: the directory's publication
//! record, watch notifications, room notify tails, subscribe answer, verbs
//! and whether each answers, registration-id form, and one-shot session
//! deadline. `apps/rooms/lib/protocol.ts` explains the vocabulary to people
//! and re-exports its generated TypeScript projection. The Rust application
//! and five terminal clients consume their generated projections too, so a
//! new spelling, kind, or field is one edit here.

const std = @import("std");

const Output = @import("output").Output;

pub const step_name = "gen-rooms-protocol";

/// Where the grammar is explained to a person.
pub const human_spec = "apps/rooms/lib/protocol.ts";

/// Where this table lives, named in every generated header.
pub const source = "tools/gen/rooms_protocol.zig";

pub const outputs = [_]Output{
    .{ .path = "apps/rooms/lib/protocol_data.ts", .generate = @import("rooms_protocol/data_ts.zig").generate },
    .{ .path = "apps/rooms/rust/application/src/protocol_data.rs", .generate = @import("rooms_protocol/data_rust.zig").generate },
    .{ .path = "apps/rooms/clients/deno/protocol_gen.ts", .generate = @import("rooms_protocol/ts.zig").generate },
    .{ .path = "apps/rooms/clients/python/_protocol_gen.py", .generate = @import("rooms_protocol/python.zig").generate },
    .{ .path = "apps/rooms/clients/racket/protocol-gen.rkt", .generate = @import("rooms_protocol/racket.zig").generate },
    .{ .path = "apps/rooms/clients/rust/protocol_gen.rs", .generate = @import("rooms_protocol/rust.zig").generate },
    .{ .path = "apps/rooms/clients/zig/protocol_gen.zig", .generate = @import("rooms_protocol/zig.zig").generate },
};

/// The wire type of one field or trailing argument, in the vocabulary every
/// client already validates natively.
pub const Ty = enum {
    /// Any string, empty included.
    string,
    /// A nonempty string.
    text,
    /// A non-negative integer.
    natural,
    boolean,
    /// A capability reference.
    reference,
    /// A directory-issued registration id in the form `registration_id` declares.
    registration_id,
    /// A list whose rows a sibling table declares.
    list,
    /// Any argument at all. A sibling reader owns its shape.
    any,

    /// The name each language's table carries, hyphenated the way the wire
    /// vocabulary is written.
    pub fn wireName(self: Ty) []const u8 {
        return switch (self) {
            .registration_id => "registration-id",
            else => @tagName(self),
        };
    }
};

/// The named sets of strings a field may be held to.
pub const Enumeration = enum {
    membership_kinds,
    publication_kinds,
    publication_proofs,
    seat_phases,

    pub fn values(self: Enumeration) []const []const u8 {
        return switch (self) {
            .membership_kinds => &.{ "observer", "participant" },
            .publication_kinds => &.{ "local", "foreign", "bridge" },
            .publication_proofs => &.{ "local", "authenticated", "session", "bridge" },
            .seat_phases => &.{ "rooms", "connecting", "linked", "failed" },
        };
    }

    /// The upper-case stem each language names the set by.
    pub fn stem(self: Enumeration) []const u8 {
        return switch (self) {
            .membership_kinds => "MEMBERSHIP_KINDS",
            .publication_kinds => "PUBLICATION_KINDS",
            .publication_proofs => "PUBLICATION_PROOFS",
            .seat_phases => "SEAT_PHASES",
        };
    }
};

/// One positional wire value.
pub const Field = struct {
    name: []const u8,
    ty: Ty,
    /// Whether a wire null is admitted in place of the value.
    nullable: bool = false,
    /// The strings admitted, when the field is an enumeration.
    values: ?Enumeration = null,
};

/// Every core Rooms method or notification word shared by TypeScript and
/// Rust. Enum names are the generated constant names in snake case. This
/// switch is the sole authority for their wire spellings.
pub const Token = enum {
    directory,
    room_sender,
    snapshot,
    open,
    open_managed,
    room_authorities,
    open_private_link,
    enter,
    enter_publication,
    link_publication,
    subscribe_publication,
    list,
    list_publications,
    named_publications,
    watch,
    watch_publications,
    unwatch_publications,
    advertised_location,
    publish_durable_room,
    publication_ready,
    publication_describe,
    revoke,
    link,
    subscribe,
    post,
    edit,
    withdraw,
    refile,
    line,
    history,
    edited,
    withdrawn,
    refiled,
    typing,
    leave,
    subject,
    line_bytes,
    carries,
    listed,
    unlisted,
    away,
    kick,
    governs,
    managed_room_identity,
    called,
    private,
    room_policy,
    room_policy_changed,
    membership_kind,
    mint_invitation,
    claim_invitation,
    set_subject,
    register,
    voucher,
    introduce,
    offer_inbox,
    offer_signaling,
    signal_offer,
    signal_check,
    signal_answer,
    signal_candidate,
    signal_done,
    signal_decline,
    sig_offer,
    sig_accepted,
    sig_answer,
    sig_candidate,
    sig_reject,
    attach,
    post_files,
    write,
    discard,
    read,
    dm,
    direct_ready,
    direct_requested,
    request_direct,
    member_registration,
    notify,
    membership_ended,
    room_authority_changed,
    opened,
    closed,
    count,
    registered,
    unregistered,
    truncated,
    roster,
    join,
    offline,
    seat,

    pub fn wire(self: Token) []const u8 {
        return switch (self) {
            .directory => "directory",
            .room_sender => "room",
            .snapshot => "snapshot",
            .open => "open",
            .open_managed => "openManaged",
            .room_authorities => "roomAuthorities",
            .open_private_link => "openPrivateLink",
            .enter => "enter",
            .enter_publication => "enterPublication",
            .link_publication => "linkPublication",
            .subscribe_publication => "subscribePublication",
            .list => "list",
            .list_publications => "listPublications",
            .named_publications => "namedPublications",
            .watch => "watch",
            .watch_publications => "watchPublications",
            .unwatch_publications => "unwatchPublications",
            .advertised_location => "advertisedLocation",
            .publish_durable_room => "publishDurableRoom",
            .publication_ready => "ready",
            .publication_describe => "describe",
            .revoke => "revoke",
            .link => "link",
            .subscribe => "subscribe",
            .post => "post",
            .edit => "edit",
            .withdraw => "withdraw",
            .refile => "refile",
            .line => "line",
            .history => "history",
            .edited => "edited",
            .withdrawn => "withdrawn",
            .refiled => "refiled",
            .typing => "typing",
            .leave => "leave",
            .subject => "subject",
            .line_bytes => "line-bytes",
            .carries => "carries",
            .listed => "listed",
            .unlisted => "unlisted",
            .away => "away",
            .kick => "kick",
            .governs => "governs",
            .managed_room_identity => "managedRoomIdentity",
            .called => "called",
            .private => "private",
            .room_policy => "roomPolicy",
            .room_policy_changed => "roomPolicyChanged",
            .membership_kind => "membershipKind",
            .mint_invitation => "mintInvitation",
            .claim_invitation => "claimInvitation",
            .set_subject => "setSubject",
            .register => "register",
            .voucher => "voucher",
            .introduce => "introduce",
            .offer_inbox => "offerInbox",
            .offer_signaling => "offerSignaling",
            .signal_offer => "signalOffer",
            .signal_check => "signalCheck",
            .signal_answer => "signalAnswer",
            .signal_candidate => "signalCandidate",
            .signal_done => "signalDone",
            .signal_decline => "signalDecline",
            .sig_offer => "offer",
            .sig_accepted => "accepted",
            .sig_answer => "answer",
            .sig_candidate => "candidate",
            .sig_reject => "reject",
            .attach => "attach",
            .post_files => "postFiles",
            .write => "write",
            .discard => "discard",
            .read => "read",
            .dm => "dm",
            .direct_ready => "directReady",
            .direct_requested => "directRequested",
            .request_direct => "requestDirect",
            .member_registration => "memberRegistration",
            .notify => "notify",
            .membership_ended => "membershipEnded",
            .room_authority_changed => "roomAuthorityChanged",
            .opened => "opened",
            .closed => "closed",
            .count => "count",
            .registered => "registered",
            .unregistered => "unregistered",
            .truncated => "truncated",
            .roster => "roster",
            .join => "join",
            .offline => "offline",
            .seat => "seat",
        };
    }
};

/// A method a client sends, and whether the partner answers it. A verb that
/// answers is sent and awaited. One that does not is told.
pub const Verb = struct {
    name: []const u8,
    replies: bool,
    on: Target,

    pub const Target = enum { directory, room, membership, inbox };
};

/// The name the server publishes the directory under.
pub const directory_name = Token.directory.wire();

/// The sender of every line the room itself says.
pub const room_sender = Token.room_sender.wire();

/// How long a one-shot client waits for its whole roster, in milliseconds.
pub const session_deadline_ms: u32 = 15_000;

pub const verbs = [_]Verb{
    .{ .name = Token.open.wire(), .replies = true, .on = .directory },
    .{ .name = Token.enter.wire(), .replies = true, .on = .directory },
    .{ .name = Token.list_publications.wire(), .replies = true, .on = .directory },
    .{ .name = Token.named_publications.wire(), .replies = true, .on = .directory },
    .{ .name = Token.watch_publications.wire(), .replies = true, .on = .directory },
    .{ .name = Token.unwatch_publications.wire(), .replies = true, .on = .directory },
    .{ .name = Token.register.wire(), .replies = true, .on = .directory },
    .{ .name = Token.introduce.wire(), .replies = true, .on = .directory },
    .{ .name = Token.member_registration.wire(), .replies = true, .on = .directory },
    .{ .name = Token.subscribe.wire(), .replies = true, .on = .room },
    .{ .name = Token.post.wire(), .replies = true, .on = .membership },
    .{ .name = Token.leave.wire(), .replies = true, .on = .membership },
    .{ .name = Token.typing.wire(), .replies = false, .on = .membership },
    .{ .name = Token.away.wire(), .replies = true, .on = .membership },
    .{ .name = Token.notify.wire(), .replies = false, .on = .inbox },
    .{ .name = Token.dm.wire(), .replies = true, .on = .inbox },
};

/// The tag on the room's last word to an inbox: the text is the reason.
pub const membership_ended = Token.membership_ended.wire();

const name_field = Field{ .name = "name", .ty = .text };

const publication_fields = [_]Field{
    .{ .name = "name", .ty = .text },
    .{ .name = "count", .ty = .natural, .nullable = true },
    .{ .name = "id", .ty = .text },
    .{ .name = "kind", .ty = .text, .values = .publication_kinds },
    .{ .name = "origin", .ty = .string },
    .{ .name = "proof", .ty = .text, .values = .publication_proofs },
    .{ .name = "offers", .ty = .text, .nullable = true, .values = .membership_kinds },
};

const registration_event_fields = [_]Field{
    .{ .name = "name", .ty = .text },
    .{ .name = "count", .ty = .natural },
    .{ .name = "registrationId", .ty = .registration_id },
};

const truncated_fields = [_]Field{.{ .name = "omitted", .ty = .natural }};

const list_page_fields = [_]Field{
    .{ .name = "rooms", .ty = .list },
    .{ .name = "next", .ty = .text, .nullable = true },
};

const watch_snapshot_fields = [_]Field{
    .{ .name = "rooms", .ty = .list },
    .{ .name = "registrations", .ty = .list },
    .{ .name = "omitted", .ty = .natural },
};

const registration_row_fields = [_]Field{
    .{ .name = "name", .ty = .text },
    .{ .name = "registrationId", .ty = .registration_id },
};

const subscribe_answer_fields = [_]Field{
    .{ .name = "seat", .ty = .reference },
    .{ .name = "kind", .ty = .text, .values = .membership_kinds },
    .{ .name = "subject", .ty = .reference, .nullable = true },
    .{ .name = "files", .ty = .reference, .nullable = true },
};

const line_trailing = [_]Field{.{ .name = "id", .ty = .natural }};
const named_trailing = [_]Field{name_field};
const typing_trailing = [_]Field{ name_field, .{ .name = "on", .ty = .boolean } };
const away_trailing = [_]Field{ name_field, .{ .name = "reason", .ty = .string } };
const seat_trailing = [_]Field{
    name_field,
    .{ .name = "state", .ty = .text, .values = .seat_phases },
    .{ .name = "nick", .ty = .text },
    .{ .name = "network", .ty = .text },
    .{ .name = "badge", .ty = .text },
    .{ .name = "said", .ty = .text },
};

/// Every named field list, in the order each language's module declares them.
pub const Fields = enum {
    publication,
    registration_event,
    truncated,
    list_page,
    watch_snapshot,
    registration_row,
    subscribe_answer,
    line_trailing,
    named_trailing,
    typing_trailing,
    away_trailing,
    seat_trailing,

    pub fn fields(self: Fields) []const Field {
        return switch (self) {
            .publication => &publication_fields,
            .registration_event => &registration_event_fields,
            .truncated => &truncated_fields,
            .list_page => &list_page_fields,
            .watch_snapshot => &watch_snapshot_fields,
            .registration_row => &registration_row_fields,
            .subscribe_answer => &subscribe_answer_fields,
            .line_trailing => &line_trailing,
            .named_trailing => &named_trailing,
            .typing_trailing => &typing_trailing,
            .away_trailing => &away_trailing,
            .seat_trailing => &seat_trailing,
        };
    }

    /// The upper-case stem each language names the list by.
    pub fn stem(self: Fields) []const u8 {
        return switch (self) {
            .publication => "PUBLICATION_FIELDS",
            .registration_event => "REGISTRATION_EVENT_FIELDS",
            .truncated => "TRUNCATED_FIELDS",
            .list_page => "LIST_PAGE_FIELDS",
            .watch_snapshot => "WATCH_SNAPSHOT_FIELDS",
            .registration_row => "REGISTRATION_ROW_FIELDS",
            .subscribe_answer => "SUBSCRIBE_ANSWER_FIELDS",
            .line_trailing => "LINE_TRAILING",
            .named_trailing => "NAMED_TRAILING",
            .typing_trailing => "TYPING_TRAILING",
            .away_trailing => "AWAY_TRAILING",
            .seat_trailing => "SEAT_TRAILING",
        };
    }

    /// One sentence each language's module says over the list.
    pub fn doc(self: Fields) []const u8 {
        return switch (self) {
            .publication => "One directory publication: a listPublications row, and what a room watch kind carries after its tag.",
            .registration_event => "What a member watch kind carries after its tag.",
            .truncated => "What the truncation watch kind carries after its tag.",
            .list_page => "What listPublications answers: one page of publication rows, and the cursor that asks for the page after it, null on the last page. The cursor is the directory's own word: pass it back exactly.",
            .watch_snapshot => "What watchPublications answers: the baseline a watcher folds deltas into.",
            .registration_row => "One row of the snapshot's registrations.",
            .subscribe_answer => "What subscribe answers.",
            .line_trailing => "After the line tag: the line's id, then the file records apps/rooms/lib/attachment.ts reads.",
            .named_trailing => "After a join or leave tag: the member.",
            .typing_trailing => "After the typing tag: the member and whether they are typing.",
            .away_trailing => "After the away tag: the member and the reason, empty when they are back.",
            .seat_trailing => "After the bridge's seat tag, specified in apps/rooms/lib/protocol_irc.ts.",
        };
    }
};

/// One directory watch notification: `notify(tag, ...args)`.
pub const WatchKind = struct {
    tag: []const u8,
    args: Fields,

    /// Whether the arguments are one whole publication record.
    pub fn room(self: WatchKind) bool {
        return self.args == .publication;
    }
};

pub const watch_kinds = [_]WatchKind{
    .{ .tag = Token.opened.wire(), .args = .publication },
    .{ .tag = Token.closed.wire(), .args = .publication },
    .{ .tag = Token.count.wire(), .args = .publication },
    .{ .tag = Token.registered.wire(), .args = .registration_event },
    .{ .tag = Token.unregistered.wire(), .args = .registration_event },
    .{ .tag = Token.truncated.wire(), .args = .truncated },
};

/// What a presence tail does to the member it names.
pub const Effect = enum { arrive, depart, stay };

/// Who says a line carrying a tail.
pub const Sender = enum { room, member, either };

/// What the display text of a line carrying a tail may be.
pub const TextRule = enum { any, empty, nonempty };

/// What rides after a room line's display text: `notify(from, text, tag, ...)`.
pub const RoomTail = struct {
    tag: []const u8,
    /// The arguments after the tag, or null when the tag stands alone.
    trailing: ?Fields = null,
    /// The type of every argument after `trailing`, or null when nothing may follow.
    rest: ?Ty = null,
    sender: Sender,
    text: TextRule,
    /// Set on a presence tail, null on a tail that says nothing about membership.
    effect: ?Effect = null,
};

/// The `seat` presence is the bridge's, specified in
/// `apps/rooms/lib/protocol_irc.ts`. Every other tail is
/// `apps/rooms/lib/protocol.ts`'s.
pub const room_tails = [_]RoomTail{
    .{ .tag = Token.line.wire(), .trailing = .line_trailing, .rest = .any, .sender = .either, .text = .any },
    .{ .tag = Token.roster.wire(), .rest = .text, .sender = .room, .text = .any, .effect = .arrive },
    .{ .tag = Token.join.wire(), .trailing = .named_trailing, .sender = .room, .text = .any, .effect = .arrive },
    .{ .tag = Token.leave.wire(), .trailing = .named_trailing, .sender = .room, .text = .any, .effect = .depart },
    .{ .tag = Token.offline.wire(), .rest = .text, .sender = .room, .text = .any, .effect = .depart },
    .{ .tag = Token.typing.wire(), .trailing = .typing_trailing, .sender = .room, .text = .empty, .effect = .stay },
    .{ .tag = Token.away.wire(), .trailing = .away_trailing, .sender = .room, .text = .any, .effect = .stay },
    .{ .tag = Token.seat.wire(), .trailing = .seat_trailing, .sender = .room, .text = .any, .effect = .stay },
    .{ .tag = membership_ended, .sender = .room, .text = .nonempty },
};

/// The text form of a directory-issued registration id: RFC 4122 text, any
/// case, with the version nibble and the variant nibble the server mints.
pub const registration_id = struct {
    pub const length: usize = 36;
    pub const dashes = [_]usize{ 8, 13, 18, 23 };
    pub const version_at: usize = 14;
    pub const versions = "12345678";
    pub const variant_at: usize = 19;
    pub const variants = "89ab";

    fn isDash(at: usize) bool {
        return std.mem.indexOfScalar(usize, &dashes, at) != null;
    }

    fn isHex(at: usize) bool {
        return !isDash(at) and at != version_at and at != variant_at;
    }

    /// The same form as one regular expression over lowercase hex. The reader
    /// applies its language's case-insensitive flag.
    pub fn writePattern(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.append(gpa, '^');
        var at: usize = 0;
        while (at < length) {
            if (isDash(at)) {
                try out.append(gpa, '-');
                at += 1;
            } else if (at == version_at) {
                try out.print(gpa, "[{s}]", .{versions});
                at += 1;
            } else if (at == variant_at) {
                try out.print(gpa, "[{s}]", .{variants});
                at += 1;
            } else {
                var run: usize = 0;
                while (at + run < length and isHex(at + run)) run += 1;
                try out.print(gpa, "[0-9a-f]{{{d}}}", .{run});
                at += run;
            }
        }
        try out.append(gpa, '$');
    }
};

/// The common header every generated module opens with, behind that
/// language's line-comment prefix.
pub fn writeHeader(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comment: []const u8) !void {
    try out.print(gpa, "{s} GENERATED by `zig build {s}` from {s}.\n", .{ comment, step_name, source });
    try out.print(gpa, "{s} Do not edit. `zig build {s}-check` keeps this fresh.\n", .{ comment, step_name });
    try out.print(gpa, "{s}\n", .{comment});
    try out.print(gpa, "{s} The Rooms wire grammar the application and terminal clients read. The human specification\n", .{comment});
    try out.print(gpa, "{s} is {s}.\n", .{ comment, human_spec });
}

/// `listPublications` as `LIST_PUBLICATIONS`, or `LIST-PUBLICATIONS` with `sep` `'-'`.
pub fn writeUpper(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, sep: u8) !void {
    for (name) |ch| {
        if (std.ascii.isUpper(ch)) try out.append(gpa, sep);
        try out.append(gpa, std.ascii.toUpper(ch));
    }
}

/// `listPublications` as `list_publications`, and `LIST_PUBLICATIONS` too.
pub fn writeSnake(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) !void {
    for (name, 0..) |ch, i| {
        if (std.ascii.isUpper(ch) and i > 0 and std.ascii.isLower(name[i - 1])) try out.append(gpa, '_');
        try out.append(gpa, std.ascii.toLower(ch));
    }
}

/// `LIST_PUBLICATIONS` as `LIST-PUBLICATIONS`.
pub fn writeKebab(out: *std.ArrayList(u8), gpa: std.mem.Allocator, stem: []const u8) !void {
    for (stem) |ch| try out.append(gpa, if (ch == '_') '-' else ch);
}

/// The verbs on one target, for the tables that list a target's verbs.
pub fn verbsOn(comptime target: Verb.Target) []const Verb {
    // A container constant, one per target, so the slice returned outlives
    // this call. A `comptime` block's local would not.
    return &struct {
        const picked = blk: {
            var count: usize = 0;
            for (verbs) |verb| {
                if (verb.on == target) count += 1;
            }
            var out: [count]Verb = undefined;
            var i: usize = 0;
            for (verbs) |verb| {
                if (verb.on == target) {
                    out[i] = verb;
                    i += 1;
                }
            }
            break :blk out;
        };
    }.picked;
}

test "the registration id form composes into the pattern every reader held" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try registration_id.writePattern(&out, std.testing.allocator);
    try std.testing.expectEqualStrings(
        "^[0-9a-f]{8}-[0-9a-f]{4}-[12345678][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        out.items,
    );
}

test "the naming helpers split camel humps and keep upper stems whole" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try writeUpper(&out, std.testing.allocator, "listPublications", '_');
    try std.testing.expectEqualStrings("LIST_PUBLICATIONS", out.items);
    out.clearRetainingCapacity();
    try writeSnake(&out, std.testing.allocator, "membershipEnded");
    try std.testing.expectEqualStrings("membership_ended", out.items);
    out.clearRetainingCapacity();
    try writeSnake(&out, std.testing.allocator, "LINE_TRAILING");
    try std.testing.expectEqualStrings("line_trailing", out.items);
}
