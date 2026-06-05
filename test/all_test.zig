comptime {
    _ = @import("foundation/frame_test.zig");
    _ = @import("foundation/id_test.zig");
    _ = @import("foundation/crypto_test.zig");
    _ = @import("codec/syrup_test.zig");
    _ = @import("codec/capnp_test.zig");
    _ = @import("model/model_test.zig");
    _ = @import("model/equality_test.zig");
    _ = @import("model/view_test.zig");
    _ = @import("oracle/protocol_oracle_test.zig");
    _ = @import("conformance/parity_test.zig");
    _ = @import("c_abi/frame_test.zig");
    _ = @import("io_adapter/memory_endpoint_test.zig");
    _ = @import("session/session_test.zig");
    _ = @import("session/bootstrap_test.zig");
    _ = @import("runtime/peer_test.zig");
    _ = @import("runtime/negotiation_test.zig");
    _ = @import("runtime/abort_projection_test.zig");
    _ = @import("runtime/pipeline_test.zig");
    _ = @import("runtime/fetch_test.zig");
    _ = @import("runtime/bootstrap_test.zig");
    _ = @import("runtime/sturdyref_test.zig");
    _ = @import("runtime/registry_test.zig");
    _ = @import("runtime/cross_peer_test.zig");
    _ = @import("runtime/factories_test.zig");
}
