//! Pure translation of preloaded text modules into one checked description.
//! Caller-owned sources outlive translation. Paths occur only in diagnostics.
const std = @import("std");
const description = @import("description.zig");
const syntax = @import("text_parser.zig");
const Encoder = @import("text_encode.zig").Encoder;
const Model = @import("model.zig").Model;
pub const Diagnostic = syntax.Diagnostic;
pub const Error = syntax.Error;
pub const Source = syntax.Source;
pub const max_files: usize = 64;
pub const max_import_depth: usize = 32;
pub const Module = struct { source: Source, header: syntax.Header };
/// The caller's compilation arena and input sources last through emission.
pub const Compiled = struct { bytes: []u8, model: Model };

pub const Bundle = struct {
    a: std.mem.Allocator,
    diagnostic: *Diagnostic,
    modules: std.ArrayList(Module) = .empty,
    budget: syntax.Budget = .{},
    input_bytes: usize = 0,

    fn noteOrigin(self: Bundle, origin: []const u8, message: []const u8) void {
        for (self.modules.items) |module| {
            if (self.diagnostic.setOrigin(module.source, origin, message)) return;
        }
        self.diagnostic.message = message;
    }

    /// Cache a header once. Callers bind each import to a preloaded module index.
    pub fn add(self: *Bundle, source: Source) Error!usize {
        if (self.modules.items.len == max_files or source.bytes.len > description.max_input_bytes - self.input_bytes) return error.ResourceLimit;
        if (!std.unicode.utf8ValidateSlice(source.bytes)) return error.InvalidText;
        self.input_bytes += source.bytes.len;
        var parser: syntax.Parser = .{ .a = self.a, .source = source, .diagnostic = self.diagnostic, .budget = &self.budget };
        const header = try parser.header();
        for (self.modules.items) |previous| if (std.mem.eql(u8, previous.header.name, header.name)) {
            self.diagnostic.set(source, 0, "duplicate module declaration");
            return error.InvalidText;
        };
        const index = self.modules.items.len;
        try self.modules.append(self.a, .{ .source = source, .header = header });
        return index;
    }

    pub fn translate(self: *Bundle) Error![]u8 {
        return (try self.compile()).bytes;
    }

    pub fn compile(self: *Bundle) Error!Compiled {
        var entries: std.ArrayList(syntax.Entry) = .empty;
        var receipt = false;
        const order = try self.a.alloc(usize, self.modules.items.len);
        for (order, 0..) |*index, i| index.* = i;
        std.mem.sort(usize, order, self.modules.items, struct {
            fn less(modules: []const Module, left: usize, right: usize) bool {
                return std.mem.order(u8, modules[left].source.path, modules[right].source.path) == .lt;
            }
        }.less);
        for (order) |index| {
            const module = self.modules.items[index];
            const aliases = try self.a.alloc(syntax.Alias, module.header.imports.len);
            for (module.header.imports, aliases) |import, *alias| {
                const target = import.target orelse {
                    self.diagnostic.set(module.source, import.offset, "import source was not preloaded");
                    return error.MissingImport;
                };
                if (target >= self.modules.items.len) return error.MissingImport;
                alias.* = .{ .name = import.alias, .module = self.modules.items[target].header.name };
            }
            var parser: syntax.Parser = .{ .a = self.a, .source = module.source, .diagnostic = self.diagnostic, .budget = &self.budget, .at = module.header.body, .prefix = module.header.name, .aliases = aliases };
            try parser.declarations(&entries);
            receipt = receipt or parser.receipt;
        }
        const Node = description.Node;
        var profiles: [4]Node = .{ .{ .kind = .string, .bytes = "glowcap.values" }, .{ .kind = .integer, .integer = 1 }, .{ .kind = .string, .bytes = "loam.receipt" }, .{ .kind = .integer, .integer = 1 } };
        var parser: syntax.Parser = .{ .a = self.a, .source = .{ .path = "", .bytes = "" }, .diagnostic = self.diagnostic, .budget = &self.budget };
        const definitions = try parser.dictionary(entries.items);
        const root: Node = .{ .kind = .record, .bytes = "glowcap:interface", .children = &.{ .{ .kind = .integer, .integer = 1 }, .{ .kind = .dictionary, .children = profiles[0..if (receipt) 4 else 2] }, definitions } };
        var encoder: Encoder = .{ .a = self.a };
        encoder.node(root, 0) catch |err| {
            if (err == error.InvalidText) self.noteOrigin(encoder.failed_source, "duplicate declaration, method, or bound");
            return err;
        };
        // The encoder has established duplicate-key, node, depth and output
        // limits. Validate this parser-owned graph without rereading our bytes.
        var failed: ?Node = null;
        const model = Model.initDiagnostic(self.a, root, &failed) catch |err| {
            self.noteOrigin((failed orelse root).source, "description rejected by checked model");
            return err;
        };
        return .{ .bytes = try encoder.bytes.toOwnedSlice(self.a), .model = model };
    }
};

/// A single preloaded source uses the same bundle parser and checked model.
pub fn translate(a: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error![]u8 {
    diagnostic.* = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const compiled = try compile(arena.allocator(), source, diagnostic);
    return a.dupe(u8, compiled.bytes);
}

/// Compile one source using the caller's arena. The returned Model borrows it
/// and the source bytes through method selection and emission.
pub fn compile(a: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error!Compiled {
    diagnostic.* = .{};
    var bundle: Bundle = .{ .a = a, .diagnostic = diagnostic };
    _ = try bundle.add(.{ .path = "", .bytes = source });
    return bundle.compile();
}
