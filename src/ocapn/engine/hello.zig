//! The keyed `op:start-session` hello, the Peer-owned half (ADR-0006,
//! ADR-0118): assembling the hint entries a hello carries, canonicalizing the
//! advertised locator per transport, signing the location record, and the two
//! partner-knowledge seams that decide whether an onion hello may state a
//! real preference. `Peer` aliases each public verb as a method, the same
//! shape `session/handshake.zig` gives the session its handshake verbs.

const std = @import("std");

const codec = @import("codec");
const foundation = @import("foundation");
const model = @import("model");
const session = @import("session");

const engine = @import("mod.zig");
const negotiation = @import("negotiation.zig");
const Peer = engine.Peer;

/// Queue a keyed `op:start-session` advertising `locator`. The canonical
/// signing input for `<my-location …>` is profile-defined and lives in the
/// codec, so this is the one place that builds it: it assembles the hints
/// the hello carries, signs the canonical bytes with `session_secret`, then
/// enqueues a `start_session` carrying the session public key, the
/// locator, and the signature. A negotiating peer drives this to an open
/// session once the partner's own start-session arrives. The signed
/// locator is what the partner verifies, so `locator` must be the one the
/// partner expects (for a Goblins partner, a `tcp` transport with
/// `#f`-encoded empty hints). Borrowed inputs are cloned into the outbound
/// queue, exactly as `sendCopying` documents.
pub fn sendKeyedStartSession(
    self: *Peer,
    locator: model.PeerLocator,
    session_secret: foundation.crypto.SecretKey,
) !void {
    var hint_storage: HelloHints = .{};
    defer hint_storage.deinit(self.allocator);
    const advertised = try self.advertisedLocator(locator, &hint_storage);
    return self.sendKeyedStartSessionExact(advertised, session_secret);
}

/// Queue this session's keyed hello over the node-selected advertised
/// locator. Advertised locators complete their profile at configuration
/// time on every transport but onion, whose stored snapshot stays bare
/// because completion cannot know a partner and a bare locator is the
/// only onion form other parties may be handed (ADR-0108). The one
/// session that may state a real onion preference — a partner known to
/// be pancake (ADR-0118) — therefore stamps here, at session time;
/// everything else sends the completed snapshot exactly.
pub fn sendKeyedStartSessionAdvertised(
    self: *Peer,
    advertised: model.PeerLocator,
    session_secret: foundation.crypto.SecretKey,
) !void {
    if (self.session_state.partner_known_pancake and
        std.mem.eql(u8, advertised.transport, model.transport.onion))
        return self.sendKeyedStartSession(advertised, session_secret);
    return self.sendKeyedStartSessionExact(advertised, session_secret);
}

/// Queue a keyed `op:start-session` for an already-complete advertised
/// locator. The caller owns profile materialization. Transport wire rules
/// are still canonicalized here: onion's interoperable spelling has `#f`
/// hints, so no entry point can sign an onion location the pinned Goblins
/// cannot dial. The one exception is a partner already known to be
/// pancake, whose hello may keep the profile hints this peer stamped
/// (ADR-0118); routing hints stay stripped even then.
pub fn sendKeyedStartSessionExact(
    self: *Peer,
    advertised: model.PeerLocator,
    session_secret: foundation.crypto.SecretKey,
) !void {
    if (!codec.registry.contains(self.session_state.preferred.codec))
        return error.UnknownCodec;
    const canonical = canonicalAdvertisedLocator(advertised, self.session_state.partner_known_pancake);
    try validateExactAdvertisedProfile(
        canonical,
        advertisedPreference(canonical.transport, self.session_state.preferred, self.session_state.partner_known_pancake),
    );
    const session_pubkey = session_secret.publicKey();
    const signed = try codec.signed.locationBytes(self.allocator, canonical);
    defer self.allocator.free(signed);
    const sig = foundation.crypto.sign(&session_secret, signed);
    try self.sendCopying(.{
        .start_session = .{
            // Always the baseline, never `version`: see `validateStartSession`.
            // The caller's preference is in the hints this peer just stamped.
            .captp_version = model.Preference.baseline.captp_version,
            .session_pubkey = .{ .bytes = session_pubkey.asBytes() },
            .acceptable_location = canonical,
            .acceptable_location_sig = .{ .bytes = sig.asBytes() },
        },
    });
}

/// Whether the locator a dialer was handed identifies its acceptor as
/// pancake (ADR-0118): the hinted form of an onion address carries the
/// `pancake/*` profile hints out of band. Wire-carried locators are bare on
/// onion, so a redeem or handoff dial never passes this test. Every dial
/// tier reads it so the handed form means the same thing everywhere.
pub fn dialedLocatorIdentifiesPancake(locator: model.PeerLocator) bool {
    if (!std.mem.eql(u8, locator.transport, model.transport.onion)) return false;
    for (locator.hints.entries) |entry| {
        if (model.transport.isProfileHintName(entry.name)) return true;
    }
    return false;
}

