//! Live workers hold initiating session authority and immutable field selections.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::{EffectStatus, Workspace};

pub(super) async fn directory(
	host: &Host,
	local: &glowcap::Session,
	owner: &managed::Session<Platform>,
	authority: (&Ref, &Ref, &Ref, &Ref),
	intent: &mut Intent,
	count: &Cell<usize>,
	platform: &Platform,
) {
	let (root, source, control, replacement) = authority;
	let original_inbox = intent.directories.as_slice()[0].inbox.unwrap();
	let original_coordinate = custody::Coordinate {
		role: custody::Role::DirectoryInbox,
		key: custody::FieldKey::new(original_inbox.slot(), original_inbox.generation()),
	};
	let original_callback = owner.restore_custody(&[original_coordinate]).await.unwrap().remove(0);
	assert!(owner.directory_source(&intent.directories.as_slice()[0]).await.is_err());
	owner
		.import(
			requests::coordinate(custody::Role::SessionAccess, 7),
			source.clone(),
			None,
		)
		.await
		.unwrap();
	intent.directories.as_mut_slice()[0].source = Some(custody::FieldKey::new(
		NonZeroU64::new(7).unwrap(),
		NonZeroU64::new(1).unwrap(),
	));
	owner.replace_workspace(intent).await.unwrap();
	super::discovery::run(host, owner, source, control, replacement).await;
	let checked = Workspace::local(host.clone(), Platform::default(), source.clone());
	let mut installed = intent.clone();
	let inbox_key = custody::FieldKey::new(NonZeroU64::new(21).unwrap(), NonZeroU64::new(1).unwrap());
	installed.directories.as_mut_slice()[0].inbox = Some(inbox_key);
	let selection = workspace::InboxSelection::directory(&installed.directories.as_slice()[0]).unwrap();
	let delivered = Rc::new(Cell::new(0));
	let mut inbox = owner
		.inbox(selection.clone(), {
			let delivered = delivered.clone();
			move |_| {
				delivered.set(delivered.get() + 1);
				Ok(())
			}
		})
		.await
		.unwrap();
	assert!(
		host.send(inbox.reference(), "notify", &[]).await.is_err(),
		"callback refuses before atomic installation"
	);
	let installation = checked
		.prepare_acquisition(
			checked.snapshot().await.unwrap().revision,
			vec![rooms_glowcap::client::workspace::Import {
				coordinate: requests::coordinate(custody::Role::DirectoryInbox, 21),
				reference: inbox.reference().clone(),
				uri: None,
			}],
			&[],
			&installed,
		)
		.unwrap();
	installation.submit().await.unwrap();
	installation.submit().await.unwrap();
	host.send(inbox.reference(), "notify", &[]).await.unwrap();
	assert_eq!(delivered.get(), 1);
	let worker = owner
		.directory_source(&installed.directories.as_slice()[0])
		.await
		.unwrap();
	checked.check_inbox(&selection, inbox.reference()).await.unwrap();
	let mut impostor = owner
		.inbox(selection.clone(), |_| panic!("uninstalled actor reached its handler"))
		.await
		.unwrap();
	assert!(
		host.send(impostor.reference(), "notify", &[]).await.is_err(),
		"selection alone cannot install a callback"
	);
	impostor.close().await.unwrap();
	assert!(
		Workspace::local(host.clone(), Platform::default(), root.clone())
			.check_inbox(&selection, inbox.reference())
			.await
			.is_err()
	);
	let operation = worker
		.register("worker-registration", "ocapn://member.id", inbox_key)
		.await
		.unwrap();
	assert_eq!(operation.source(), source, "no private-root substitution");
	publication_results::lifecycle(host, control, "pause").await;
	assert!(checked.check_inbox(&selection, inbox.reference()).await.is_err());
	assert!(host.send(inbox.reference(), "notify", &[]).await.is_err());
	assert_eq!(delivered.get(), 1);
	assert!(operation.submit().await.is_err());
	assert!(
		worker
			.register("paused-worker", "ocapn://member.id", inbox_key)
			.await
			.is_err()
	);
	assert_eq!(count.get(), 0, "paused worker invokes no directory");
	publication_results::lifecycle(host, control, "resume").await;
	assert_eq!(operation.submit().await.unwrap(), EffectStatus::Pending);
	assert_eq!(
		finished(host, source, operation.operation(), source).await.as_str(),
		Some("committed")
	);
	let destination = custody::FieldKey::new(NonZeroU64::new(11).unwrap(), NonZeroU64::new(1).unwrap());
	let acquisition = worker.acquire_registration(&operation, destination).await.unwrap();
	acquisition.submit().await.unwrap();
	acquisition.submit().await.unwrap();
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let acquired = workspace.snapshot().await.unwrap();
	assert_eq!(acquired.intent.directories.as_slice()[0].name, Some(destination));
	assert_eq!(count.get(), 1, "result retry cannot register again");
	checked.check_inbox(&selection, inbox.reference()).await.unwrap();
	host.send(inbox.reference(), "notify", &[]).await.unwrap();
	assert_eq!(
		delivered.get(),
		2,
		"registration result does not retire its installed callback"
	);
	local.tell(inbox.reference(), "notify", &[]).unwrap();
	while delivered.get() != 3 {
		environment::yield_turn().await;
	}
	assert!(
		worker.acquire_registration(&operation, destination).await.is_err(),
		"old field selection retires"
	);
	let newer = owner
		.directory_source(&acquired.intent.directories.as_slice()[0])
		.await
		.unwrap();
	assert!(
		newer.acquire_registration(&operation, destination).await.is_err(),
		"new worker rejects old operation"
	);
	let mut replaced = acquired.intent.clone();
	replaced.directories.as_mut_slice()[0].inbox = None;
	owner.replace_workspace(&replaced).await.unwrap();
	assert!(
		checked.check_inbox(&selection, inbox.reference()).await.is_err(),
		"retired callbacks cannot use receipt-held inbox custody"
	);
	assert!(host.send(inbox.reference(), "notify", &[]).await.is_err());
	assert_eq!(delivered.get(), 3);
	owner.replace_workspace(&acquired.intent).await.unwrap();
	// Admission waits retain one in-flight input while the bounded queue fills.
	// Closing must cancel that wait and settle every queued call before returning.
	platform.observation_suspended.set(true);
	let mut pending = vec![host.send(inbox.reference(), "notify", &[])];
	environment::yield_turn().await;
	for _ in 0..16 {
		pending.push(host.send(inbox.reference(), "notify", &[]));
	}
	assert!(
		host.send(inbox.reference(), "notify", &[]).await.is_err(),
		"full inbox refuses admission"
	);
	inbox.close().await.unwrap();
	for call in pending {
		assert!(call.await.is_err(), "close drains every admitted answer");
	}
	assert_eq!(delivered.get(), 3, "closing dispatches no queued notice");
	platform.observation_suspended.set(false);
	// Replacement retired the original inbox occurrence. Keep the continuing
	// source, but do not select that released callback in the next candidate.
	intent.directories.as_mut_slice()[0].inbox = None;
	// Retire the test name through public authority, preserving the initiating
	// source for the containing executor scenario.
	let retirement = workspace
		.prepare_acquisition(
			workspace.snapshot().await.unwrap().revision,
			Vec::new(),
			&[requests::coordinate(custody::Role::DirectoryName, 11)],
			intent,
		)
		.unwrap();
	retirement.submit().await.unwrap();
	owner
		.import(original_coordinate, original_callback, None)
		.await
		.unwrap();
	intent.directories.as_mut_slice()[0].inbox = Some(original_inbox);
	owner.replace_workspace(intent).await.unwrap();
	inbox.close().await.unwrap();
	assert!(host.send(inbox.reference(), "notify", &[]).await.is_err());
	supervised_directory(host, owner, source, control, intent, count).await;
	super::directory_coordination::run(host, owner, source, intent, count).await;
}

