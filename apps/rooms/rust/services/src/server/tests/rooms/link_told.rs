//! Who is told a room's link. Every row builds a room on a real server,
//! changes it the way an operator or its manager would, asks as one of the
//! askers a room has, and states whether the link is told or what refuses it.
//! A told link must also seat a participant, so a row cannot pass by telling
//! a link that does not post.
use super::*;
use glowcap::Argument;
use rooms_application::{directory::creation, room::authority};
use rooms_glowcap::client::directory::ManagedRoom;
use rows::rows;

mod rows;

#[derive(Clone, Copy, Debug)]
enum Kind {
	Plain,
	/// A plain room opened private under its recovery key.
	Private,
	/// A managed room opened under this policy.
	Managed(RoomPolicy),
}

#[derive(Clone, Copy, Debug)]
enum Change {
	AsOpened,
	/// A manager holds the room and the link was revoked. The manager revoked
	/// a managed room's link. An operator issued a plain room's manager and
	/// revoked its link.
	LinkRevokedWithManager,
	/// The link was revoked while a manager held the room, and then the
	/// manager was revoked.
	LinkRevokedThenManagerRevoked,
	/// An operator revoked the link of a plain room no manager has held.
	LinkRevokedNeverManaged,
	/// An operator revoked a plain room's link and then issued the room a
	/// manager, which makes the room's link as well.
	LinkRevokedThenManagerIssued,
	/// The manager revoked the link and made the next one.
	LinkRemade,
	Forgotten,
	/// The room was forgotten and then opened again under the same name: a
	/// managed room under the same key with this policy, and a plain room
	/// that an operator had issued a manager.
	ForgottenThenOpened(RoomPolicy),
	/// A managed room opened and listed whose record `roomAuthorities` has not
	/// written yet.
	RecordUnwritten,
}

#[derive(Clone, Copy, Debug)]
enum Holder {
	/// A stranger who holds the entrance and sits nowhere.
	Unseated,
	/// A member seated through the entrance before anything changed.
	SeatedThroughIt,
	/// A member who took the entrance, and after the change entered again and
	/// sits as what the name offers now.
	SeatedAsTheNameOffers,
}

/// Who mints the invitation an asker claims.
#[derive(Clone, Copy, Debug)]
enum Minter {
	Owner,
	/// A member seated through the room's first link before the change.
	SeatedThroughTheFirstLink,
}

#[derive(Clone, Copy, Debug)]
enum Asker {
	Name,
	/// The entrance the room's name gave before the change, asked in a room
	/// verb.
	Entrance(Holder),
	/// The room's first link, entered before the change and asked in a room
	/// verb.
	Link(Holder),
	/// The entrance `open` answered whoever opened the room.
	Opener,
	/// The entrance of a participant invitation, minted and claimed after the
	/// change and asked before it seats anyone.
	Invitation(Minter),
	Manager,
	Key,
}

#[derive(Debug)]
enum Told {
	Link,
	Refused(&'static str),
}

struct Row {
	kind: Kind,
	/// The policy the manager sets before the ask, when it differs.
	now: Option<RoomPolicy>,
	change: Change,
	asker: Asker,
	expected: Told,
}

const OPEN: RoomPolicy = RoomPolicy::Open;
const MODERATED: RoomPolicy = RoomPolicy::Moderated;
const PRIVATE: RoomPolicy = RoomPolicy::Private;
const SEATS_WATCH: &str = "read-only-membership: this room's link lets its holder post, and this way in only watches";
const GATE_CLOSED: &str = "no-such-room: this room entrance is no longer offered";
const INVITATION: &str = "an invitation lets one person in";
const LINK_REVOKED: &str = "no-such-room: this room link was revoked";
const MANAGER_NEXT: &str = "this room has no link, and its manager makes the next one";
const KEY_NEXT: &str = "this room has no link, and the holder of its room key makes the next one";
const NAME_NEXT: &str = "this room has no link, and asking the directory for it by name makes one";
const MANAGER_REVOKED: &str = "this room manager capability was revoked";

fn row(kind: Kind, now: Option<RoomPolicy>, change: Change, asker: Asker, expected: Told) -> Row {
	Row {
		kind,
		now,
		change,
		asker,
		expected,
	}
}

struct Table {
	running: super::super::Running,
	owner: Client<HostPlatform>,
	stranger: Client<HostPlatform>,
	runtimes: [glowcap::Runtime; 2],
	_temp: Scratch,
}

impl Table {
	async fn start() -> Self {
		let temp = Scratch::create("server");
		let running = super::super::start_with(
			temp.to_path_buf(),
			tcp(),
			crate::server::Asked::parse("operator").unwrap(),
		)
		.await;
		let dial = glowcap::parse_locator(&running.location).unwrap();
		let (owner_runtime, stranger_runtime) = (runtime().await, runtime().await);
		let owner = Client::new(
			owner_runtime.connect(&dial, ConnectOptions::default()).await.unwrap(),
			HostPlatform,
		);
		let stranger = Client::new(
			stranger_runtime
				.connect(&dial, ConnectOptions::default())
				.await
				.unwrap(),
			HostPlatform,
		);
		Self {
			owner,
			stranger,
			running,
			runtimes: [owner_runtime, stranger_runtime],
			_temp: temp,
		}
	}

