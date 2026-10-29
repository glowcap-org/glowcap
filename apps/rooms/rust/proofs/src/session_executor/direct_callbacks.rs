//! Direct callbacks retain actual reciprocal and line actors through admission.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::Workspace;
use std::cell::RefCell;

pub(super) async fn run(
	host: &Host,
	exporter: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	control: &Ref,
	reciprocal: &RefCell<Option<Ref>>,
) {
	let source_key = custody::FieldKey::new(NonZeroU64::new(81).unwrap(), NonZeroU64::new(1).unwrap());
	owner
		.import(
			requests::coordinate(custody::Role::SessionAccess, 81),
			source.clone(),
			None,
		)
		.await
		.unwrap();
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let mut intent = workspace.snapshot().await.unwrap().intent;
	let workspace::Conversation::Direct(row) = &mut intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.source = Some(source_key);
	let selected = row.clone();
	owner.replace_workspace(&intent).await.unwrap();
	let mut rooms = managed::Memberships::with_kinds(managed::MembershipKinds::ROOMS);
	let report = rooms
		.reconcile(
			owner,
			&intent,
			"ocapn://member.id",
			&mut realization::Entropy::seeded(599),
			|_| panic!("a room consumer must not announce a direct route"),
		)
		.await;
	assert!(report.failures.is_empty());
	assert_eq!(report.ready, 0);
	assert!(
		reciprocal.borrow().is_none(),
		"excluded direct routes have no readiness effect"
	);
	rooms.close().await.unwrap();
	let line = host
		.spawn(|verb, args| {
			let verb = verb.ok_or("fixture requires a method")?;
			assert_eq!(verb, "read");
			assert!(args.is_empty());
			Ok("exact line".into())
		})
		.unwrap();
	let received = Rc::new(Cell::new(0));
	let origin = Rc::new(RefCell::new(None));
	let delivered_route = Rc::new(RefCell::new(None));
	let sibling_notices = Rc::new(Cell::new(0));
	let reply_route = exporter.spawn(|_, _| Ok(Argument::Void)).unwrap();
	let mut membership = owner
		.supervise_direct(&selected, &mut realization::Entropy::seeded(600), {
			let source = source.clone();
			let origin_out = origin.clone();
			let received = received.clone();
			let delivered_route = delivered_route.clone();
			let line = line.clone();
			let sibling_notices = sibling_notices.clone();
			move |verb, args, _delivering, origin| {
				assert_eq!(origin.source(), &source);
				*origin_out.borrow_mut() = Some(origin.clone());
				if verb != rooms_application::direct::DM {
					let values: Vec<_> = rooms_glowcap::values(args).collect();
					rooms_application::direct::read(verb, &values).unwrap();
					sibling_notices.set(sibling_notices.get() + 1);
					return Ok(Argument::Void);
				}
				assert_eq!(verb, rooms_application::direct::DM);
				assert_eq!(args[0].as_str(), Some("from peer"));
				let Argument::Reference(reply) = &args[1] else {
					panic!("held reciprocal route");
				};
				*delivered_route.borrow_mut() = Some(reply.clone());
				received.set(received.get() + 1);
				Ok(Argument::Reference(line.clone()))
			}
		})
		.await
		.unwrap();
	membership.ready().await.unwrap();
	let inbox = reciprocal
		.borrow()
		.as_ref()
		.expect("readiness passed exact inbox")
		.clone();
	let args = ["from peer".into(), Argument::Reference(reply_route)];
	let returned = exporter
		.send(&inbox, rooms_application::direct::DM, &args)
		.await
		.unwrap();
	let Argument::Reference(returned) = returned else {
		panic!("direct reply preserved posted line");
	};
	assert_eq!(
		exporter.send(&returned, "read", &[]).await.unwrap().as_str(),
		Some("exact line")
	);
	assert_eq!(received.get(), 1);
	assert!(delivered_route.borrow().is_some());
	let origin = origin.borrow_mut().take().unwrap();
	let edits = Rc::new(Cell::new(0));
	let mutable = owner
		.receive_line(origin.clone(), 1024, {
			let edits = edits.clone();
			move |id, memory| {
				rooms_glowcap::client::direct::received_line::behavior(
					id,
					"peer".into(),
					Vec::new(),
					|| true,
					LineChanges(edits, memory),
				)
			}
		})
		.unwrap();
	assert!(
		owner
			.receive_line(origin.clone(), 2 * 1024 * 1024 + 1, |_, _| panic!(
				"refused before allocating a line"
			))
			.is_err()
	);
	host.send(mutable.reference(), "edit", &["changed".into()])
		.await
		.unwrap();
	assert_eq!(edits.get(), 1);
	let filler = owner
		.receive_line(origin, 2 * 1024 * 1024 - 4096, |_, _| {
			Ok(Box::new(|_, _| Ok(Argument::Void)))
		})
		.unwrap();
	let mut refile = vec!["larger metadata".into()];
	for _ in 0..8 {
		refile.extend([
			"file".into(),
			"界".repeat(160).into(),
			"a".repeat(80).into(),
			1.into(),
			Argument::Reference(line.clone()),
			0.into(),
			0.into(),
		]);
	}
	assert!(
		host.send(mutable.reference(), "refile", &refile).await.is_err(),
		"refile cannot bypass aggregate metadata admission"
	);
	assert_eq!(
		edits.get(),
		1,
		"capacity refusal preserves the line and notification state"
	);
	filler.close().await.unwrap();
	host.send(mutable.reference(), "refile", &refile).await.unwrap();
	assert_eq!(
		edits.get(),
		2,
		"actual worker retirement makes the same growth admissible"
	);
	for (verb, args) in [
		(
			rooms_application::direct::READY,
			vec![Argument::Reference(returned.clone())],
		),
		(rooms_application::direct::TYPING, vec![true.into()]),
		(
			rooms_application::direct::HAND_ROOM,
			vec!["room".into(), Argument::Reference(returned.clone())],
		),
		(
			rooms_application::direct::OFFER_ROOM,
			vec!["room".into(), "held link".into()],
		),
		(
			rooms_application::direct::HAND_ARCHIVE,
			vec![
				"directory".into(),
				"standing".into(),
				Argument::Void,
				Argument::Reference(returned.clone()),
			],
		),
		(
			rooms_application::direct::OFFER_ARCHIVE,
			vec![
				"directory".into(),
				"standing".into(),
				Argument::Void,
				"held link".into(),
			],
		),
	] {
		exporter.send(&inbox, verb, &args).await.unwrap();
	}
	assert_eq!(sibling_notices.get(), 6);
	publication_results::lifecycle(host, control, "pause").await;
	assert!(
		host.send(mutable.reference(), "edit", &["paused".into()])
			.await
			.is_err()
	);
	assert_eq!(edits.get(), 2, "line edits recheck the original source grant");
	assert!(
		exporter
			.send(&inbox, rooms_application::direct::DM, &args)
			.await
			.is_err()
	);
	assert_eq!(received.get(), 1, "paused original source blocks callback delivery");
	publication_results::lifecycle(host, control, "resume").await;
	host.send(mutable.reference(), "refile", &["refiled".into()])
		.await
		.unwrap();
	assert_eq!(edits.get(), 3);
	exporter
		.send(&inbox, rooms_application::direct::DM, &args)
		.await
		.unwrap();
	assert_eq!(received.get(), 2);
	// Equal authority imported at a different coordinate is still a new route.
	// Current callback admission must fence the old selection immediately. status-allow: replacement state identity
	let mut replacement = workspace.snapshot().await.unwrap().intent;
	let original = replacement.clone();
	let workspace::Conversation::Direct(row) = &mut replacement.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	let key = custody::FieldKey::new(NonZeroU64::new(82).unwrap(), NonZeroU64::new(1).unwrap());
	let held = owner
		.restore_custody(&[requests::coordinate(
			custody::Role::DirectAccess,
			row.access.unwrap().slot().get(),
		)])
		.await
		.unwrap();
	owner
		.import(
			requests::coordinate(custody::Role::DirectAccess, 82),
			held[0].clone(),
			None,
		)
		.await
		.unwrap();
	row.access = Some(key);
	owner.replace_workspace(&replacement).await.unwrap();
	assert!(
		host.send(mutable.reference(), "edit", &["retired route".into()])
			.await
			.is_err()
	);
	assert_eq!(edits.get(), 3, "line edits cannot follow replacement route custody");
	assert!(
		exporter
			.send(&inbox, rooms_application::direct::DM, &args)
			.await
			.is_err()
	);
	assert_eq!(
		received.get(),
		2,
		"replacing a held route invalidates the callback selection"
	);
	let mut intent = workspace.snapshot().await.unwrap().intent;
	let workspace::Conversation::Direct(row) = &mut intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.closed = true;
	owner.replace_workspace(&intent).await.unwrap();
	assert!(
		exporter
			.send(&inbox, rooms_application::direct::DM, &args)
			.await
			.is_err()
	);
	membership.close().await.unwrap();
	assert!(host.send(mutable.reference(), "withdraw", &[]).await.is_err());
	mutable.close().await.unwrap();
	owner.close_received_lines().await.unwrap();
	assert!(!membership.is_active());
	owner.replace_workspace(&original).await.unwrap();
	let mut intent = workspace.snapshot().await.unwrap().intent;
	let workspace::Conversation::Direct(row) = &mut intent.conversations.as_mut_slice()[0] else {
		unreachable!()
	};
	row.closed = false;
	owner.replace_workspace(&intent).await.unwrap();
	assert!(
		exporter
			.send(&inbox, rooms_application::direct::DM, &args)
			.await
			.is_err(),
		"retired actor cannot revive with intent"
	);
	super::activity_direct::run(host, exporter, owner, source, control, reciprocal).await;
	super::direct_routes::run(host, owner, source).await;
}

struct LineChanges(Rc<Cell<usize>>, managed::LineMemory);
impl rooms_glowcap::client::direct::received_line::Changes for LineChanges {
	type Reservation = managed::LineResize;
	fn reserve(
		&mut self,
		proposal: rooms_application::room::line::Proposal<'_, rooms_application::room::attachment::Attachment<Ref>>,
	) -> core::result::Result<Self::Reservation, String> {
		let bytes = proposal
			.files()
			.map(|file| {
				size_of::<rooms_application::room::attachment::Attachment<Ref>>() + file.description.retained_bytes()
			})
			.sum::<usize>();
		self.1.prepare(bytes).map_err(|e| e.to_string())
	}
	fn commit(
		&mut self,
		reservation: Self::Reservation,
		_: rooms_application::room::line::LineChange<'_, '_, rooms_application::room::attachment::Attachment<Ref>>,
	) {
		reservation.commit();
		self.0.set(self.0.get() + 1);
	}
}
