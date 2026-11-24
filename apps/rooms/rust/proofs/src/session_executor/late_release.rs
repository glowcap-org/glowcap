//! A send dispatched before its worker stopped, which its source releases:
//! the release retires the paused executor and settles the receipt as given
//! up, and a resubmission of the operation is answered from the receipt.
use super::*;

pub(super) async fn run(
	host: &Host,
	root: &Ref,
	other: &Ref,
	platform: &Platform,
	calls: &Cell<usize>,
	cold_args: &[Argument],
	case: &Case,
) {
	// A dispatched send whose worker stops while it observes leaves its
	// execution with a paused executor. The release retires it, and its
	// observation, still held, finds no worker to settle once it lifts.
	let snapshot = host.send(root, "snapshot", &[]).await.unwrap();
	let mut late_args = cold_args.to_vec();
	late_args[0] = "effect-late".into();
	late_args[1] = snapshot.as_list().unwrap()[0].clone();
	let late_intent =
		serde_json::to_string(&("effect-late", late_args[1].as_i64().unwrap(), case.name, &case.args)).unwrap();
	// The first worker stops before it polls. Once the receipt's
	// commit is confirmed, the source resumes it with observation
	// held, so it dispatches and then waits on its observation.
	platform.suspended.set(true);
	assert!(mutate(host, root, "command", &late_args).await.is_ok());
	platform.tasks.borrow().last().unwrap().abort();
	platform.suspended.set(false);
	host.send(root, "snapshot", &[]).await.unwrap();
	platform.observation_suspended.set(true);
	assert_eq!(
		host.send(
			root,
			"resume-effect",
			&["effect-late".into(), late_intent.as_str().into()]
		)
		.await
		.unwrap()
		.as_str(),
		Some("pending")
	);
	while calls.get() == 3 {
		environment::yield_turn().await;
	}
	platform.tasks.borrow().last().unwrap().abort();
	for _ in 0..3 {
		tokio::task::yield_now().await;
	}
	recovery::forfeit(host, root, "effect-late", &late_intent).await;
	platform.observation_suspended.set(false);
	for _ in 0..3 {
		environment::yield_turn().await;
	}
	recovery::given_up(host, root, "effect-late").await;
	assert_eq!(calls.get(), 4, "lifting the held observation dispatched nothing again");
	// The released receipt answers a resubmission of its operation at
	// its base and dispatches nothing, and another access is told the
	// operation is not its own.
	assert_eq!(
		mutate(host, root, "command", &late_args).await.unwrap().as_str(),
		Some("unknown"),
		"a resubmission is answered from the released receipt"
	);
	assert_eq!(calls.get(), 4, "a resubmission after release never dispatches");
	assert_eq!(
		host.send(other, "effect-holder", &["effect-late".into()])
			.await
			.unwrap(),
		Argument::String("another".into()),
		"a released receipt is still not another access's"
	);
	assert!(
		recovery::inert(host, root)
			.await
			.iter()
			.all(|(id, _)| id != "effect-late"),
		"a released receipt holds no place a sweep would release"
	);
}
