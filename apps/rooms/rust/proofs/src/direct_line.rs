use super::arguments::{text, Arg};
use rooms_application::{
	direct::{
		event::{Content, Line as EventLine},
		line::dispatch,
	},
	room::{
		attachment::read_exact,
		line::Line,
		message::{ChangeKind, LineId},
	},
};
use std::{cell::Cell, rc::Rc};

pub fn run() {
	admission();
	let a = Rc::new(Cell::new(0));
	let b = Rc::new(Cell::new(0));
	let first = record("first", a.clone());
	let mut line = Line::new(LineId::new(1).unwrap(), "alice".into(), read_exact(&first, 0).unwrap()).unwrap();
	for args in [
		vec![],
		vec![text("bad"), Arg::Integer(-1)],
		vec![text("bad"), Arg::Float(0.0)],
		vec![text("bad"), Arg::Integer(0), Arg::Integer(0)],
		vec![text("bad"), text("file")],
		vec![text(&"x".repeat(8193))],
	] {
		assert!(dispatch(&mut line, "refile", &args).is_err());
		assert_eq!(line.files().len(), 1);
		assert!(Rc::ptr_eq(&line.files()[0].blob, &a));
		assert!(!line.is_withdrawn());
	}
	let mut args = vec![text("both"), Arg::Integer(0)];
	args.extend(record("second", b.clone()));
	let change = dispatch(&mut line, "refile", &args).unwrap().unwrap();
	assert_eq!(change.kind, ChangeKind::Refiled);
	assert_eq!(change.files.len(), 2);
	assert!(change.retired.is_empty());
	let pending = [
		Content::Typing { on: true },
		Content::Line(EventLine {
			line: change.id,
			text: change.text.into(),
			kind: change.kind,
			files: change.files.to_vec(),
		}),
		Content::Typing { on: false },
	];
	let args = [text("second only"), Arg::Integer(1)];
	let change = dispatch(&mut line, "refile", &args).unwrap().unwrap();
	assert!(Rc::ptr_eq(&change.files[0].blob, &b));
	assert!(Rc::ptr_eq(&change.retired[0].blob, &a));
	drop(change);
	let args = [text("")];
	let change = dispatch(&mut line, "refile", &args).unwrap().unwrap();
	assert_eq!(change.kind, ChangeKind::Withdrawn);
	assert!(change.files.is_empty());
	assert_eq!(change.retired.len(), 1);
	drop(change);
	assert!(dispatch::<Arg>(&mut line, "withdraw", &[]).unwrap().is_none());
	assert!(dispatch(&mut line, "edit", &[text("late")]).is_err());
	// Queued line snapshots retain their files across subsequent withdrawal;
	// typing in that same ordered stream cannot contribute an archive record.
	let archived: Vec<_> = pending.iter().filter_map(Content::line).collect();
	assert_eq!(archived.len(), 1);
	assert_eq!(archived[0].line.get(), 1);
	assert_eq!(archived[0].text, "both");
	assert_eq!(archived[0].files.len(), 2);
	assert!(Rc::ptr_eq(&archived[0].files[0].blob, &a));
	let (held_a, held_b) = (Rc::strong_count(&a), Rc::strong_count(&b));
	drop(archived);
	drop(pending);
	assert_eq!(Rc::strong_count(&a), held_a - 1);
	assert_eq!(Rc::strong_count(&b), held_b - 1);
}
fn record(name: &str, capability: Rc<Cell<usize>>) -> Vec<Arg> {
	vec![
		text("file"),
		text(name),
		text("application/octet-stream"),
		Arg::Integer(3),
		Arg::Capability(capability),
		Arg::Integer(0),
		Arg::Integer(0),
	]
}

fn admission() {
	use rooms_application::direct::line::{dispatch_with, AdmissionError};
	let a = Rc::new(Cell::new(0));
	let b = Rc::new(Cell::new(0));
	let mut line = Line::new(
		LineId::new(1).unwrap(),
		"alice".into(),
		read_exact(&record("a", a.clone()), 0).unwrap(),
	)
	.unwrap();
	let mut refile = vec![text("both"), Arg::Integer(0)];
	refile.extend(record("b", b.clone()));
	let result = dispatch_with(&mut line, "refile", &refile, |proposal| {
		assert_eq!(proposal.kind, ChangeKind::Refiled);
		assert_eq!(proposal.text, "both");
		let files = proposal.files().collect::<Vec<_>>();
		assert!(Rc::ptr_eq(&files[0].blob, &a));
		assert!(Rc::ptr_eq(&files[1].blob, &b));
		Err::<(), _>("full")
	});
	assert!(matches!(result, Err(AdmissionError::Admission("full"))));
	assert_eq!(line.files().len(), 1);
	assert!(!line.is_withdrawn());
	let invalid = [text("invalid"), Arg::Integer(1)];
	assert!(dispatch_with(&mut line, "refile", &invalid, |_| -> Result<(), ()> {
		panic!("invalid selection cannot reserve")
	})
	.is_err());
	let edit = [text("caption")];
	let (receipt, change) = dispatch_with(&mut line, "edit", &edit, |proposal| {
		assert!(Rc::ptr_eq(&proposal.files().next().unwrap().blob, &a));
		Ok::<_, ()>(7)
	})
	.unwrap()
	.unwrap();
	assert_eq!(receipt, 7);
	assert!(change.files.is_empty(), "wire edit remains a delta");
	drop(change);
	assert!(dispatch_with::<Arg, (), _>(&mut line, "withdraw", &[], |_| Err("full")).is_err());
	assert!(!line.is_withdrawn());
	assert_eq!(line.files().len(), 1);
	dispatch_with::<Arg, _, ()>(&mut line, "withdraw", &[], |proposal| {
		assert_eq!(proposal.files().count(), 0);
		Ok(())
	})
	.unwrap();
	assert!(dispatch_with::<Arg, (), ()>(&mut line, "withdraw", &[], |_| panic!(
		"idempotent withdrawal cannot reserve"
	))
	.unwrap()
	.is_none());
	// Room-hosted staged custody follows the same admission transaction.
	let mut room = Line::new(LineId::new(2).unwrap(), "alice".into(), vec![1]).unwrap();
	let mut staged = vec![2];
	assert!(room
		.dispatch_with(
			"refile",
			&[text("room"), Arg::Integer(0)],
			&mut staged,
			|_| Err::<(), _>("full")
		)
		.is_err());
	assert_eq!(room.files(), &[1]);
	assert_eq!(staged, [2]);
}
