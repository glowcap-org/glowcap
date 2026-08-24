//! Negotiated locator-vocabulary gates.
//!
//! Codecs parse locator bytes and the model names hint vocabulary, but session
//! negotiation decides whether a peer may use experimental route vocabulary on
//! this link.

const std = @import("std");

const model = @import("model");
const session = @import("../mod.zig");

const Session = session.Session;
const Error = session.Error;

pub fn validateHintShape(hints: anytype) Error!void {
    if (comptime @hasDecl(@TypeOf(hints), "validateShape")) {
        hints.validateShape() catch return Error.MalformedMessage;
        return;
    }
    model.validateHints(hints) catch return Error.MalformedMessage;
}

pub fn validateLocatorShape(locator: anytype) Error!void {
    model.validateLocatorTransportDesignator(locator.transport, locator.designator) catch
        return Error.MalformedMessage;
    try validateHintShape(locator.hints);
}

pub fn carriesRouteVocabulary(locator: anytype) Error!bool {
    return std.mem.eql(u8, locator.transport, model.transport.id);
}

fn acceptsRouteVocabulary(preference: model.Preference) bool {
    return preference.captp_version == .next and preference.features.multi_location;
}

pub fn validateStartSession(
    self: *const Session,
    local: model.Preference,
    remote: model.Preference,
    acceptable_location: anytype,
) !void {
    if (try carriesRouteVocabulary(acceptable_location) and
        (!acceptsRouteVocabulary(local) or !acceptsRouteVocabulary(remote)))
        return Error.MalformedMessage;
    try validateIdLocator(self, acceptable_location);
}

pub fn requireNegotiated(self: *const Session, locator: anytype) Error!void {
    try requireNegotiatedVocabulary(self, locator);
    try validateIdLocator(self, locator);
}

fn requireNegotiatedVocabulary(self: *const Session, locator: anytype) Error!void {
    try validateLocatorShape(locator);
    if (try carriesRouteVocabulary(locator) and
        (self.captp_version != .next or !self.features.multi_location))
        return Error.FeatureNotNegotiated;
}

pub fn parseNegotiatedIdLocator(
    self: *const Session,
    allocator: std.mem.Allocator,
    locator: model.PeerLocator,
) (std.mem.Allocator.Error || Error)!model.RouteBundle {
    try requireNegotiatedVocabulary(self, locator);
    return session.id_route.parseLocator(allocator, locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableId, error.UnsupportedId => return Error.MalformedMessage,
    };
}

fn validateIdLocator(self: *const Session, locator: anytype) Error!void {
    _ = self;
    if (!std.mem.eql(u8, locator.transport, model.transport.id)) return;
    _ = session.id_route.validateLocator(locator) catch return Error.MalformedMessage;
}
