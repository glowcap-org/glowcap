use super::*;
use crate::{client::Deadline, session_runtime::direct_publications::DirectPublications};
use glowcap::Argument;
use rooms_application::direct::Notice;
use rooms_glowcap::client::direct::{publisher::Publisher, receiver};
use std::{
	cell::Cell,
	future::Future,
	task::{Context, Waker},
};

async fn refused(offer: &peers::Offer) {
	use rooms_application::failure::{Failure, FailureCode};
	let reason = offer.typing().await.unwrap_err().to_string();
	assert_eq!(
		Failure::parse(&reason).map(|failure| failure.code),
		Some(FailureCode::DirectNotAccepted),
		"{reason}"
	);
}

#[tokio::test]
async fn durable_acceptance_guards_actual_inboxes_across_cancellation_and_reopening() {
	tokio::task::LocalSet::new()
		.run_until(async {
			tokio::time::timeout(Duration::from_secs(15), scenario())
				.await
				.expect("direct publication deadline");
		})
		.await;
}
async fn scenario() {
	let temp = Temp(std::env::temp_dir().join(format!("rooms-runtime-publications-{}", std::process::id())));
	std::fs::create_dir(&temp.0).unwrap();
	let docs = SessionDocuments::open(&temp.0).await.unwrap().into_owners();
	drop((docs.grants, docs.bridge_secrets));
	let (commands, worker) = SessionCommands::open(docs.state, crate::client::Deadline)
		.await
		.unwrap();
	let transport = Rc::new(
		Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
			.await
			.unwrap(),
	);
	let (runtime, directories, events, mut inbox) = DirectoryRuntime::new(
		transport.clone(),
		commands.clone(),
		"ocapn://member.id".into(),
		crate::client::Deadline,
		crate::entropy::OsEntropy,
	)
	.unwrap();
	let command_task = tokio::task::spawn_local(worker.run(events));
	let directory_task = tokio::task::spawn_local(directories.run());
	let (tx, mut arrivals) = mpsc::channel(4);
	let mut first = peers::Peer::start(10, tx.clone()).await;
	let mut second = peers::Peer::start(11, tx).await;
	for (index, peer) in [(10, &first), (11, &second)] {
		let locator = peer.locator();
		command(
			&commands,
			&format!("join-{index}"),
			Command::JoinDirectory,
			vec![
				json!({"id":CheckpointRoutes.locator_authority(&locator).unwrap(), "locator":locator,
			"nick":"alice", "home":index==10, "standing":null})
				.to_string()
				.into(),
			],
		)
		.await;
	}
	let a = arrivals.recv().await.unwrap();
	let b = arrivals.recv().await.unwrap();
	a.ack().await;
	b.ack().await;
	until(&runtime, |r| r.rows().iter().all(|row| row.phase() == Phase::Connected)).await;
	let (a, b) = if a.index == 10 { (a, b) } else { (b, a) };
	a.notify("mintInboxFor").await;
	let work = inbox.next().await.unwrap();
	let publisher = Publisher::new(transport.host().clone(), Deadline).unwrap();
	let made = Rc::new(Cell::new(0));
	let deliveries = Rc::new(Cell::new(0));
	let (lines, mut messages) = crate::session_runtime::direct_events::DirectEvents::new(
		crate::client::Deadline,
		&mut crate::entropy::OsEntropy,
	)
	.unwrap();
	let delivery = lines.receiver();
	let routes = crate::session_runtime::direct_routes::DirectRoutes::new();
	let route_receiver = routes.receiver();
	let (factories, received) = (made.clone(), deliveries.clone());
	let publications = DirectPublications::new(publisher.clone(), move |context| {
		assert!(context.current(), "factory must follow durable acceptance");
		factories.set(factories.get() + 1);
		let received = received.clone();
		let lines = delivery.clone();
		let routes = route_receiver.clone();
		Ok(Box::new(receiver(move |notice, session| match notice {
			Notice::Typing(true) => {
				received.set(received.get() + 1);
				Ok(Argument::Void)
			}
			Notice::Message {
				text,
				attachments,
				reply,
			} => {
				let client = rooms_glowcap::client::Client::new(session, Deadline);
				if let Some(reply) = reply {
					routes.adopt(&context, client.clone(), reply)?;
				}
				lines
					.post(context.clone(), client.session(), text, attachments)
					.map(Argument::Reference)
			}
			Notice::Ready(reply) => {
				routes.adopt(&context, rooms_glowcap::client::Client::new(session, Deadline), reply)?;
				Ok(Argument::Void)
			}
			_ => panic!("this fixture exercises messages, reciprocal routes and typing"),
		})))
	});
	admission(&publications, &runtime, &work).await;
	let accepted = publications.offer(&runtime, &work).await.unwrap();
	let old = first.offers.recv().await.unwrap();
	factory_retirement(&publisher, &runtime, &work).await;
	assert!(
		first.offers.try_recv().is_err(),
		"a retired factory must not offer an alias"
	);
	old.typing().await.unwrap();
	assert_eq!(deliveries.get(), 1);
	publications.offer(&runtime, &work).await.unwrap();
	let repeated = first.offers.recv().await.unwrap();
	assert_eq!(old.inbox, repeated.inbox);
	assert_eq!(made.get(), 1);
	assert_eq!(publisher.held(), 1);
	let directory = runtime.direct_directory(&accepted).unwrap();
	let spare = Vec::with_capacity(
		crate::session_runtime::direct_events::EVENT_BYTES
			/ core::mem::size_of::<rooms_application::room::attachment::Attachment<glowcap::Ref>>()
			+ 1,
	);
	assert!(
		lines
			.receiver()
			.post(accepted.clone(), directory.client().session(), "", spare)
			.is_err(),
		"retained spare capacity spends the event budget"
	);
	let posted = old.session.send(&old.inbox, "dm", &["hello".into()]).await.unwrap();
	let Argument::Reference(posted) = posted else {
		panic!("direct posted line")
	};
	let said = messages.next().await.unwrap();
	assert_eq!(said.line().unwrap().text, "hello");
	assert_eq!(said.context.conversation(), accepted.conversation());
	old.session.send(&posted, "edit", &["edited".into()]).await.unwrap();
	let edited = messages.next().await.unwrap();
	assert_eq!(edited.line().unwrap().line, said.line().unwrap().line);
	assert_eq!(edited.generation, said.generation);
	assert!(said.at > 0);
	assert_eq!(edited.line().unwrap().text, "edited");
	assert_eq!(
		edited.line().unwrap().kind,
		rooms_application::room::message::ChangeKind::Edited
	);
	super::lines::exercise(&runtime, &accepted, &old, &posted, &mut messages).await;
	let mut reciprocal = super::routes::exercise(&routes, &accepted, &old, &mut messages).await;
	let Argument::Reference(live_line) = old.session.send(&old.inbox, "dm", &["last".into()]).await.unwrap() else {
		panic!("last line")
	};
	lines.close();
	assert!(old
		.session
		.send(&live_line, "edit", &["after close".into()])
		.await
		.is_err());
	assert_eq!(
		messages.next().await.unwrap().line().unwrap().text,
		"last",
		"admitted events drain after close"
	);
	assert!(messages.next().await.is_none());
	// An independent directory may use the same registration ID without sharing
	// its conversation, actor, or retirement with the first directory.
	b.notify("mintInboxFor").await;
	let other = inbox.next().await.unwrap();
	let sibling = publications.offer(&runtime, &other).await.unwrap();
	let sibling_offer = second.offers.recv().await.unwrap();
	let mut sibling_route = super::routes::install(&sibling_offer).await;
	routes.say(&sibling, "independent").await.unwrap();
	assert_eq!(sibling_route.messages.recv().await.unwrap(), "independent");
	super::routes::independent(&routes, &accepted, &sibling, &mut reciprocal, &mut sibling_route).await;
	assert_ne!(sibling.conversation(), accepted.conversation());
	assert_eq!(publisher.held(), 2);
	first.delay_offer.set(true);
	let mut pending = Box::pin(publications.offer(&runtime, &work));
	let mut held = tokio::select! { offer = first.offers.recv() => offer.unwrap(), _ = &mut pending => panic!("offer acknowledged early") };
	assert_eq!(publications.pending(), 1);
	publications.offer(&runtime, &other).await.unwrap();
	let independent = second.offers.recv().await.unwrap();
	assert_eq!(independent.inbox, sibling_offer.inbox);
	publications.offer(&runtime, &work).await.unwrap();
	let duplicate = first.offers.recv().await.unwrap();
	assert_eq!(duplicate.inbox, old.inbox);
	assert_eq!(
		made.get(),
		2,
		"concurrent duplicates must not construct another receiver"
	);
	assert_eq!(publications.pending(), 1);
	drop(pending);
	assert_eq!(publications.pending(), 0);
	assert_eq!(publisher.held(), 2, "cancelled observation retains its publication");
	command(
		&commands,
		"close",
		Command::CloseDirect,
		vec![accepted.conversation().text().clone()],
	)
	.await;
	refused(&old).await;
	assert!(routes.say(&accepted, "retired").await.is_err());
	routes.reconcile();
	assert!(!routes.live(&accepted));
	routes.say(&sibling, "survives").await.unwrap();
	assert_eq!(sibling_route.messages.recv().await.unwrap(), "survives");
	assert!(reciprocal.messages.try_recv().is_err());
	assert!(old.session.send(&posted, "edit", &["late".into()]).await.is_err());
	assert_eq!(deliveries.get(), 1);
	sibling_offer.typing().await.unwrap();
	publications.reconcile().await.unwrap();
	assert_eq!(publisher.held(), 1);
	held.answer.as_mut().unwrap().fulfill(&Argument::Void).unwrap();
	assert!(held.typing().await.is_err());
	let reopened = publications.offer(&runtime, &work).await.unwrap();
	assert!(!reopened.same_context(&accepted));
	assert_eq!(reopened.conversation(), accepted.conversation());
	let new = first.offers.recv().await.unwrap();
	assert_ne!(new.inbox, old.inbox);
	new.typing().await.unwrap();
	assert!(old.typing().await.is_err());
	assert_eq!(made.get(), 3);
	// Retirement during the publisher's outside-turn yield refuses construction
	// before publishing an alias, even though acceptance had already completed.
	let late = DirectPublications::new(publisher.clone(), |_| panic!("retired factory must not run"));
	let mut pending = Box::pin(late.offer(&runtime, &work));
	for _ in 0..2 {
		assert!(pending
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending());
	}
	command(
		&commands,
		"close-before-factory",
		Command::CloseDirect,
		vec![reopened.conversation().text().clone()],
	)
	.await;
	assert!(pending.await.is_err());
	assert!(first.offers.try_recv().is_err());
	assert_eq!(
		publisher.held(),
		2,
		"refused factory must release its provisional alias"
	);
	publications.reconcile().await.unwrap();
	assert_eq!(publisher.held(), 1);
	late.close().await.unwrap();
	publications.offer(&runtime, &work).await.unwrap();
	let final_offer = first.offers.recv().await.unwrap();
	final_offer.typing().await.unwrap();
	first.delay_offer.set(true);
	let mut in_flight = Box::pin(publications.offer(&runtime, &work));
	let mut closing_offer = tokio::select! {
		offer = first.offers.recv() => offer.unwrap(),
		_ = &mut in_flight => panic!("shutdown offer answered early"),
	};
	// Closing withdraws all contexts synchronously; cancellation during cleanup
	// cannot restore authority or release native alias capacity prematurely.
	let mut close = Box::pin(publications.close());
	assert!(close
		.as_mut()
		.poll(&mut Context::from_waker(Waker::noop()))
		.is_pending());
	assert!(new.typing().await.is_err());
	refused(&final_offer).await;
	refused(&closing_offer).await;
	closing_offer.answer.as_mut().unwrap().fulfill(&Argument::Void).unwrap();
	assert!(
		in_flight.await.is_err(),
		"late offer acknowledgement must not revive publication"
	);
	assert!(sibling_offer.typing().await.is_err());
	drop(close);
	assert_eq!(
		publisher.held(),
		2,
		"native aliases remain charged until cleanup resumes"
	);
	publications.close().await.unwrap();
	assert_eq!(publisher.held(), 0);
	assert!(publications.offer(&runtime, &work).await.is_err());
	super::routes::close_pending(&routes, &sibling, &sibling_offer, &mut sibling_route).await;
	runtime.close().await.unwrap();
	directory_task.await.unwrap().unwrap();
	commands.close().await.unwrap();
	command_task.await.unwrap().unwrap();
	drop((
		publications,
		late,
		publisher,
		old,
		repeated,
		held,
		new,
		final_offer,
		sibling_offer,
	));
	transport.close(PendingWork::Cancel).await.unwrap();
	first.close().await;
	second.close().await;
}

