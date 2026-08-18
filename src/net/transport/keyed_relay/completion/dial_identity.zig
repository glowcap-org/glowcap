//! Collision-free internal identities for resolver and address-race work.

pub fn Identity(comptime Namespace: type, comptime ConnId: type, comptime DialOp: type) type {
    return struct {
        const marker: u64 = @as(u64, 1) << 40;
        pub const resolver_wake_ud = Namespace.userData(marker);

        pub fn userData(operation: DialOp, connection_id: ConnId, leg_slot: u3) u64 {
            return Namespace.userData(
                marker |
                    (@as(u64, connection_id) << 7) |
                    (@as(u64, leg_slot) << 1) |
                    @intFromEnum(operation),
            );
        }

        pub fn id(user_data: u64) ConnId {
            return @intCast((Namespace.userDataPayload(user_data) & ~marker) >> 7);
        }

        pub fn slot(user_data: u64) u3 {
            return @intCast((Namespace.userDataPayload(user_data) >> 1) & 7);
        }

        pub fn op(user_data: u64) DialOp {
            return @enumFromInt(@as(u1, @truncate(user_data)));
        }

        pub fn owns(user_data: u64) bool {
            if (!Namespace.ownsUserData(user_data) or user_data == resolver_wake_ud) return false;
            return Namespace.userDataPayload(user_data) & marker != 0;
        }

        /// Reserve one synthetic descriptor identity across both admitted and
        /// still-opening relay rows. Keeping this beside the bit layout makes
        /// collision freedom one authority rather than a parent-loop detail.
        pub fn reserve(backend: anytype) error{TooManyConnections}!ConnId {
            var remaining: u64 = Namespace.max_fd_id;
            while (remaining != 0) : (remaining -= 1) {
                const connection_id = backend.next_id;
                backend.next_id = if (connection_id == Namespace.max_fd_id) 1 else connection_id + 1;
                if (!backend.conns.contains(connection_id) and
                    !backend.pending_dials.contains(connection_id)) return connection_id;
            }
            return error.TooManyConnections;
        }
    };
}
