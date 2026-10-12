//! Explicit close for a CLI-owned `driver.Server`. Implicit `deinit` retains
//! leftovers on the Runtime with no product-front recipient. This barrier
//! returns the exact chain so `close` and argv listen can keep it.

const glowcap = @import("glowcap");
const Ctx = @import("../ctx.zig").Ctx;

const driver = glowcap.driver;
const FailureChain = glowcap.foundation.FailureChain;

/// Join a Server's close barrier, then release the handle. Close is consuming:
/// a returned chain is the outcome, not a reason to skip `deinit`.
pub fn closeServer(_: *Ctx, server: *driver.Server) ?FailureChain {
    const failure = if (server.close()) |op| op.toChain() else null;
    server.deinit();
    return failure;
}
