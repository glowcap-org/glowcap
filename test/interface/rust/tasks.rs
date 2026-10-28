//! Generated Tasks creation against its real server, with independent raw reads.
#[path = "../../../apps/tasks/rust/interface.rs"]
mod interface;
#[path = "refusal.rs"]
mod refusal;
use glowcap::{Argument, ConnectOptions, PendingWork, Ref, Runtime, RuntimeConfig, Session, tcp};
use std::rc::Rc;

async fn call(session: &Session, target: &Ref, verb: &str, args: &[Argument]) -> Argument {
	session.send(target, verb, args).await.expect("raw call failed")
}

pub async fn run(port: u16, name: &str) {
	let runtime = Runtime::open(RuntimeConfig::providers([tcp::provider(Default::default())]))
		.await
		.unwrap();
	let session = Rc::new(
		runtime
			.connect(&tcp::locator("127.0.0.1", port), ConnectOptions::default())
			.await
			.unwrap(),
	);
	let root = session.fetch(name).await.unwrap();
	let list = Ref::try_from(&call(&session, &root, "list", &[0i64.into()]).await).unwrap();
	assert!(matches!(
		interface::prepare_add(session.clone(), list.clone(), ""),
		Err(interface::Error::InvalidArgument)
	));
	let mut text = "write tests".to_owned();
	let preparation = interface::prepare_add(session.clone(), list.clone(), &text).unwrap();
	// Preparation already owns its snapshot before sequence observation runs.
	text.clear();
	text.push_str("changed after preparation");
	drop(text);
	let request = preparation.await.unwrap();
	let pending = request.submit();
	assert!(matches!(Argument::from(pending.raw()), Argument::Promise(_)));
	let pipelined = session.send(pending.raw(), "text", &[]);
	let first = pending.await.unwrap();
	assert_eq!(pipelined.await.unwrap().as_str(), Some("write tests"));
	let replay = request.submit().await.unwrap();
	assert_eq!(call(&session, &replay, "text", &[]).await.as_str(), Some("write tests"));
	assert_eq!(call(&session, &first, "text", &[]).await.as_str(), Some("write tests"));
	assert_eq!(call(&session, &list, "count", &[]).await.as_i64(), Some(1));
	drop(request);
	let maximum = "é".repeat(2048);
	let created = interface::add(session.clone(), list.clone(), &maximum).await.unwrap();
	assert_eq!(
		call(&session, &created, "text", &[]).await.as_str(),
		Some(maximum.as_str())
	);
	let oversized = "é".repeat(2049);
	assert!(matches!(
		interface::prepare_add(session.clone(), list.clone(), &oversized),
		Err(interface::Error::InvalidArgument)
	));
	assert_eq!(call(&session, &list, "count", &[]).await.as_i64(), Some(2));
	session.close(PendingWork::Cancel).await.unwrap();
	runtime.close(PendingWork::Cancel).await.unwrap();
	refusal::run().await;
}