/// Record out-of-band knowledge that this partner is pancake, before any
/// hello: the dialer was handed the pancake-hinted form of an onion
/// address (ADR-0118). On every other transport the flag changes nothing,
/// because the configured preference is advertised regardless.
pub fn noteKnownPancakePartner(self: *Peer) void {
    self.session_state.partner_known_pancake = true;
}

/// Answer a deferred onion hello (ADR-0118): read the inbound hello's
/// stated preference, and when it differs from the baseline — proof the
/// initiator is pancake, because the pinned Goblins onion netlayer signs
/// only `#f`-hinted locations — record the knowledge before stamping our
/// own hello, so `advertisedLocator`'s onion arm states the configured
/// preference. A bare inbound hello gets today's bare answer. Unreadable
/// hints send nothing: validation refuses the same message immediately
/// after this runs, and the session aborts before a partner could wait on
/// the answer.
pub fn answerDeferredHello(
    self: *Peer,
    ss: model.view.StartSession,
    advertised: model.PeerLocator,
    session_secret: foundation.crypto.SecretKey,
) !void {
    const stated = session.parsePreferenceHints(ss.acceptable_location.hints) catch return;
    if (!std.meta.eql(stated, model.Preference.baseline)) self.session_state.partner_known_pancake = true;
    return self.sendKeyedStartSessionAdvertised(advertised, session_secret);
}

fn validateExactAdvertisedProfile(
    advertised: model.PeerLocator,
    expected: model.Preference,
) session.Error!void {
    // A named repeat of the one preference parse: the stamp above and
    // `validateSend` each read the hints again. Session-open only, zero
    // allocation; folding the three reads would thread parse state through
    // the send path for a cost the wire never sees.
    const actual = try session.parsePreferenceHints(advertised.hints);
    if (!std.meta.eql(actual, expected)) return session.Error.MalformedMessage;
}

/// This peer's hello locator: the caller's plus the preference hints this
/// peer stamps when the transport admits them. Onion stays hintless and
/// advertises the baseline profile (ADR-0108) unless this partner is
/// already known to be pancake, the one licence to state a real
/// preference there (ADR-0118).
///
/// Every hello passes through here, and it has to be *before* the caller
/// signs, because the hints are inside the signed location record. That is
/// the whole reason this is a shared verb rather than something each
/// assembler does: there are several of them, and a hello that forgets is
/// read by its partner as "this peer wants the baseline", a downgrade
/// nobody reports.
pub fn advertisedLocator(
    self: *const Peer,
    locator: model.PeerLocator,
    storage: *HelloHints,
) HelloHints.Error!model.PeerLocator {
    return storage.extend(
        self.allocator,
        locator,
        self.session_state.preferred,
        self.session_state.partner_known_pancake,
    );
}

