//! One callback-context projection trace for LMDB and IndexedDB consumers.
//! Shared Zig scenarios decide selection, refusal and restart semantics.
use super::{Argument, Ref, Session};
use super::{Delivery, Invocation};

pub fn reply(input: Invocation<'_>) -> Argument {
	let resource = input.bound_resource;
	Argument::List(vec![
		Argument::Bytes(resource.id.owner.to_vec()),
		Argument::Integer(i64::from(resource.id.slot)),
		Argument::Integer(resource.id.generation.try_into().unwrap()),
		Argument::Integer(resource.kind.try_into().unwrap()),
		Argument::Bytes(resource.object.to_vec()),
		Argument::Integer(resource.revision.try_into().unwrap()),
		Argument::Bytes(input.content.to_vec()),
		Argument::Integer(input.content_revision.try_into().unwrap()),
		Argument::String(
			match input.delivery {
				Delivery::Local => "local",
				Delivery::Forwarding => "forwarding",
			}
			.into(),
		),
	])
}

// Stable owner, slot, generation, kind, resource key and content key. A tuple
// lets the browser persist the proof stamp without a serialization dependency
// in the library's shared test fixture. snapshot checks mutable revisions.
pub type Stamp = ([u8; 16], u32, u64, u64, Vec<u8>, Vec<u8>);
pub async fn snapshot(session: &Session, resource: &Ref) -> Stamp {
	// Peer-controlled lookalike metadata is ignored by this method.
	let result = session
		.send(resource, "context", &[Argument::Bytes(vec![0; 33])])
		.await
		.unwrap();
	let values = result.as_list().unwrap();
	assert_eq!(values[0].as_bytes().unwrap().len(), 16);
	assert_eq!(values[2].as_i64(), Some(1));
	assert_eq!(values[3].as_i64(), Some(1));
	assert_eq!(values[4].as_bytes().unwrap().len(), 33);
	assert!(values[5].as_i64().unwrap() > 0);
	assert_eq!(values[6].as_bytes().unwrap().len(), 33);
	assert_ne!(values[4].as_bytes(), values[6].as_bytes());
	assert!(values[7].as_i64().unwrap() > 0);
	assert_eq!(values[8].as_str(), Some("local"));
	(
		values[0].as_bytes().unwrap().try_into().unwrap(),
		values[1].as_i64().unwrap().try_into().unwrap(),
		values[2].as_i64().unwrap().try_into().unwrap(),
		values[3].as_i64().unwrap().try_into().unwrap(),
		values[4].as_bytes().unwrap().to_vec(),
		values[6].as_bytes().unwrap().to_vec(),
	)
}
pub fn same_resource(left: &Stamp, right: &Stamp) {
	assert_eq!(
		left, right,
		"bound identity is independent of the held grant and cold restoration"
	);
}
