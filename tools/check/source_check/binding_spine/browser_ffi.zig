//! Browser/native selection for the TypeScript FFI path resolver.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const expectFileContains = util.expectFileContains;

/// Browser symbol tables share the runtime-neutral FFI surface but must never
/// import the native archive/download cascade. The compile-time subpath mapping
/// is the boundary: native Deno/Bun programs resolve `@glowcap/runtime/ffi` to
/// `runtime/ffi.ts`, while browser builds resolve it to `web/browser_ffi.ts`.
/// Holding both the generated import and every complete browser mapping prevents a
/// relative `./load.ts` import from quietly bringing Node built-ins back into
/// a browser bundle where a tolerant bundler would merely externalize them.
/// Deno config inheritance does not merge import maps, so an application map
/// mirrors the binding-owned entries explicitly; the built-artifact test under
/// `apps/rooms/test/` is the final authority that this source contract worked.
pub fn checkBrowserFfiResolver(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const shared_import = "import { lazySymbols, libPath } from \"@glowcap/runtime/ffi\";";
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/internal/ffi/host.ts", &.{shared_import});
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/internal/ffi/ocapn.ts", &.{shared_import});
    try expectFileContains(io, gpa, root, violations, "bindings/ts/runtime/internal/ffi/driver.ts", &.{shared_import});
    try expectFileContains(io, gpa, root, violations, "tools/gen/binding/ts_ffi.zig", &.{
        "import { lazySymbols, libPath } from \"@glowcap/runtime/ffi\";",
    });
    try expectFileContains(io, gpa, root, violations, "bindings/ts/web/browser-bundle.json", &.{
        "\"@glowcap/runtime/ffi\": \"./browser_ffi.ts\"",
    });
    try expectFileContains(io, gpa, root, violations, "apps/rooms/web/browser-bundle.json", &.{
        "\"@glowcap/abi\": \"../../../bindings/ts/abi/constants.ts\"",
        "\"@glowcap/web\": \"../../../bindings/ts/web/mod.ts\"",
        "\"@glowcap/runtime\": \"../../../bindings/ts/runtime/mod.ts\"",
        "\"@glowcap/runtime/websocket\": \"../../../bindings/ts/runtime/websocket.ts\"",
        "\"@glowcap/runtime/ffi\": \"../../../bindings/ts/web/browser_ffi.ts\"",
        "\"@glowcap/runtime/transport\": \"../../../bindings/ts/runtime/transport.ts\"",
        "\"@glowcap/relay\": \"../../../bindings/ts/relay/mod.ts\"",
        "\"@glowcap/iroh\": \"../../../bindings/ts/web/browser_iroh_stub.ts\"",
        "\"@glowcap/iroh/internal\": \"../../../bindings/ts/web/browser_iroh_stub.ts\"",
        "\"@glowcap/webrtc\": \"../../../bindings/ts/webrtc/mod.ts\"",
        "\"@glowcap/webrtc/channel\": \"../../../bindings/ts/webrtc/channel.ts\"",
        "\"@glowcap/tcp\": \"../../../bindings/ts/tcp/mod.ts\"",
        "\"node:net\": \"../../../bindings/ts/web/browser_ffi_stubs.ts\"",
        "\"bun:ffi\": \"../../../bindings/ts/web/browser_ffi_stubs.ts\"",
        "\"react\": \"npm:react@",
        "\"zustand\": \"npm:zustand@",
        "\"zod/mini\": \"npm:zod@",
    });
    const binding_bundle = try root.readFileAlloc(io, "bindings/ts/web/browser-bundle.json", gpa, .limited(1 << 20));
    defer gpa.free(binding_bundle);
    for ([_][]const u8{ "npm:react", "npm:zustand", "npm:zod" }) |application_dependency| {
        if (std.mem.indexOf(u8, binding_bundle, application_dependency) != null) {
            try appendViolation(gpa, violations, "bindings/ts/web/browser-bundle.json: binding config owns application dependency `{s}`; move it to the application's own bundle config", .{application_dependency});
        }
    }
    try expectFileContains(io, gpa, root, violations, "apps/ocapnviz/deno.json", &.{
        "\"@glowcap/runtime/ffi\": \"../../bindings/ts/web/browser_ffi.ts\"",
    });

    const path = "bindings/ts/web/browser_ffi.ts";
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for browser FFI resolver check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    if (std.mem.indexOf(u8, contents, "../runtime/internal/ffi/surface.ts") == null or
        std.mem.indexOf(u8, contents, "return stem;") == null)
    {
        try appendViolation(gpa, violations, "{s}: must pair the shared FFI surface with a stem-only wasm resolver", .{path});
    }
    if (std.mem.indexOf(u8, contents, "load.ts") != null or
        std.mem.indexOf(u8, contents, "node:") != null or
        std.mem.indexOf(u8, contents, "bun:ffi") != null)
    {
        try appendViolation(gpa, violations, "{s}: browser FFI resolver must not import or name a native archive/runtime module", .{path});
    }
}