/// Scratch for the hint entries a hello adds to its caller's locator.
/// The returned locator borrows this storage until `sendCopying` clones it;
/// callers initialize with `.{}` and call `deinit` afterward.
pub const HelloHints = struct {
    inline_entries: [inline_hint_entries]model.HintEntry = undefined,
    allocated_entries: ?[]model.HintEntry = null,
    codec_digits: [8]u8 = undefined,
    feature_bytes: [model.FeatureSet.wire_string_max_len]u8 = undefined,

    pub fn deinit(self: *HelloHints, allocator: std.mem.Allocator) void {
        if (self.allocated_entries) |entries| allocator.free(entries);
        self.* = .{};
    }

    /// A locator's own hints plus this peer's transport-admissible
    /// preference. A peer that prefers the baseline, or any peer
    /// advertising onion, adds nothing and signs the byte-identical bare
    /// locator.
    pub const Error = error{
        /// The caller's hint count cannot be extended without overflowing
        /// the address space.
        TooManyHints,
        /// The caller supplied a hint this peer stamps itself.
        ReservedHintName,
        /// Hints are a dictionary; signing duplicates produces a hello a
        /// conforming receiver must reject.
        DuplicateHintName,
        /// The peer preference names an open wire id with no implementation
        /// in this build; advertising it would promise a codec we cannot use.
        UnknownCodec,
    } || std.mem.Allocator.Error;

    pub fn extend(
        self: *HelloHints,
        allocator: std.mem.Allocator,
        supplied: model.PeerLocator,
        preference: model.Preference,
        partner_known_pancake: bool,
    ) Error!model.PeerLocator {
        std.debug.assert(self.allocated_entries == null);
        if (!codec.registry.contains(preference.codec)) return Error.UnknownCodec;
        const locator = canonicalAdvertisedLocator(supplied, partner_known_pancake);
        const carried = locator.hints.entries;
        // Every silent path out of here is a downgrade: a partner reads a
        // missing hint as "this peer wants the baseline" and is right to,
        // so quietly dropping the preference weakens the session with
        // nothing reported anywhere. So the refusals below are returned
        // rather than asserted. The list is caller-supplied and this verb
        // is reachable from outside the engine, through
        // `driver.BlockingSession.startKeyedSessionWithSecret`, so an
        // assertion would hold only in a safe build: `perf-check` and
        // `release-pack` compile it out. The overflow and allocation paths
        // are reported, as is a second profile claim in one hello.
        if (model.firstDuplicateHintName(carried) != null) return Error.DuplicateHintName;
        for (carried) |entry| {
            // A caller that supplied the profile itself keeps its encoding:
            // replacing it would change the bytes the partner verifies the
            // signature over. No caller in this tree does, and this refuses
            // rather than letting a future one downgrade in silence.
            for ([_][]const u8{
                model.transport.hint_captp_version,
                model.transport.hint_codec,
                model.transport.hint_features,
            }) |reserved| {
                if (std.mem.eql(u8, entry.name, reserved)) return Error.ReservedHintName;
            }
        }
        // Onion's standardized locator is deliberately hintless: the
        // Goblins dialer accepts only the `#f`-hints shape, so an onion
        // hello states the baseline (ADR-0108) unless the partner is
        // already known to be pancake, when it states the configured
        // preference like any other transport's (ADR-0118). Every other
        // transport always advertises the configured preference.
        const effective = advertisedPreference(locator.transport, preference, partner_known_pancake);
        // Only a preference that differs from the baseline is worth
        // stating. `model.Preference.baseline` rather than literals, so
        // changing the baseline is one edit.
        const baseline = model.Preference.baseline;
        const stamped_count = @as(usize, @intFromBool(effective.captp_version != baseline.captp_version)) +
            @as(usize, @intFromBool(effective.codec != baseline.codec)) +
            @as(usize, @intFromBool(!std.meta.eql(effective.features, baseline.features)));
        if (stamped_count == 0) return locator;
        const count = std.math.add(usize, carried.len, stamped_count) catch
            return Error.TooManyHints;
        const entries = if (count <= self.inline_entries.len)
            self.inline_entries[0..count]
        else blk: {
            const allocated = try allocator.alloc(model.HintEntry, count);
            self.allocated_entries = allocated;
            break :blk allocated;
        };
        @memcpy(entries[0..carried.len], carried);
        var write = carried.len;
        if (effective.captp_version != baseline.captp_version) {
            entries[write] = .{
                .name = model.transport.hint_captp_version,
                .value = .{ .string = effective.captp_version.wireString() },
            };
            write += 1;
        }
        if (effective.codec != baseline.codec) {
            // A `u16` in decimal fits five digits; the buffer holds eight.
            const digits = std.fmt.bufPrint(&self.codec_digits, "{d}", .{@intFromEnum(effective.codec)}) catch unreachable;
            entries[write] = .{ .name = model.transport.hint_codec, .value = .{ .string = digits } };
            write += 1;
        }
        if (!std.meta.eql(effective.features, baseline.features)) {
            const text = effective.features.toWireString(&self.feature_bytes) catch unreachable;
            entries[write] = .{ .name = model.transport.hint_features, .value = .{ .string = text } };
            write += 1;
        }
        std.debug.assert(write == count);
        return .{
            .transport = locator.transport,
            .designator = locator.designator,
            .hints = .{ .entries = entries },
        };
    }
};

fn advertisedPreference(
    transport: []const u8,
    configured: model.Preference,
    partner_known_pancake: bool,
) model.Preference {
    if (std.mem.eql(u8, transport, model.transport.onion) and !partner_known_pancake)
        return model.Preference.baseline;
    return configured;
}

fn canonicalAdvertisedLocator(locator: model.PeerLocator, keep_profile_hints: bool) model.PeerLocator {
    if (!std.mem.eql(u8, locator.transport, model.transport.onion)) return locator;
    // A partner known to be pancake reads profile hints like any other
    // transport's (ADR-0118); everyone else gets onion's one interoperable
    // spelling, `#f` hints, so nothing this peer signs is undialable by
    // the pinned Goblins (ADR-0108). Routing hints stay stripped in both
    // cases: only the profile entries this peer stamps may ride.
    if (keep_profile_hints) {
        for (locator.hints.entries) |entry| {
            if (!model.transport.isProfileHintName(entry.name)) {
                return .{
                    .transport = locator.transport,
                    .designator = locator.designator,
                    .hints = model.Hints.emptyFalse(),
                };
            }
        }
        return locator;
    }
    return .{
        .transport = locator.transport,
        .designator = locator.designator,
        .hints = model.Hints.emptyFalse(),
    };
}

/// The common locator has at most one routing hint plus the three profile
/// entries this peer may stamp. Larger OCapN hint maps spill to exact-sized
/// scratch rather than imposing a protocol limit on a stack optimization.
const inline_hint_entries = 4;

/// Settle this session's active profile from the two preferences, once the
/// partner's hello has stated its own.
///
/// The session records the claims; this decides with them, because the
/// decision is the engine's. Both peers hold the same two preferences and
/// `negotiate` is symmetric, so they reach the same pair with no further
/// round trip.
pub fn settleNegotiatedProfile(self: *Peer) void {
    const settled = negotiation.settle(
        self.session_state.preferred,
        self.session_state.partner_preference,
    );
    self.session_state.captp_version = settled.captp_version;
    self.session_state.codec = settled.codec;
    self.session_state.features = settled.features;
}
