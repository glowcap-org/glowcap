//! Persisted cleanup progress and an exact one-step acknowledgement floor.
pub const MaintenancePosition = struct {
    sequence: u64 = 0,
    last: Command = .none,
    phase: Phase = .idle,
    cursor: u64 = 0,
    pub const Command = enum { none, sweep, retire, step };
    pub const Phase = enum { idle, observations, identities, grants, resources };
};