async fn admission(publications: &DirectPublications, runtime: &DirectoryRuntime, work: &RegistrationWork) {
	let mut held = Vec::new();
	for _ in 0..crate::session_runtime::direct_publications::OFFER_LIMIT {
		let mut offer = Box::pin(publications.offer(runtime, work));
		assert!(offer
			.as_mut()
			.poll(&mut Context::from_waker(Waker::noop()))
			.is_pending());
		held.push(offer);
	}
	assert!(publications.offer(runtime, work).await.is_err());
	assert_eq!(publications.pending(), held.len());
	held.pop();
	let mut admitted = Box::pin(publications.offer(runtime, work));
	assert!(admitted
		.as_mut()
		.poll(&mut Context::from_waker(Waker::noop()))
		.is_pending());
	drop((admitted, held));
	assert_eq!(publications.pending(), 0, "cancellation returns admission capacity");
}

async fn factory_retirement(publisher: &Publisher<Deadline>, runtime: &DirectoryRuntime, work: &RegistrationWork) {
	let owner = Rc::new(std::cell::RefCell::new(std::rc::Weak::<DirectPublications>::new()));
	let closing = owner.clone();
	let publications = Rc::new(DirectPublications::new(publisher.clone(), move |_| {
		closing.borrow().upgrade().unwrap().retire();
		Ok(Box::new(|_, _| panic!("retired factory behavior was published")))
	}));
	*owner.borrow_mut() = Rc::downgrade(&publications);
	let held = publisher.held();
	assert!(publications.offer(runtime, work).await.is_err());
	assert_eq!(
		publisher.held(),
		held,
		"retired factory must release its provisional slot"
	);
}
