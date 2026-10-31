//! Explicit release inventories share one transactional staging operation.
const std = @import("std");
const common = @import("../common.zig");
const execution = @import("../execution.zig");
const transaction = @import("transaction.zig");

pub const Manifest = struct {
    static_archives: []const []const u8 = &.{},
    dynamic_archives: []const []const u8 = &.{},
    headers: []const []const u8 = &.{},
    binaries: []const []const u8 = &.{},
    helpers: []const []const u8 = &.{},
    rooms: bool = false,
};

pub const helpers = &.{ "rooms-server", "rooms-session", "rooms-web", "rooms-archive", "rooms-chat", "rooms-irc-server", "rooms-irc-bridge" };
pub const product: Manifest = .{
    .dynamic_archives = &.{ "glowcap_net_transport_iroh", "glowcap_net_transport_webrtc" },
    .binaries = &.{"glowcap"},
    .helpers = helpers,
    .rooms = true,
};

pub fn join(b: *std.Build, items: []const []const u8) []const u8 {
    return std.mem.join(b.allocator, " ", items) catch @panic("OOM");
}

/// The sealer is a host tool even when the staged product targets another
/// platform: it runs during the host build transaction, before publication.
fn productManifestModule(b: *std.Build) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("tools/gen/product_manifest.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    module.addImport("installation_manifest", b.createModule(.{
        .root_source_file = b.path("cli/installation/manifest.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    return module;
}

fn productManifest(b: *std.Build) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = "glowcap-product-manifest", .root_module = productManifestModule(b) });
}

/// Keep generation and parsing under the ordinary check gate without needing
/// a release-package build to reach their focused tests.
pub fn addManifestTests(b: *std.Build) *std.Build.Step.Run {
    const tests = b.addTest(.{ .name = "product-manifest-test", .root_module = productManifestModule(b) });
    return execution.addZigTest(b, tests, .unit_test);
}

