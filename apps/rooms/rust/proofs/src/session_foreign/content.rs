//! Shared codec order and exact prepared fields define this application witness.
use super::{FIELDS, targets::Target};
use crate::session_capacity as capacity;
use glowcap::{
	Argument, Result,
	loam::{
		self, Call, Content, Graph, Invocation, Method, PageSchema, ReferenceRequest, Registration, Requirement, Retry,
	},
};
use rooms_application::content::session::{custody, records};
use std::{cell::Cell, rc::Rc};

pub struct Application {
	pub targets: Vec<Target>,
	pub invocations: Rc<Cell<usize>>,
	pub wrong_uri: Rc<Cell<bool>>,
}
impl Content for Application {
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		Requirement::new(&[if matches!(input.verb, "read" | "stamp") { 10 } else { 20 }], &[])
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		let pages = input.graph.ok_or_else(|| loam::refusal("graph is not prepared"))?;
		if matches!(input.verb, "retain" | "stamp") {
			return Ok(Vec::new());
		}
		let mut requests = Vec::new();
		for (page, snapshot) in pages.iter().enumerate() {
			requests.extend((0..snapshot.field_count()).map(|field| ReferenceRequest::RestorePage { page, field }));
		}
		if input.verb == "write" {
			assert_eq!(self.targets.len(), FIELDS);
			requests.extend(
				self.targets
					.iter()
					.enumerate()
					.map(|(index, target)| ReferenceRequest::Save {
						reference: target.reference.clone(),
						uri: Some(if self.wrong_uri.get() && index == 0 {
							self.targets[1].uri.clone()
						} else {
							target.uri.clone()
						}),
					}),
			);
		}
		Ok(requests)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		if input.verb == "stamp" {
			return Ok(Argument::List(vec![
				Argument::Integer(input.content_revision as i64),
				Argument::Integer(input.bound_resource.revision as i64),
			]));
		}
		if input.verb == "retain" {
			crate::session_storage::graph::retain(call, input)?;
			return Ok(Argument::Void);
		}
		let revision = input.args[0].as_i64().unwrap() as u64;
		if input.verb == "write" {
			self.invocations.set(self.invocations.get() + 1);
			let mut next = self.targets.iter();
			let record = capacity::candidate(revision, || next.next().unwrap().reference.clone());
			assert!(next.next().is_none());
			let encoded = records::encode(&record).unwrap();
			let pages =
				crate::session_storage::graph::replace(call, &encoded, |field| capacity::reference(field).clone())?;
			assert_eq!(pages + 1, records::MAX_PAGES);
			return Ok(Argument::Integer(pages as i64));
		}
		let pages = input.graph.ok_or_else(|| loam::refusal("graph is not prepared"))?;
		assert_eq!(pages.len() + 1, records::MAX_PAGES);
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
		let mut identities = Vec::with_capacity(FIELDS);
		let restored = records::decode_graph(
			custody::ResourceBinding {
				resource: input.bound_resource,
			},
			&graph,
			|page, coordinate, field| {
				let page = pages
					.get(page.checked_sub(1).ok_or(records::Error::Fields)?)
					.ok_or(records::Error::Fields)?;
				let reference = call.page_reference(page, field).map_err(|_| records::Error::Fields)?;
				assert!(!identities.contains(&reference), "restored graph aliases a field");
				identities.push(reference.clone());
				Ok(capacity::field(coordinate.role, coordinate.key.slot().get(), reference))
			},
		)
		.unwrap();
		assert_eq!(identities.len(), FIELDS);
		assert_eq!(restored.binding.resource, input.bound_resource);
		let mut next = 0;
		let expected = capacity::candidate(revision, || {
			let identity = next;
			next += 1;
			identity
		});
		let expected = records::encode(&expected).unwrap();
		let actual = records::encode(&restored).unwrap();
		assert_eq!(actual.workspace, expected.workspace);
		let actual_fields = actual.custody.iter().chain(actual.effects.iter().flatten());
		let expected_fields = expected.custody.iter().chain(expected.effects.iter().flatten());
		for (actual, expected) in actual_fields.zip(expected_fields) {
			assert_eq!(actual.payload, expected.payload);
			assert_eq!(actual.fields.len(), expected.fields.len());
			for (actual, expected) in actual.fields.iter().zip(&expected.fields) {
				assert_eq!(actual.coordinate(), expected.coordinate());
			}
		}
		// Every disclosed occurrence is an owned result at the existing near
		// resolver. page_reference alone borrows Call custody and cannot escape.
		// This bounded list stays within the source Host; it is never a wire
		// argument/result vector. The caller checks each URI after cold restore.
		let mut disclosed: Vec<_> = (0..FIELDS).map(|_| None).collect();
		let expected_pages = expected.custody.iter().chain(expected.effects.iter().flatten());
		for (page, expected) in pages.iter().filter(|page| page.field_count() != 0).zip(expected_pages) {
			assert_eq!(page.field_count(), expected.fields.len());
			for (field, expected) in expected.fields.iter().enumerate() {
				let identity = *capacity::reference(expected);
				assert!(disclosed[identity].is_none());
				disclosed[identity] = Some(call.disclose_page(page, field, false)?);
			}
		}
		Ok(Argument::List(vec![
			Argument::Integer(input.content_revision as i64),
			Argument::Integer(input.bound_resource.revision as i64),
			Argument::List(disclosed.into_iter().map(Option::unwrap).collect()),
		]))
	}
}
pub fn registration(application: Application) -> Registration {
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
			max_edges: FIELDS + 2 * (records::MAX_PAGES - 1) + 1,
		}),
		methods: vec![
			Method {
				verb: "stamp".into(),
				retry: Retry::ReadOnly,
			},
			Method {
				verb: "retain".into(),
				retry: Retry::Receipt,
			},
			Method {
				verb: "write".into(),
				retry: Retry::Receipt,
			},
			Method {
				verb: "read".into(),
				retry: Retry::ReadOnly,
			},
		],
		content: Box::new(application),
	}
}
