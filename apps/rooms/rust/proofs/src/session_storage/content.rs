//! Real session payloads and held fields pass through the shared graph callback.
use glowcap::{
	Argument, Ref, Result,
	loam::{
		self, Call, Content, Graph, Invocation, Method, PageSchema, ReferenceRequest, Registration, Requirement, Retry,
	},
};
use rooms_application::{
	content::session::{
		custody::{self, Held, Retained, RetainedField},
		records, workspace,
	},
	fields::{List, Text},
};
use serde_json::json;
use std::{cell::Cell, num::NonZeroU64, rc::Rc};

pub const FIELDS: usize = records::FIELDS_PER_PAGE * 2 + 1;
pub struct References;
macro_rules! roles {
	($($role:ident),*) => {
		impl custody::References for References { $(type $role = Ref;)* }
		fn reference<'a>(field: &Retained<'a, References>) -> &'a Ref {
			match field { $(Retained::$role(held) => &held.reference,)* }
		}
		fn restored(coordinate: custody::Coordinate, reference: Ref) -> RetainedField<References> {
			match coordinate.role { $(custody::Role::$role => RetainedField::$role(Held {
				key: custody::FieldKey::new(coordinate.key.slot(), coordinate.key.generation()), reference
			}),)* }
		}
	};
}
roles!(
	SessionAccess,
	SessionControl,
	RoomAccess,
	DirectoryAccess,
	DirectAccess,
	DirectInbox,
	ArchiveAccess,
	Operator,
	Operations,
	IrcConnection,
	Offer,
	AcceptedAccess,
	RoomControl,
	ArchiveControl,
	CreationReceipt,
	PublicationLease,
	RoomSeat,
	RoomSubject,
	RoomInbox,
	RoomFiles,
	Line,
	DirectoryName,
	DirectoryInbox,
	SourceBlob
);
fn nz(value: u64) -> NonZeroU64 {
	NonZeroU64::new(value).unwrap()
}
fn key<K>(slot: u64) -> custody::FieldKey<K> {
	custody::FieldKey::new(nz(slot), nz(1))
}

