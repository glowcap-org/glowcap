//! Bundle re-preparation preserves membership edits and never substitutes custody.
use super::*;
use rooms_application::{
	content::session::workspace::{ConnectionSelection, Operations},
	session::operations::mutation::Kind,
};
use rooms_glowcap::client::{
	Client, Error,
	workspace::{Import, OperationsSelection, Workspace},
};

fn fresh<K>(slot: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(NonZeroU64::new(slot).unwrap(), NonZeroU64::new(1).unwrap())
}

pub(super) async fn run(owner: &managed::Session<Platform>, host: &Host, source: &Ref) {
	// A local capability isolates workspace admission from a third exporter's
	// handoff routes; the surrounding bundle trace owns foreign recipe lookup.
	let target = source;
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let initial = workspace.snapshot().await.unwrap();
	let gateway_handle = custody::Coordinate {
		role: custody::Role::Operations,
		key: fresh(902),
	};
	let connection_handle = custody::Coordinate {
		role: custody::Role::IrcConnection,
		key: fresh(903),
	};
	owner.import(gateway_handle, target.clone(), None).await.unwrap();
	owner.import(connection_handle, target.clone(), None).await.unwrap();
	let mut intent = initial.intent.clone();
	intent.operations = List::new(vec![
		Operations {
			kind: Kind::IrcGateway,
			handle: gateway_handle,
			connection: None,
		},
		Operations {
			kind: Kind::IrcConnection,
			handle: connection_handle,
			connection: Some(ConnectionSelection {
				operation: rooms_application::fields::Text::new("connection".into()).unwrap(),
				gateway: gateway_handle,
				id: rooms_application::fields::Text::new("network".into()).unwrap(),
			}),
		},
	])
	.unwrap();
	owner.replace_workspace(&intent).await.unwrap();
	let original = workspace.snapshot().await.unwrap();
	host.publish("operations-selection", {
		let source = source.clone();
		let target = target.clone();
		move || Box::new(move |_, _| Ok(Argument::List(vec![source.clone().into(), target.clone().into()])))
	})
	.unwrap();
	let peer = Host::from_seed([122; 32]).unwrap();
	let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9193");
	let (dialed, accepted) = results::connect(&peer, host, &locator, gate::Gate::default()).await;
	let gateway = dialed.fetch("operations-selection").await.unwrap();
	let pair = dialed.send(&gateway, "get", &[]).await.unwrap();
	let Some([Argument::Reference(reflected), Argument::Reference(imported)]) = pair.as_list() else {
		panic!("selected authorities")
	};
	let client = Client::new(dialed, Platform::default());
	let remote = Workspace::new(client.clone(), reflected.clone());
	let selection = OperationsSelection::from_intent(&original.intent).unwrap();
	let replacement = OperationsSelection {
		operators: List::new(vec![fresh(901)]).unwrap(),
		operations: selection.operations.clone(),
	};
	let coordinate = custody::Coordinate {
		role: custody::Role::Operator,
		key: fresh(901),
	};
	let request = remote
		.prepare_operations(
			vec![Import {
				coordinate,
				reference: imported.clone(),
				uri: None,
			}],
			selection.clone(),
			replacement,
		)
		.await
		.unwrap();
	assert!(
		request.reprepare().await.is_err(),
		"unsubmitted replacement was recomposed"
	);
	let mut changed = original.intent.clone();
	changed.standing = rooms_application::fields::Text::new("intervening membership".into()).unwrap();
	owner.replace_workspace(&changed).await.unwrap();
	let outcome = request.submit().await;
	assert!(matches!(outcome, Err(Error::WorkspaceConflict)), "{outcome:?}");
	assert_eq!(
		workspace.snapshot().await.unwrap().intent,
		changed,
		"refusal changed the workspace"
	);
	{
		let mut submission = std::pin::pin!(request.submit());
		let mut context = std::task::Context::from_waker(std::task::Waker::noop());
		assert!(std::future::Future::poll(submission.as_mut(), &mut context).is_pending());
	}
	assert!(
		request.reprepare().await.is_err(),
		"uncertain replay inherited old proof of absence"
	);
	let outcome = request.submit().await;
	assert!(matches!(outcome, Err(Error::WorkspaceConflict)), "{outcome:?}");
	let replacement = request.reprepare().await.unwrap();
	assert_eq!(
		replacement.source(),
		reflected,
		"recomposition substituted admission authority"
	);
	replacement.submit().await.unwrap();
	replacement.submit().await.unwrap();
	let installed = workspace.snapshot().await.unwrap();
	assert_eq!(
		installed.intent.standing, changed.standing,
		"bundle replacement lost an intervening edit"
	);
	assert_eq!(installed.intent.operators.as_slice(), &[fresh(901)]);
	assert_eq!(
		installed.intent.operations, original.intent.operations,
		"surviving gateway lost its connection"
	);
	owner.import(coordinate, target.clone(), None).await.unwrap();
	assert!(
		request.reprepare().await.is_err(),
		"old selection overwrote a replacement bundle"
	);
	let remove = remote
		.prepare_operations(
			Vec::new(),
			OperationsSelection::from_intent(&installed.intent).unwrap(),
			OperationsSelection {
				operators: List::default(),
				operations: List::default(),
			},
		)
		.await
		.unwrap();
	remove.submit().await.unwrap();
	assert!(
		workspace.snapshot().await.unwrap().intent.operations.is_empty(),
		"retired gateway kept its connection"
	);
	assert!(
		owner.restore_custody(&[connection_handle]).await.is_err(),
		"retired connection kept live custody"
	);
	// Imported workspace inventories can contain more than a boot bundle.
	// Replacing them must fence every original selection, not truncate to six.
	let mut broad = workspace.snapshot().await.unwrap().intent;
	for slot in 1000..1007 {
		let key = fresh(slot);
		owner
			.import(
				custody::Coordinate {
					role: custody::Role::Operator,
					key,
				},
				target.clone(),
				None,
			)
			.await
			.unwrap();
		broad.operators.try_push(fresh(slot)).unwrap();
	}
	owner.replace_workspace(&broad).await.unwrap();
	let original = OperationsSelection::from_intent(&broad).unwrap();
	let replacement = OperationsSelection {
		operators: List::default(),
		operations: List::default(),
	};
	let remove = remote
		.prepare_operations(Vec::new(), original, replacement)
		.await
		.unwrap();
	remove.submit().await.unwrap();
	assert!(workspace.snapshot().await.unwrap().intent.operators.is_empty());
	let mut maximal = broad;
	maximal.operators = List::new((2000..2064).map(fresh).collect()).unwrap();
	maximal.operations = List::new(
		(3000..3064)
			.map(|slot| Operations {
				kind: Kind::IrcGateway,
				handle: custody::Coordinate {
					role: custody::Role::Operations,
					key: fresh(slot),
				},
				connection: None,
			})
			.collect(),
	)
	.unwrap();
	let selection = OperationsSelection::from_intent(&maximal).unwrap();
	let encoded = serde_json::to_string(&selection).unwrap();
	assert!(encoded.len() <= OperationsSelection::MAX_JSON_BYTES);
	assert_eq!(
		serde_json::from_str::<OperationsSelection>(&encoded).unwrap(),
		selection
	);
	owner.replace_workspace(&initial.intent).await.unwrap();
	client.session().close(PendingWork::Cancel).await.unwrap();
	accepted.close(PendingWork::Cancel).await.unwrap();
	host.unpublish("operations-selection").unwrap();
	peer.close(PendingWork::Cancel).await.unwrap();
}
