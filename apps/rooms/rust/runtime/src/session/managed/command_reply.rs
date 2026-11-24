//! The kind of result a session command settles with, decided by the route
//! its admission takes, so a client can tell before sending what it would
//! have to keep.
use rooms_application::{
	content::session::{dispatch::Dispatch, local},
	room::ArgumentView,
	session::{
		command::{Effect, Request, Route},
		effect::Reply,
	},
};

/// The kind of result `request` settles with once it is sent, routed in the
/// order command admission routes it. A local command answers none, because
/// it has nothing to keep: it settles at admission, except turning history
/// off, whose receipt stays pending until the recording owner has erased.
/// A request that dispatch refuses answers none too, and admission refuses it.
pub fn command_reply<A: ArgumentView>(request: &Request<'_, A>) -> Option<Reply> {
	let route = request.route();
	if local::recognizes(route) {
		None
	} else if super::archive_sharing::recognizes(route) {
		Some(if route == Route::Effect(Effect::RevokeIssuedArchiveShare) {
			Reply::Boolean
		} else {
			Reply::Acknowledgment
		})
	} else if super::manager_recovery::recognizes(route) {
		Some(Reply::RoomManager)
	} else {
		Dispatch::parse(request).ok().map(|dispatch| dispatch.mutation.reply)
	}
}
