//! Shared C-ABI argument and reference constructors for the `test/c_abi`
//! suite. Every field of the blank argument is named, so the shared-by-layout
//! `PancakeArgument` growing a field fails these tests at compile time instead
//! of zero-filling silently. The blank is a deliberate VOID argument: the
//! all-zeroes value would read as a valid integer argument, because
//! `PANCAKE_ARG_INTEGER` is zero.

const c = @import("c_abi");

pub fn zeroRef() c.PancakeReference {
    return .{ .id = 0 };
}

pub fn argBase() c.PancakeArgument {
    return .{
        .kind = c.PANCAKE_ARG_VOID,
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

pub fn argInt(value: i64) c.PancakeArgument {
    var arg = argBase();
    arg.kind = c.PANCAKE_ARG_INTEGER;
    arg.integer = value;
    return arg;
}

pub fn argStr(text: []const u8) c.PancakeArgument {
    var arg = argBase();
    arg.kind = c.PANCAKE_ARG_STRING;
    arg.bytes = text.ptr;
    arg.bytes_len = text.len;
    return arg;
}

pub fn argBytes(bytes: []const u8) c.PancakeArgument {
    var arg = argBase();
    arg.kind = c.PANCAKE_ARG_BYTES;
    arg.bytes = bytes.ptr;
    arg.bytes_len = bytes.len;
    return arg;
}

pub fn argRef(reference: c.PancakeReference) c.PancakeArgument {
    var arg = argBase();
    arg.kind = c.PANCAKE_ARG_REFERENCE;
    arg.reference = reference;
    return arg;
}