	async fn finish(self) {
		closing_tolerated(self.owner.session().close(PendingWork::Cancel).await);
		closing_tolerated(self.stranger.session().close(PendingWork::Cancel).await);
		self.running.stop.send(()).unwrap();
		self.running.task.await.unwrap().unwrap();
		for runtime in self.runtimes {
			runtime.close(PendingWork::Cancel).await.unwrap();
		}
	}
}

/// Whether holding `link` lets its holder post.
async fn link_posts(client: &Client<HostPlatform>, link: &str) -> bool {
	let entrance = client.enliven(link).await.unwrap();
	let (room, _lines, _, _) = join(client, entrance, "Visitor").await;
	room.say("hello").await.is_ok()
}

fn token(link: &str) -> String {
	rooms_glowcap::routes::CheckpointRoutes.authority_token(link).unwrap()
}

/// Run one row and return what its ask answered.
async fn ask(row: &Row) -> Result<String, String> {
	let table = Table::start().await;
	let key = RecoveryKey::from_entropy([61; 16]);
	let (owner, stranger) = (&table.owner, &table.stranger);
	let owner_directory = Directory::fetch(owner.clone()).await.unwrap();
	let stranger_directory = Directory::fetch(stranger.clone()).await.unwrap();
	let operator = owner
		.session()
		.fetch(&table.running.capabilities[0].swiss)
		.await
		.unwrap();
	let durable = match row.kind {
		Kind::Plain => "Salon",
		Kind::Private | Kind::Managed(_) => key.as_str(),
	};
	let on_operator = |verb: &'static str| {
		let (owner, operator) = (owner.clone(), operator.clone());
		async move { owner.session().send(&operator, verb, &[durable.into()]).await.unwrap() }
	};
	// The room, live and seating its owner.
	let mut created: Option<ManagedRoom> = None;
	let mut seats = Vec::new();
	let mut opened = None;
	let mut first_link = None;
	match (row.kind, row.change) {
		(Kind::Private, _) => {
			let room = owner_directory.open_private("Salon", &key).await.unwrap();
			seats.push(join(owner, room, "Owner").await);
		}
		(Kind::Plain, _) => {
			let room = owner_directory.open("Salon").await.unwrap();
			opened = Some(room.clone());
			seats.push(join(owner, room, "Owner").await);
			first_link = Some(owner_directory.link("Salon").await.unwrap());
		}
		(Kind::Managed(born), Change::RecordUnwritten) => {
			let [visibility, entry, speaking] = born.modes();
			owner
				.session()
				.send(
					owner_directory.reference(),
					creation::OPEN_MANAGED,
					&[
						"Salon".into(),
						visibility.into(),
						entry.into(),
						speaking.into(),
						key.as_str().into(),
					],
				)
				.await
				.unwrap();
		}
		(Kind::Managed(born), _) => {
			let made = owner_directory.open_managed("Salon", born, &key).await.unwrap();
			opened = Some(made.room.clone());
			seats.push(join(owner, made.room.clone(), "Owner").await);
			first_link = Some(made.room_link.clone());
			created = Some(made);
		}
	}
	let manager = match &created {
		Some(made) => Some(owner.enliven(&made.manager_link).await.unwrap()),
		None => None,
	};
	// The entrance an asker holds is taken before anything changes.
	let entrance = match row.asker {
		Asker::Entrance(holder) | Asker::Link(holder) => {
			let entrance = if matches!(row.asker, Asker::Link(_)) {
				stranger.enliven(first_link.as_deref().unwrap()).await.unwrap()
			} else {
				stranger_directory.enter("Salon").await.unwrap()
			};
			if matches!(holder, Holder::SeatedThroughIt) {
				seats.push(join(stranger, entrance.clone(), "Eve").await);
			}
			Some(entrance)
		}
		Asker::Invitation(Minter::SeatedThroughTheFirstLink) => {
			let entrance = stranger.enliven(first_link.as_deref().unwrap()).await.unwrap();
			seats.push(join(stranger, entrance, "Eve").await);
			None
		}
		_ => None,
	};
	let mut remade = None;
	if let (Some(now), Some(manager)) = (row.now, &manager) {
		let [visibility, entry, speaking] = now.modes();
		owner
			.session()
			.send(
				manager,
				authority::SET_POLICY,
				&[visibility.into(), entry.into(), speaking.into(), "Salon".into()],
			)
			.await
			.unwrap();
	}
	match (row.kind, row.change) {
		(_, Change::AsOpened | Change::RecordUnwritten) => {}
		(_, Change::Forgotten) => {
			on_operator(authority::FORGET_ROOM).await;
		}
		(Kind::Plain, Change::ForgottenThenOpened(_)) => {
			on_operator(authority::ISSUE_MANAGER).await;
			on_operator(authority::FORGET_ROOM).await;
			let room = owner_directory.open("Salon").await.unwrap();
			seats.push(join(owner, room, "Owner").await);
		}
		(Kind::Managed(_), Change::ForgottenThenOpened(again)) => {
			on_operator(authority::FORGET_ROOM).await;
			let made = owner_directory.open_managed("Salon", again, &key).await.unwrap();
			seats.push(join(owner, made.room, "Owner").await);
		}
		(Kind::Plain, Change::LinkRevokedThenManagerIssued) => {
			on_operator(authority::REVOKE_ROOM_LINK).await;
			on_operator(authority::ISSUE_MANAGER).await;
		}
		(Kind::Plain, Change::LinkRevokedWithManager | Change::LinkRevokedThenManagerRevoked) => {
			on_operator(authority::ISSUE_MANAGER).await;
			on_operator(authority::REVOKE_ROOM_LINK).await;
			if matches!(row.change, Change::LinkRevokedThenManagerRevoked) {
				on_operator(authority::REVOKE_MANAGER).await;
			}
		}
		(Kind::Plain, Change::LinkRevokedNeverManaged) => {
			on_operator(authority::REVOKE_ROOM_LINK).await;
		}
		(
			Kind::Managed(_),
			Change::LinkRevokedWithManager | Change::LinkRevokedThenManagerRevoked | Change::LinkRemade,
		) => {
			let revoked = token(first_link.as_deref().unwrap());
			let manager = manager.as_ref().unwrap();
			let on_manager = |verb: &'static str, args: Vec<Argument>| {
				let owner = owner.clone();
				async move { owner.session().send(manager, verb, &args).await.unwrap() }
			};
			on_manager(authority::REVOKE_ROOM_LINK, vec![revoked.into()]).await;
			match row.change {
				Change::LinkRevokedThenManagerRevoked => {
					on_operator(authority::REVOKE_MANAGER).await;
				}
				Change::LinkRemade => {
					let made = on_manager(authority::LINK, Vec::new()).await;
					remade = Some(token(made.as_str().unwrap()));
				}
				_ => {}
			}
		}
		(kind, change) => panic!("the table holds no {kind:?} room that is {change:?}"),
	}
	if matches!(row.asker, Asker::Entrance(Holder::SeatedAsTheNameOffers)) {
		let again = stranger_directory.enter("Salon").await.unwrap();
		seats.push(join(stranger, again, "Eve").await);
	}
	let answer: Result<Argument, String> = match row.asker {
		Asker::Name => stranger_directory
			.link("Salon")
			.await
			.map(Argument::String)
			.map_err(|e| e.to_string()),
		Asker::Entrance(_) | Asker::Link(_) => stranger
			.session()
			.send(entrance.as_ref().unwrap(), authority::LINK, &[])
			.await
			.map_err(|e| e.to_string()),
		Asker::Opener => owner
			.session()
			.send(opened.as_ref().unwrap(), authority::LINK, &[])
			.await
			.map_err(|e| e.to_string()),
		Asker::Invitation(minter) => {
			let (client, seat) = match minter {
				Minter::Owner => (owner, seats.first().unwrap()),
				Minter::SeatedThroughTheFirstLink => (stranger, seats.last().unwrap()),
			};
			let invitation = seat.0.invite(MembershipKind::Participant).await.unwrap();
			let claimed = invitation.claim().await.unwrap();
			client
				.session()
				.send(&claimed, authority::LINK, &[])
				.await
				.map_err(|e| e.to_string())
		}
		Asker::Manager => owner
			.session()
			.send(manager.as_ref().unwrap(), authority::LINK, &[])
			.await
			.map_err(|e| e.to_string()),
		Asker::Key => owner_directory
			.private_link(&key)
			.await
			.map(Argument::String)
			.map_err(|e| e.to_string()),
	};
	let outcome = match answer {
		Ok(told) => {
			let link = told.as_str().unwrap().to_owned();
			if let Some(first) = first_link
				.as_deref()
				.filter(|_| !matches!(row.change, Change::AsOpened))
			{
				assert_ne!(token(&link), token(first), "a revoked link was told again");
			}
			if let Some(remade) = &remade {
				assert_eq!(&token(&link), remade, "the link told is the one the manager made");
			}
			assert!(link_posts(stranger, &link).await, "the told link does not post");
			Ok(link)
		}
		Err(refusal) => Err(refusal),
	};
	drop(seats);
	table.finish().await;
	outcome
}

#[tokio::test]
async fn who_is_told_a_rooms_link() {
	rooms_testing::local_set::run_within(Duration::from_secs(180), async {
		let mut wrong = Vec::new();
		for row in rows() {
			let asked = ask(&row).await;
			let matches = match (&row.expected, &asked) {
				(Told::Link, Ok(_)) => true,
				(Told::Refused(with), Err(refusal)) => refusal.contains(with),
				_ => false,
			};
			if !matches {
				wrong.push(format!(
					"{:?} now={:?} {:?} {:?}: expected {:?}, answered {:?}",
					row.kind, row.now, row.change, row.asker, row.expected, asked
				));
			}
		}
		assert!(
			wrong.is_empty(),
			"{} rows answer wrongly:\n{}",
			wrong.len(),
			wrong.join("\n")
		);
	})
	.await;
}
