//! The harness the room policy tests share: a world holding live rooms, a
//! directory, and an authority, with the argument views the verbs read.
use super::*;

pub(super) type Dir = Directory<u32, &'static str>;
pub(super) type Live = Rooms<u32, &'static str>;

pub(super) fn authority() -> Authority {
	Authority::read(&Document::fresh([1; 32], [2; 32])).unwrap()
}
pub(super) fn id(n: u32) -> Id {
	Id::parse(&format!("{n:08x}-0000-4000-8000-000000000000")).unwrap()
}
pub(super) fn fresh(n: u32) -> entrance::Fresh {
	entrance::Fresh {
		entry_id: id(n),
		private_key: RecoveryKey::from_entropy([n as u8; 16]),
	}
}
pub(super) fn same(_: u32, _: u32) -> bool {
	false
}
pub(super) fn open(name: &str, policy: RoomPolicy) -> Open<'_> {
	Open {
		name,
		policy,
		recovery: None,
		managed: false,
	}
}

pub(super) struct World {
	pub(super) rooms: Live,
	pub(super) directory: Dir,
	pub(super) authority: Authority,
}
impl World {
	pub(super) fn new(history: bool) -> Self {
		Self {
			rooms: Rooms::new(history.then(history::Index::default), Default::default()),
			directory: Dir::default(),
			authority: authority(),
		}
	}
	/// Record a managed room under `id`, as its manager bootstrap does.
	pub(super) fn register(&mut self, id: &str, name: &str, policy: RoomPolicy) {
		let registration = crate::server::links::Registration { name, policy };
		self.authority = self
			.authority
			.remembered(id, false, true, Some(registration))
			.unwrap()
			.unwrap();
	}
	pub(super) fn open(&mut self, c: u32, name: &str, policy: RoomPolicy) -> Entrance {
		self.rooms
			.open(c, open(name, policy), fresh(c * 10), &self.authority)
			.unwrap()
			.entrance
	}
	pub(super) fn join(&mut self, c: u32, entrance: &Entrance, nick: &str) -> seating::Subscribed<u32, &'static str> {
		let inbox: &'static str = alloc::boxed::Box::leak(format!("{nick}-inbox").into_boxed_str());
		let seat: &'static str = alloc::boxed::Box::leak(format!("{nick}-seat").into_boxed_str());
		self.rooms
			.subscribe(
				c,
				entrance,
				nick,
				inbox,
				None,
				seat,
				Some("subject"),
				&mut self.directory,
				same,
				&self.authority,
				Some(fresh(c * 100)),
			)
			.unwrap_or_else(|refused| panic!("{}", refused.refusal))
	}
}

pub(super) fn notices<'a>(effects: &'a Effects<u32, &'static str>, connection: u32) -> Vec<&'a Notice> {
	effects
		.tells
		.iter()
		.filter(|tell| tell.connection == connection)
		.map(|tell| &tell.notice)
		.collect()
}
