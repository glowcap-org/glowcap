//! The rows of the table. Combinations left out because they cannot exist:
//! - A plain room is open for its whole life, because `open` takes no policy,
//!   so it has no moderated rows and no policy change. A plain private room
//!   is a different kind of row: it is unlisted, held by its recovery key, and
//!   shown only as opened.
//! - A plain room has no recovery key and no manager link a client holds, so
//!   it has no key or manager asker. A plain private room has a key asker and
//!   no manager.
//! - A managed room whose record is not yet written has issued no manager
//!   link, and its key holder's ask is the `roomAuthorities` write itself.
//! - A revoked link and a forgotten room cross one policy each, because the
//!   policy rule and the revocation rule read different facts. A room opened
//!   again after a forget has a row for each policy it comes back with.
//! - A plain room's link is remade by its name where the room has no
//!   manager, so only a managed room has rows for a link its manager remade.
//! - An invitation is refused before the room's policy or its link is read,
//!   so it has one row as opened and one for a member whose own link was
//!   revoked.
use super::*;

pub(super) fn rows() -> Vec<Row> {
	use Asker::{Entrance, Key, Manager, Name};
	use Change::{
		AsOpened, Forgotten, ForgottenThenOpened, LinkRemade, LinkRevokedNeverManaged, LinkRevokedThenManagerIssued,
		LinkRevokedThenManagerRevoked, LinkRevokedWithManager, RecordUnwritten,
	};
	use Holder::{SeatedAsTheNameOffers, SeatedThroughIt, Unseated};
	use Told::{Link, Refused};
	let plain = Kind::Plain;
	let private = Kind::Private;
	let managed = Kind::Managed;
	vec![
		row(plain, None, AsOpened, Name, Link),
		row(plain, None, AsOpened, Entrance(Unseated), Link),
		row(plain, None, AsOpened, Entrance(SeatedThroughIt), Link),
		row(plain, None, LinkRevokedNeverManaged, Name, Link),
		row(
			plain,
			None,
			LinkRevokedNeverManaged,
			Entrance(Unseated),
			Refused(NAME_NEXT),
		),
		row(
			plain,
			None,
			LinkRevokedNeverManaged,
			Asker::Link(SeatedThroughIt),
			Refused(LINK_REVOKED),
		),
		row(plain, None, LinkRevokedWithManager, Name, Refused(MANAGER_NEXT)),
		row(
			plain,
			None,
			LinkRevokedWithManager,
			Asker::Opener,
			Refused(MANAGER_NEXT),
		),
		row(plain, None, LinkRevokedThenManagerRevoked, Name, Link),
		row(plain, None, LinkRevokedThenManagerIssued, Name, Link),
		row(
			plain,
			None,
			LinkRevokedThenManagerIssued,
			Asker::Link(Unseated),
			Refused(LINK_REVOKED),
		),
		row(plain, None, Forgotten, Name, Refused("no-such-room: no room named")),
		row(plain, None, Forgotten, Entrance(Unseated), Refused(GATE_CLOSED)),
		row(plain, None, ForgottenThenOpened(OPEN), Name, Link),
		row(
			plain,
			None,
			ForgottenThenOpened(OPEN),
			Asker::Link(Unseated),
			Refused(LINK_REVOKED),
		),
		row(private, None, AsOpened, Name, Refused("no-such-room: no room named")),
		row(private, None, AsOpened, Key, Link),
		row(managed(OPEN), None, AsOpened, Name, Link),
		row(managed(OPEN), None, AsOpened, Entrance(Unseated), Link),
		row(managed(OPEN), None, AsOpened, Asker::Link(Unseated), Link),
		row(
			managed(OPEN),
			None,
			AsOpened,
			Asker::Invitation(Minter::Owner),
			Refused(INVITATION),
		),
		row(managed(OPEN), None, AsOpened, Manager, Link),
		row(managed(OPEN), None, AsOpened, Key, Link),
		row(managed(MODERATED), None, AsOpened, Name, Refused(SEATS_WATCH)),
		row(
			managed(MODERATED),
			None,
			AsOpened,
			Entrance(Unseated),
			Refused(SEATS_WATCH),
		),
		row(managed(MODERATED), None, AsOpened, Asker::Link(Unseated), Link),
		row(managed(MODERATED), None, AsOpened, Asker::Link(SeatedThroughIt), Link),
		row(managed(MODERATED), None, AsOpened, Manager, Link),
		row(managed(MODERATED), None, AsOpened, Key, Link),
		row(managed(OPEN), Some(MODERATED), AsOpened, Name, Refused(SEATS_WATCH)),
		row(
			managed(OPEN),
			Some(MODERATED),
			AsOpened,
			Entrance(Unseated),
			Refused(GATE_CLOSED),
		),
		row(
			managed(OPEN),
			Some(MODERATED),
			AsOpened,
			Entrance(SeatedThroughIt),
			Refused(GATE_CLOSED),
		),
		row(
			managed(OPEN),
			Some(MODERATED),
			AsOpened,
			Asker::Link(SeatedThroughIt),
			Link,
		),
		row(
			managed(OPEN),
			Some(MODERATED),
			AsOpened,
			Entrance(SeatedAsTheNameOffers),
			Refused(GATE_CLOSED),
		),
		row(managed(MODERATED), Some(OPEN), AsOpened, Name, Link),
		row(
			managed(MODERATED),
			Some(OPEN),
			AsOpened,
			Entrance(Unseated),
			Refused(GATE_CLOSED),
		),
		row(
			managed(MODERATED),
			Some(OPEN),
			AsOpened,
			Entrance(SeatedThroughIt),
			Refused(GATE_CLOSED),
		),
		row(
			managed(OPEN),
			Some(PRIVATE),
			AsOpened,
			Name,
			Refused("no-such-room: no room named"),
		),
		row(
			managed(OPEN),
			Some(PRIVATE),
			AsOpened,
			Entrance(Unseated),
			Refused(GATE_CLOSED),
		),
		row(managed(OPEN), Some(PRIVATE), AsOpened, Manager, Link),
		row(managed(OPEN), None, LinkRevokedWithManager, Name, Refused(MANAGER_NEXT)),
		row(
			managed(OPEN),
			None,
			LinkRevokedWithManager,
			Entrance(Unseated),
			Refused(MANAGER_NEXT),
		),
		row(managed(OPEN), None, LinkRevokedWithManager, Manager, Link),
		row(
			managed(OPEN),
			None,
			LinkRevokedThenManagerRevoked,
			Name,
			Refused(KEY_NEXT),
		),
		row(
			managed(OPEN),
			None,
			LinkRevokedThenManagerRevoked,
			Manager,
			Refused(MANAGER_REVOKED),
		),
		row(
			managed(OPEN),
			None,
			LinkRevokedThenManagerRevoked,
			Asker::Opener,
			Refused(KEY_NEXT),
		),
		row(managed(OPEN), None, LinkRevokedThenManagerRevoked, Key, Link),
		row(managed(OPEN), None, LinkRemade, Name, Link),
		row(managed(OPEN), None, LinkRemade, Manager, Link),
		row(managed(OPEN), None, LinkRemade, Asker::Opener, Link),
		row(managed(OPEN), Some(MODERATED), AsOpened, Asker::Opener, Link),
		row(
			managed(OPEN),
			None,
			LinkRemade,
			Asker::Link(Unseated),
			Refused(LINK_REVOKED),
		),
		row(
			managed(OPEN),
			None,
			LinkRemade,
			Asker::Link(SeatedThroughIt),
			Refused(LINK_REVOKED),
		),
		row(
			managed(OPEN),
			None,
			LinkRemade,
			Asker::Invitation(Minter::SeatedThroughTheFirstLink),
			Refused(INVITATION),
		),
		row(
			managed(OPEN),
			None,
			Forgotten,
			Name,
			Refused("no-such-room: no room named"),
		),
		row(managed(OPEN), None, Forgotten, Entrance(Unseated), Refused(GATE_CLOSED)),
		row(managed(OPEN), None, Forgotten, Manager, Refused(MANAGER_REVOKED)),
		row(
			managed(OPEN),
			None,
			ForgottenThenOpened(MODERATED),
			Name,
			Refused(SEATS_WATCH),
		),
		row(
			managed(OPEN),
			None,
			ForgottenThenOpened(MODERATED),
			Entrance(Unseated),
			Refused(GATE_CLOSED),
		),
		row(
			managed(OPEN),
			None,
			ForgottenThenOpened(OPEN),
			Asker::Link(Unseated),
			Refused(LINK_REVOKED),
		),
		row(
			managed(OPEN),
			None,
			ForgottenThenOpened(OPEN),
			Manager,
			Refused(MANAGER_REVOKED),
		),
		row(managed(MODERATED), None, RecordUnwritten, Name, Refused(SEATS_WATCH)),
		row(
			managed(MODERATED),
			None,
			RecordUnwritten,
			Entrance(Unseated),
			Refused(SEATS_WATCH),
		),
		row(managed(OPEN), None, RecordUnwritten, Name, Link),
	]
}