/// Complete the ordinary install prefix from the same manifest-staged product
/// used for deployment. The source launcher and packaged binary then resolve
/// assets and skills by the same installation-relative rule.
pub fn installResources(b: *std.Build, product_directory: []const u8) *std.Build.Step.Run {
    const run = common.addInstalledSystemRun(b, .build_tool, &.{
        "sh",                "-ec",
        transaction.wrap(b,
            \\marker=release.json
            \\cp -R -L "$2/." "$stage/tree/"
            \\for document in "$2/../../"*; do
            \\  if [ -f "$document" ]; then cp "$document" "$3/"; fi
            \\done
        ),
        "glowcap-resources",
    });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "share/glowcap" } }, .{ .make_absolute = true });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = b.fmt("{s}/share/glowcap", .{product_directory}) } }, .{ .make_absolute = true });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    return run;
}

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, version: std.SemanticVersion, directory: []const u8, manifest: Manifest) *std.Build.Step.Run {
    const minimum = switch (target.result.os.tag) {
        .linux => target.result.os.version_range.linux.glibc,
        .macos => target.result.os.version_range.semver.min,
        else => std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 },
    };
    const run = common.addInstalledSystemRun(b, .build_tool, &.{
        "sh",            "-ec",
        transaction.wrap(b, b.fmt(
            \\prefix="$2"
            \\marker=share/glowcap/release.json
            \\mkdir -p "$stage/tree/lib" "$stage/tree/include" "$stage/tree/bin" "$stage/tree/libexec" "$stage/tree/share/glowcap"
            \\for name in {s}; do
            \\  test -f "$prefix/lib/lib$name.a" || {{ echo "missing static archive $name" >&2; exit 1; }}
            \\  cp -L "$prefix/lib/lib$name.a" "$stage/tree/lib/"
            \\done
            \\case '{s}' in
            \\  linux) suffixes='.so .so.{d} .so.{d}.{d}.{d}'; runtime_suffix='.so.{d}' ;;
            \\  macos) suffixes='.dylib .{d}.dylib .{d}.{d}.{d}.dylib'; runtime_suffix='.{d}.dylib' ;;
            \\  *) echo 'no release library layout for target OS' >&2; exit 1 ;;
            \\esac
            \\if [ '{s}' = true ]; then suffixes="$runtime_suffix"; fi
            \\for name in {s}; do
            \\  for suffix in $suffixes; do
            \\    test -f "$prefix/lib/lib$name$suffix" || {{ echo "missing shared-library member $name$suffix" >&2; exit 1; }}
            \\    cp -L "$prefix/lib/lib$name$suffix" "$stage/tree/lib/"
            \\  done
            \\done
            \\for name in {s}; do cp "include/$name" "$stage/tree/include/"; done
            \\# A packaged README is read as plain text, so it drops the doc's OKF header.
            \\without_header() {{ awk 'NR == 1 && $0 == "---" {{ head = 1; next }} head && $0 == "---" {{ head = 0; gap = 1; next }} head {{ next }} gap && $0 == "" {{ gap = 0; next }} {{ gap = 0; print }}' "$1"; }}
            \\for name in {s}; do cp "$prefix/bin/$name" "$stage/tree/bin/"; done
            \\for name in {s}; do cp "$prefix/libexec/$name" "$stage/tree/libexec/"; done
            \\if [ '{s}' = true ]; then
            \\  mkdir -p "$stage/tree/share/glowcap/rooms" "$stage/tree/share/glowcap/skills/rooms-peer/references" "$stage/tree/share/glowcap/skills/rooms-team"
            \\  cp -R -L zig-out/rooms-web/current/. "$stage/tree/share/glowcap/rooms/"
            \\  mkdir -p "$stage/tree/share/glowcap/deployment"
            \\  cp apps/rooms/web/deploy/rooms.Dockerfile apps/rooms/web/deploy/docker-compose.yml apps/rooms/web/deploy/docker-compose.override.yml.example "$stage/tree/share/glowcap/deployment/"
            \\  for path in rooms-peer/SKILL.md rooms-peer/references/commands.md rooms-team/SKILL.md rooms-team/ops.md rooms-team/gotchas.md rooms-team/strategies.md; do
            \\    cp ".agents/skills/$path" "$stage/tree/share/glowcap/skills/$path"
            \\  done
            \\  browser=$(tr -d '\n' < "$stage/tree/share/glowcap/rooms/source.version")
            \\  case "$browser" in *[!a-f0-9]*|'') echo 'invalid browser revision' >&2; exit 1;; esac
            \\  test "${{#browser}}" -eq 64
            \\  without_header apps/rooms/host.md > "$stage/tree/README.md"
            \\else
            \\  browser=''
            \\  without_header docs/c-sdk.md > "$stage/tree/README.md"
            \\fi
            \\revision=$(git rev-parse HEAD)
            \\dirty=false
            \\if [ -n "$(git status --porcelain)" ]; then dirty=true; fi
            \\printf '{{"version":"{d}.{d}.{d}","target":"{s}-{s}","minimum_runtime":"{s} {d}.{d}.{d}","revision":"%s","dirty":%s,"browser":"%s","checkout_preparation":{s}}}\n' "$revision" "$dirty" "$browser" > "$stage/tree/share/glowcap/release.json"
            \\cp PROVENANCE.md LICENSE-APACHE LICENSE-THIRD-PARTY "$stage/tree/"
            \\if find "$stage/tree" ! -type d ! -type f -print | grep -q .; then
            \\  echo 'stage must contain only regular files and directories' >&2; exit 1
            \\fi
            \\if [ '{s}' = true ]; then "$3" "$stage/tree"; fi
        , .{
            join(b, manifest.static_archives),       @tagName(target.result.os.tag),
            version.major,                           version.major,
            version.minor,                           version.patch,
            version.major,                           version.major,
            version.major,                           version.minor,
            version.patch,                           version.major,
            if (manifest.rooms) "true" else "false", join(b, manifest.dynamic_archives),
            join(b, manifest.headers),               join(b, manifest.binaries),
            join(b, manifest.helpers),               if (manifest.rooms) "true" else "false",
            version.major,                           version.minor,
            version.patch,                           @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),          if (target.result.os.tag == .linux) "glibc" else "macOS",
            minimum.major,                           minimum.minor,
            minimum.patch,                           if (manifest.rooms) "true" else "false",
            if (manifest.rooms) "true" else "false",
        })),
        "glowcap-stage",
    });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = directory } }, .{ .make_absolute = true });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    if (manifest.rooms) run.addFileArg(productManifest(b).getEmittedBin());
    run.step.dependOn(b.getInstallStep());
    return run;
}
