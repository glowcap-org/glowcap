//! Closed vocabulary for the relay reactor's polled subjects and listener
//! lifecycle slot. The reactor owns transitions; these types only make its
//! mutually exclusive states explicit.

pub fn PollSubject(
    comptime ListenerSetup: type,
    comptime ListenerState: type,
    comptime ConnState: type,
) type {
    return union(enum) {
        wake,
        listener_setup: *ListenerSetup,
        listener: *ListenerState,
        connection: *ConnState,
    };
}

pub fn ListenerSlot(comptime ListenerSetup: type, comptime ListenerState: type) type {
    return union(enum) {
        empty,
        starting: *ListenerSetup,
        active: *ListenerState,
    };
}
