//! Private aggregate for the Rust Session scenario families.

#[path = "session_tests/support.rs"]
pub(crate) mod support;

#[path = "session_tests/capabilities.rs"]
mod capabilities;
#[path = "session_tests/codec_values.rs"]
mod codec_values;
#[path = "session_tests/handoff_and_observability.rs"]
mod handoff_and_observability;
#[path = "session_tests/lifecycle.rs"]
mod lifecycle;
#[path = "session_tests/profiles.rs"]
mod profiles;
#[path = "session_tests/promise_arguments.rs"]
mod promise_arguments;
#[path = "session_tests/verbs.rs"]
mod verbs;
#[path = "session_tests/wire_ownership.rs"]
mod wire_ownership;

#[path = "session_tests/reply_ownership.rs"]
mod reply_ownership;

#[path = "session_tests/fetch_custody.rs"]
mod fetch_custody;

#[path = "session_tests/unobserved_custody.rs"]
mod unobserved_custody;

#[path = "session_tests/enliven_gc.rs"]
mod enliven_gc;

#[path = "session_tests/current_session.rs"]
mod current_session;

#[path = "session_tests/shared_ownership.rs"]
mod shared_ownership;

#[path = "session_tests/flush.rs"]
mod flush;

#[path = "session_tests/far_promises.rs"]
mod far_promises;
