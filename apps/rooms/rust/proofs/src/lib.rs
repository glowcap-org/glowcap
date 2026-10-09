//! Executable application contracts. These are proof entry points, not a Rooms
//! UI API or a second production glowcap binding.
// The binding owns archive composition and target layouts on both hosts.
mod archive;
mod archive_blobs;
mod archive_disk;
mod archive_documents;
mod archive_host;
mod archive_identity;
mod archive_merge;
mod archive_recording;
mod archive_shares;
mod arguments;
#[cfg(all(target_arch = "wasm32", feature = "async-host"))]
mod async_host;
mod authority_client;
mod binding;
mod bridge_client;
mod checkpoint;
mod command_admission;
#[cfg(any(
	all(test, not(target_arch = "wasm32")),
	all(target_arch = "wasm32", feature = "async-host")
))]
mod content_policy;
mod content_session;
mod controller_commands;
mod conversation;
mod direct_client;
mod direct_line;
mod direct_operation;
mod directory_client;
mod directory_view;
mod documents;
mod failures;
mod files;
mod grant_protocol;
mod grants;
mod handed_rooms;
mod host;
mod inbox_publication;
mod introduction_client;
mod invitation_client;
mod membership;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod native_files;
mod operator_views;
mod reconciliation;
mod registration_client;
mod room;
mod room_links;
mod room_operation;
mod room_view;
mod session_capacity;
mod session_commands;
mod session_events;
#[cfg(any(
	all(test, not(target_arch = "wasm32")),
	all(target_arch = "wasm32", feature = "async-host")
))]
mod session_executor;
#[cfg(any(
	all(test, not(target_arch = "wasm32")),
	all(target_arch = "wasm32", feature = "async-host")
))]
mod session_foreign;
mod session_results;
mod session_state;
#[cfg(any(
	all(test, not(target_arch = "wasm32")),
	all(target_arch = "wasm32", feature = "async-host")
))]
mod session_storage;
mod signaling_client;
mod snapshot;
mod sources;
mod stewardship;
mod workspace;

#[unsafe(no_mangle)]
pub extern "C" fn rooms_contract_proof() -> u32 {
	binding::run();
	archive::run();
	archive_disk::run();
	archive_blobs::run();
	archive_shares::run();
	archive_identity::run();
	archive_merge::run();
	archive_documents::run();
	archive_recording::run();
	archive_host::run();
	authority_client::run();
	bridge_client::run();
	directory_client::run();
	directory_view::run();
	direct_client::run();
	direct_line::run();
	direct_operation::run();
	room_operation::run();
	room_view::run();
	registration_client::run();
	stewardship::run();
	membership::run();
	conversation::run();
	invitation_client::run();
	introduction_client::run();
	inbox_publication::run();
	grants::run();
	checkpoint::run();
	workspace::run();
	command_admission::run();
	content_session::run();
	session_capacity::run();
	controller_commands::run();
	reconciliation::run();
	session_commands::run();
	session_results::run();
	snapshot::run();
	session_events::run();
	operator_views::run();
	sources::run();
	signaling_client::run();
	session_state::run();
	grant_protocol::run();
	documents::run();
	files::run();
	failures::run();
	room::run();
	room_links::run();
	handed_rooms::run();
	host::run();
	1
}

#[test]
fn shared_application_and_static_host() {
	content_policy::run();
	assert_eq!(rooms_contract_proof(), 1);
}
