//! Allocation-free validation of model values before Cap'n Proto encoding.
//!
//! Keeping this walk ahead of builder admission makes malformed outbound text
//! a deterministic protocol refusal instead of an allocation-dependent partial
//! encode. The encoder owns representation; this leaf owns only admissibility.

const std = @import("std");

const model = @import("model");
const Error = @import("shared.zig").Error;

fn validateUtf8(text: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return Error.UnsupportedArgument;
}

pub fn validateMessageUtf8(message: model.Message) Error!void {
    switch (message) {
        .deliver => |deliver| {
            try validateReferenceUtf8(deliver.target);
            try validateArgumentsUtf8(deliver.args);
            if (deliver.resolve_me_desc) |reference| try validateReferenceUtf8(reference);
        },
        .resolve => |resolve| try validateResolutionUtf8(resolve.resolution),
        .start_session => |start_session| try validateLocatorUtf8(start_session.acceptable_location),
        .abort => |abort| try validateUtf8(abort.message),
        .listen => |listen| {
            try validateReferenceUtf8(listen.target);
            try validateReferenceUtf8(listen.listener);
        },
        .get => |get| {
            try validateReferenceUtf8(get.receiver);
            try validateUtf8(get.field);
        },
        .index => |index| {
            try validateReferenceUtf8(index.receiver);
            if (index.index == .big_integer and !index.index.big_integer.isCanonical()) {
                return Error.UnsupportedArgument;
            }
        },
        .untag => |untag| {
            try validateReferenceUtf8(untag.receiver);
            try validateUtf8(untag.tag);
        },
        .gc_export, .gc_answer => {},
    }
}

fn validateResolutionUtf8(resolution: model.Resolution) Error!void {
    switch (resolution) {
        .fulfill => |argument| try validateArgumentUtf8(argument),
        .@"break" => |reason| try validateUtf8(reason.message),
    }
}

fn validateReferenceUtf8(reference: model.Reference) Error!void {
    switch (reference) {
        .promise => {},
        .sturdy => |sturdy| try validateLocatorUtf8(sturdy.peer),
        .broken => |reason| try validateUtf8(reason.message),
        .near, .far => {},
        .routed => return Error.UnsupportedReference,
    }
}

fn validateLocatorUtf8(locator: model.PeerLocator) Error!void {
    try validateUtf8(locator.transport);
    try validateUtf8(locator.designator);
    for (locator.hints.entries) |entry| {
        try validateUtf8(entry.name);
        if (entry.value == .string) try validateUtf8(entry.value.string);
    }
}

fn validateArgumentsUtf8(arguments: []const model.Argument) Error!void {
    for (arguments) |argument| try validateArgumentUtf8(argument);
}

fn validateArgumentUtf8(argument: model.Argument) Error!void {
    switch (argument) {
        .symbol, .string, .keyword => |text| try validateUtf8(text),
        .reference => |reference| try validateReferenceUtf8(reference),
        .@"error" => |reason| try validateUtf8(reason.message),
        .handoff => |handoff| switch (handoff.*) {
            .give => |give| try validateLocatorUtf8(give.exporter),
            .receive => |receive| try validateLocatorUtf8(receive.signed_give.exporter),
        },
        .list, .set => |items| try validateArgumentsUtf8(items),
        .tagged => |tagged| {
            try validateUtf8(tagged.tag);
            try validateArgumentsUtf8(tagged.value);
        },
        .@"struct" => |entries| for (entries) |entry| {
            try validateUtf8(entry.key);
            try validateArgumentUtf8(entry.value);
        },
        .bytes, .integer, .boolean, .void, .float64, .big_integer => {},
    }
}
