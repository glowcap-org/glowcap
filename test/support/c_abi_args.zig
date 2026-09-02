//! Shared C-ABI argument and reference constructors for the `test/c_abi`
//! suite. Every field of the blank argument is named, so the shared-by-layout
//! `GlowcapArgument` growing a field fails these tests at compile time instead
//! of zero-filling silently. The blank is a deliberate VOID argument: the
//! all-zeroes value would read as a valid integer argument, because
//! `GLOWCAP_ARG_INTEGER` is zero.

const c = @import("c_abi");

pub fn zeroRef() c.GlowcapReference {
    return .{ .id = 0 };
}

pub fn argBase() c.GlowcapArgument {
    return .{
        .kind = c.GLOWCAP_ARG_VOID,
        .boolean = 0,
        .integer = 0,
        .float64 = 0,
        .bytes = null,
        .bytes_len = 0,
        .reference = zeroRef(),
        .items = null,
        .items_len = 0,
    };
}

pub fn argInt(value: i64) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_INTEGER;
    arg.integer = value;
    return arg;
}

pub fn argStr(text: []const u8) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_STRING;
    arg.bytes = text.ptr;
    arg.bytes_len = text.len;
    return arg;
}

pub fn argBytes(bytes: []const u8) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_BYTES;
    arg.bytes = bytes.ptr;
    arg.bytes_len = bytes.len;
    return arg;
}

pub fn argRef(reference: c.GlowcapReference) c.GlowcapArgument {
    var arg = argBase();
    arg.kind = c.GLOWCAP_ARG_REFERENCE;
    arg.reference = reference;
    return arg;
}
