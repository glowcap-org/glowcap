//! The text constants every binding mirrors. Bindings match these bytes, so
//! each value comes from the declaration that produces it, and every binding
//! generator reads this one table.

const cd = @import("c_abi_host");
const model = @import("model");

pub const Text = struct { stem: []const u8, value: []const u8, doc: []const u8 };

pub const texts = [_]Text{
    .{
        .stem = "HINT_DIRECT_ADDRESSES",
        .value = model.transport.hint_direct_addresses,
        .doc = "Locator hint name carrying dial addresses for a transport whose designator is a key.",
    },
    .{
        .stem = "HINT_ALT_LOCATORS",
        .value = model.transport.hint_alt_locators,
        .doc = "Locator hint name carrying a pipe-separated list of complete peer URIs to try after this locator. The value is routing advice, and the exporter's locator stays the signed authority for a redeem.",
    },
    .{
        .stem = "HINT_VIA",
        .value = model.transport.hint_via,
        .doc = "Locator hint name carrying the `id` transport's route bundle.",
    },
    .{
        .stem = "UNKNOWN_SWISSNUM_MESSAGE",
        .value = cd.GLOWCAP_UNKNOWN_SWISSNUM_MESSAGE,
        .doc = "Exact partner fetch-refusal text for an unknown publication; use the generated publication-not-found predicate.",
    },
};
