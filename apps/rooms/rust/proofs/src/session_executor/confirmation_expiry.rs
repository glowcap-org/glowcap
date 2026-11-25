//! A send whose commit confirmation misses its observation deadline: the job
//! stalls before it dispatches, and its source's release then retires it and
//! settles its receipt as for any stalled job.
use super::*;

const OPERATION: &str = "effect-unconfirmed";

pub(super) async fn run(
	host: &Host,
	root: &Ref,
	platform: &Platform,
	calls: &Cell<usize>,
	cold_args: &[Argument],
	case: &Case,
) {
	let snapshot = host.send(root, "snapshot", &[]).await.unwrap();
	let mut args = cold_args.to_vec();
	args[0] = OPERATION.into();
	args[1] = snapshot.as_list().unwrap()[0].clone();
	let intent = serde_json::to_string(&(OPERATION, args[1].as_i64().unwrap(), case.name, &case.args)).unwrap();
	let dispatched = calls.get();
	let refused = platform.refused_observations.get();
	// Every observation deadline expires at once, so the worker's first wait,
	// on the commit that installed it, is the one that stalls it.
	platform.refuse_observation.set(true);
	assert_eq!(
		mutate(host, root, "command", &args).await.unwrap().as_str(),
		Some("pending")
	);
	assert_eq!(
		finished(host, root, OPERATION, root).await.as_str(),
		Some("unknown"),
		"a job whose confirmation expired stalls with its outcome unknown"
	);
	platform.refuse_observation.set(false);
	assert_eq!(
		platform.refused_observations.get(),
		refused + 1,
		"exactly one observation expired"
	);
	for _ in 0..3 {
		environment::yield_turn().await;
	}
	assert_eq!(
		calls.get(),
		dispatched,
		"the expired observation was the commit's confirmation, because nothing dispatched"
	);
	assert!(
		recovery::inert(host, root).await.iter().any(|(id, _)| id == OPERATION),
		"a stalled job's receipt holds its place, so a sweep would release it"
	);
	recovery::forfeit(host, root, OPERATION, &intent).await;
	for _ in 0..3 {
		environment::yield_turn().await;
	}
	assert_eq!(calls.get(), dispatched, "the retired job dispatches nothing afterwards");
	assert_eq!(
		mutate(host, root, "command", &args).await.unwrap().as_str(),
		Some("unknown"),
		"a resubmission is answered from the released receipt"
	);
	assert_eq!(calls.get(), dispatched, "a resubmission after release never dispatches");
}