pub fn initial() -> Vec<u8> {
	records::encode_workspace(&intent(false)).unwrap().remove(0)
}
fn intent(large: bool) -> workspace::Intent {
	workspace::Intent::decode(
		&json!({
			"version": 1, "directories": [], "conversations": [], "invitations": [], "active": null,
			"standing": "", "ignored": if large { vec!["é".repeat(4096); 64] } else { Vec::new() },
			"keepHistory": true, "connection": "relay", "archive": null, "archiveControl": null,
			"operators": [], "peering": []
		})
		.to_string(),
	)
	.unwrap()
}
fn candidate(target: Ref, revision: u64) -> workspace::Record<References, ()> {
	let mut custody = custody::Custody::default();
	for slot in 1..=FIELDS as u64 {
		custody
			.insert_room_access(Held {
				key: key(slot),
				reference: target.clone(),
			})
			.unwrap();
	}
	let mut intent = intent(true);
	intent.standing = Text::new(format!("revision-{revision}").into()).unwrap();
	workspace::Record {
		binding: custody::ResourceBinding { resource: () },
		intent,
		custody,
		outgoing: Default::default(),
		bridges: Default::default(),
		effects: List::new(vec![custody::EffectReceipt {
			introduction: None,
			outgoing: None,
			adopted: false,
			operation: Text::new("saved-effect".into()).unwrap(),
			canonical_intent: Text::new(format!("{revision}{}", "x".repeat(60000)).into()).unwrap(),
			resource_generation: nz(7 + revision),
			source: Held {
				key: key(1),
				reference: target.clone(),
			},
			targets: List::new(vec![RetainedField::RoomAccess(Held {
				key: key(3),
				reference: target.clone(),
			})])
			.unwrap(),
			outcome: custody::Outcome::Committed {
				result: Text::new("applied".into()).unwrap(),
				retained: List::new(vec![RetainedField::RoomAccess(Held {
					key: key(8),
					reference: target,
				})])
				.unwrap(),
			},
		}])
		.unwrap(),
	}
}
pub struct SessionContent {
	pub invocations: Rc<Cell<usize>>,
}
impl Content for SessionContent {
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[if input.verb == "write" { 20 } else { 10 }], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		let mut requests = Vec::new();
		for (index, page) in input
			.graph
			.ok_or_else(|| loam::refusal("graph is not prepared"))?
			.iter()
			.enumerate()
		{
			requests.extend((0..page.field_count()).map(|field| ReferenceRequest::RestorePage { page: index, field }));
		}
		if input.verb == "write" {
			let reference = input
				.args
				.first()
				.and_then(|value| Ref::try_from(value).ok())
				.ok_or_else(|| loam::refusal("held target required"))?;
			// Deliberately stress both complete populations and the attachment
			// Save quota, even though this fixture's fields share one target.
			requests.extend((0..FIELDS).map(|_| ReferenceRequest::Save {
				reference: reference.clone(),
				uri: None,
			}));
		}
		Ok(requests)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		self.invocations.set(self.invocations.get() + 1);
		if input.verb == "write" {
			let target = Ref::try_from(&input.args[0]).map_err(|_| loam::refusal("held target required"))?;
			let revision = input.args[1].as_i64().unwrap() as u64;
			let record = candidate(target, revision);
			let encoded = records::encode(&record).unwrap();
			let pages = super::graph::replace(call, &encoded, |field| reference(field).clone())?;
			return Ok(Argument::Integer(pages as i64));
		}
		let pages = input.graph.ok_or_else(|| loam::refusal("graph is not prepared"))?;
		let graph: Vec<_> = core::iter::once(records::GraphPage {
			schema: records::WORKSPACE.id,
			version: records::WORKSPACE.version,
			payload: input.payload,
			field_count: 0,
		})
		.chain(pages.iter().map(|page| records::GraphPage {
			schema: page.schema().id,
			version: page.schema().version,
			payload: page.payload(),
			field_count: page.field_count(),
		}))
		.collect();
		let record = records::decode_graph(
			custody::ResourceBinding {
				resource: input.bound_resource,
			},
			&graph,
			|page, coordinate, field| {
				let page = page
					.checked_sub(1)
					.and_then(|index| pages.get(index))
					.ok_or(records::Error::Fields)?;
				let reference = call.page_reference(page, field).map_err(|_| records::Error::Fields)?;
				Ok(restored(coordinate, reference))
			},
		)
		.map_err(|_| loam::refusal("invalid session graph"))?;
		let revision = input.args[0].as_i64().unwrap() as u64;
		let mut expected = intent(true);
		expected.standing = Text::new(format!("revision-{revision}").into()).unwrap();
		assert_eq!(record.intent, expected);
		assert!(record.custody.room_access(key(FIELDS as u64)).is_some());
		assert_eq!(record.binding.resource, input.bound_resource);
		let receipt = &record.effects.as_slice()[0];
		assert_eq!(receipt.resource_generation, nz(7 + revision));
		assert_eq!(
			receipt.canonical_intent.text().as_str(),
			Some(format!("{revision}{}", "x".repeat(60000)).as_str())
		);
		let custody::Outcome::Committed { retained, .. } = &receipt.outcome else {
			panic!("committed receipt lost")
		};
		let RetainedField::RoomAccess(result) = &retained.as_slice()[0] else {
			panic!("result role changed")
		};
		assert_eq!(result.reference, receipt.source.reference);
		assert_eq!(record.custody.room_access(key(3)).unwrap().reference, result.reference);
		let effect = pages
			.iter()
			.find(|page| page.schema().id == records::EFFECT.id)
			.unwrap();
		call.disclose_page(effect, 2, false)
	}
}
pub fn registration(invocations: Rc<Cell<usize>>) -> Registration {
	Registration {
		schema: records::WORKSPACE.id,
		version: records::WORKSPACE.version,
		graph: Some(Graph {
			requirement_verbs: Vec::new(),
			schemas: records::SCHEMAS
				.iter()
				.map(|schema| PageSchema {
					id: schema.id,
					version: schema.version,
				})
				.collect(),
			max_pages: records::MAX_PAGES - 1,
			max_payload_bytes: custody::MAX_AUTHORITY_BYTES,
			max_edges: records::MAX_PAGES * 2 + FIELDS + 3,
		}),
		methods: vec![
			Method {
				verb: "write".into(),
				retry: Retry::Receipt,
			},
			Method {
				verb: "read".into(),
				retry: Retry::ReadOnly,
			},
		],
		content: Box::new(SessionContent { invocations }),
	}
}
