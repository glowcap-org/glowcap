//! One `std.Io` stream adapter shared by the byte-source transports.
//!
//! The inproc resident reads an in-process pipe and the iroh resident reads the
//! sidecar's QUIC stream, but the `std.Io.Reader` / `std.Io.Writer` vtable
//! scaffolding around those byte sources is identical: recover the concrete
//! stream from `&interface` by field offset, fill the first writable slice,
//! keep any overflow in the reader's buffer, and drain buffered and vectored
//! writes through one write-all primitive. `Shim` owns that scaffolding once; a
//! transport brings only its byte source as the `Source` type. (tcp does not
//! ride this: its stream is `std.Io.net.Stream`, which carries its own
//! reader/writer.)
//!
//! `Source` is a small copyable value declaring three methods:
//!
//! - `fn readSome(self: Source, dest: []u8) std.Io.Reader.Error!usize` blocks
//!   for at least one byte and returns the count read, `error.EndOfStream` at
//!   the source's clean end, `error.ReadFailed` on a fault.
//! - `fn writeAll(self: Source, bytes: []const u8) std.Io.Writer.Error!void`
//!   writes the whole slice or fails.
//! - `fn flush(self: Source) std.Io.Writer.Error!void` runs once at the end of
//!   every drain, so a source whose faults surface out-of-band (a QUIC
//!   connection that died under the writes) reports them; a source with no
//!   flush step makes it a no-op.

const std = @import("std");

const Io = std.Io;

const max_iovecs = 8;

/// The reader/writer pair over one `Source`. The concrete `Reader` / `Writer`
/// values must live at a stable address for as long as their `interface` is
/// borrowed (the vtable recovers them from `&interface` by field offset), so
/// the owning transport pins them, exactly as `PinnedRawStream` pins a socket.
pub fn Shim(comptime Source: type) type {
    return struct {
        pub const Reader = struct {
            interface: Io.Reader,
            source: Source,

            /// The vtable-wired reader over `source`; `buffer` is caller-owned
            /// and borrowed for the reader's life.
            pub fn init(source: Source, buffer: []u8) Reader {
                return .{
                    .interface = .{ .vtable = &reader_vtable, .buffer = buffer, .seek = 0, .end = 0 },
                    .source = source,
                };
            }

            fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
                const dest = limit.slice(try io_w.writableSliceGreedy(1));
                var data: [1][]u8 = .{dest};
                const n = try readVec(io_r, &data);
                io_w.advance(n);
                return n;
            }

            fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
                const self: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
                var iovecs: [max_iovecs][]u8 = undefined;
                const dest_n, const data_size = try io_r.writableVector(&iovecs, data);
                const dest = iovecs[0..dest_n];
                std.debug.assert(dest[0].len > 0);
                // A short read into the first writable slice is allowed by the
                // vtable contract; the source hands over whatever has arrived.
                const n = try self.source.readSome(dest[0]);
                if (n > data_size) {
                    io_r.end += n - data_size;
                    return data_size;
                }
                return n;
            }
        };

        pub const Writer = struct {
            interface: Io.Writer,
            source: Source,

            /// The vtable-wired writer over `source`; `buffer` is caller-owned
            /// and borrowed for the writer's life.
            pub fn init(source: Source, buffer: []u8) Writer {
                return .{
                    .interface = .{ .vtable = &writer_vtable, .buffer = buffer },
                    .source = source,
                };
            }

            fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
                const self: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
                var total: usize = 0;
                const buffered = io_w.buffered();
                if (buffered.len > 0) {
                    try self.source.writeAll(buffered);
                    total += buffered.len;
                }
                const slices = data[0 .. data.len - 1];
                for (slices) |slice| {
                    if (slice.len == 0) continue;
                    try self.source.writeAll(slice);
                    total += slice.len;
                }
                const pattern = data[data.len - 1];
                if (pattern.len > 0) {
                    var i: usize = 0;
                    while (i < splat) : (i += 1) try self.source.writeAll(pattern);
                    total += pattern.len * splat;
                }
                try self.source.flush();
                return io_w.consume(total);
            }
        };

        const reader_vtable = Io.Reader.VTable{ .stream = Reader.streamImpl, .readVec = Reader.readVec };
        const writer_vtable = Io.Writer.VTable{ .drain = Writer.drain };
    };
}
