use rooms_application::{room::handoff::*, session::checkpoint::reconciliation::Id};
use std::{cell::Cell, rc::Rc};
fn id(value: &str) -> Id {
	Id::new(value.into()).unwrap()
}
fn view(index: usize) -> View {
	View {
		id: id(&format!("handed-{index}")),
		directory: id("directory"),
		label: rooms_application::fields::Text::new("private".into()).unwrap(),
		from: rooms_application::fields::Text::new("peer".into()).unwrap(),
	}
}
struct Resource(Rc<Cell<usize>>);
impl Drop for Resource {
	fn drop(&mut self) {
		self.0.set(self.0.get() + 1);
	}
}
pub fn run() {
	let drops = Rc::new(Cell::new(0));
	let mut rooms = Handoffs::default();
	for index in 0..LIMIT {
		rooms.receive(view(index), Resource(drops.clone()), 0).unwrap();
	}
	assert_eq!(
		rooms.receive(view(0), Resource(drops.clone()), 0),
		Err(Error::Duplicate)
	);
	assert_eq!(rooms.receive(view(LIMIT), Resource(drops.clone()), 0), Err(Error::Full));
	let attempt = rooms.begin(&id("handed-0")).unwrap();
	assert!(matches!(rooms.begin(&id("handed-0")), Err(Error::Busy)));
	assert!(rooms.remove(&id("handed-0")));
	assert!(!attempt.held().current());
	assert_eq!(
		drops.get(),
		2,
		"removal cannot release a resource still owned by acceptance"
	);
	assert_eq!(rooms.receive(view(LIMIT), Resource(drops.clone()), 0), Err(Error::Full));
	drop(attempt);
	assert_eq!(drops.get(), 4);
	rooms.receive(view(LIMIT), Resource(drops.clone()), 0).unwrap();
	let attempt = rooms.begin(&id("handed-1")).unwrap();
	drop(attempt);
	let attempt = rooms.begin(&id("handed-1")).unwrap();
	rooms.close();
	assert!(!attempt.held().current());
	assert_eq!(rooms.rows().len(), 0);
	assert_eq!(rooms.receive(view(100), Resource(drops.clone()), 0), Err(Error::Closed));
	drop(attempt);
	assert_eq!(drops.get(), LIMIT + 5);

	let mut rooms = Handoffs::default();
	assert_eq!(rooms.receive(view(0), (), BYTES), Err(Error::Full));
	rooms.receive(view(0), (), BYTES / 2).unwrap();
	assert_eq!(rooms.receive(view(1), (), BYTES / 2), Err(Error::Full));
	let attempt = rooms.begin(&id("handed-0")).unwrap();
	rooms.remove(&id("handed-0"));
	assert_eq!(rooms.receive(view(1), (), BYTES / 2), Err(Error::Full));
	drop(attempt);
	rooms.receive(view(1), (), BYTES / 2).unwrap();
	assert!(rooms.retain(|row| row.view().directory != id("directory")));
	assert!(!rooms.retain(|_| false));
	rooms.receive(view(2), (), 0).unwrap();
	let old = rooms.begin(&id("handed-2")).unwrap();
	rooms.remove(&id("handed-2"));
	rooms.receive(view(2), (), 0).unwrap();
	assert!(
		!rooms.complete(&old),
		"a late completion must not retire a replacement occurrence"
	);
	let current = rooms.begin(&id("handed-2")).unwrap();
	assert!(rooms.complete(&current));
	drop((old, current));

	let mut spare = String::with_capacity(BYTES);
	spare.push('x');
	let mut large = view(2);
	large.label = rooms_application::fields::Text::new(spare.into()).unwrap();
	assert_eq!(
		rooms.receive(large, (), 0),
		Err(Error::Full),
		"charge capacity, not only text length"
	);
}