pub(super) struct Entropy(u64);
impl Entropy {
	pub(super) fn new() -> Self {
		Self(100)
	}
	pub(super) fn seeded(seed: u64) -> Self {
		Self(seed)
	}
}
impl rooms_runtime::entropy::Entropy for Entropy {
	fn fill(&mut self, bytes: &mut [u8]) -> core::result::Result<(), rooms_runtime::entropy::EntropyUnavailable> {
		self.0 += 1;
		for (index, byte) in bytes.iter_mut().enumerate() {
			*byte = (self.0 + index as u64) as u8;
		}
		Ok(())
	}
}
async fn supervised_directory(
	host: &Host,
	owner: &managed::Session<Platform>,
	source: &Ref,
	control: &Ref,
	intent: &Intent,
	count: &Cell<usize>,
) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let received = Rc::new(Cell::new(0));
	let prior = count.get();
	let original_selection = workspace::InboxSelection::directory(&intent.directories.as_slice()[0]).unwrap();
	let original = owner
		.restore_custody(&[original_selection.coordinate()])
		.await
		.unwrap()
		.remove(0);
	let mut live = owner
		.supervise_directory(
			&intent.directories.as_slice()[0],
			"ocapn://member.id",
			&mut Entropy::new(),
			{
				let received = received.clone();
				move |_, _| {
					received.set(received.get() + 1);
					Ok(())
				}
			},
		)
		.await
		.unwrap();
	live.ready().await.unwrap();
	live.ready().await.unwrap();
	assert_eq!(count.get(), prior + 1, "readiness cannot repeat registration");
	let installed = workspace.snapshot().await.unwrap();
	let row = &installed.intent.directories.as_slice()[0];
	assert!(row.name.is_some());
	assert_ne!(row.inbox, intent.directories.as_slice()[0].inbox);
	let selected = workspace::InboxSelection::directory(row).unwrap();
	let callback = owner.restore_custody(&[selected.coordinate()]).await.unwrap().remove(0);
	host.send(&callback, "notify", &[]).await.unwrap();
	assert_eq!(received.get(), 1);
	publication_results::lifecycle(host, control, "pause").await;
	assert!(host.send(&callback, "notify", &[]).await.is_err());
	publication_results::lifecycle(host, control, "resume").await;
	host.send(&callback, "notify", &[]).await.unwrap();
	assert_eq!(received.get(), 2);
	// Removing the original selection retires the worker without a timer.
	owner
		.import(original_selection.coordinate(), original, None)
		.await
		.unwrap();
	let name = row.name.unwrap();
	workspace
		.prepare_acquisition(
			workspace.snapshot().await.unwrap().revision,
			Vec::new(),
			&[
				selected.coordinate(),
				custody::Coordinate {
					role: custody::Role::DirectoryName,
					key: custody::FieldKey::new(name.slot(), name.generation()),
				},
			],
			intent,
		)
		.unwrap()
		.submit()
		.await
		.unwrap();
	live.ended().await.unwrap();
	live.close().await.unwrap();
	live.close().await.unwrap();
	assert!(host.send(&callback, "notify", &[]).await.is_err());
	assert_eq!(count.get(), prior + 1);
}
