//! Stable registration projection. Zig copies declaration data during attach;
//! Rust callback addresses remain fixed until the attachment retires.
use super::{Graph, Method, Registration, Retry, content};
use crate::{context::ContextInner, sys::loam as ffi};
use std::rc::Rc;

struct Row {
	schema: u64,
	version: u32,
	methods: Vec<Method>,
	graph: Option<Graph>,
}
pub(super) struct Prepared {
	// Every pointer in declarations borrows one of these fixed allocations.
	_rows: Vec<Row>,
	_methods: Vec<Vec<ffi::GlowcapLoamMethod>>,
	_schemas: Vec<Vec<ffi::GlowcapLoamGraphSchema>>,
	_graph_verbs: Vec<Vec<ffi::GlowcapLoamGraphVerb>>,
	_graphs: Vec<Option<ffi::GlowcapLoamGraph>>,
	pub callbacks: Vec<content::Callback>,
	pub declarations: Vec<ffi::GlowcapLoamContent>,
}
impl Prepared {
	pub fn new(registrations: Vec<Registration>, diagnostics: Rc<ContextInner>, host_id: u64) -> Self {
		let (rows, callbacks): (Vec<_>, Vec<_>) = registrations
			.into_iter()
			.map(|registration| {
				(
					Row {
						schema: registration.schema,
						version: registration.version,
						methods: registration.methods,
						graph: registration.graph,
					},
					content::Callback {
						content: registration.content,
						diagnostics: Rc::clone(&diagnostics),
						host_id,
						owner: std::rc::Weak::new(),
					},
				)
			})
			.unzip();
		let method_tables: Vec<Vec<_>> = rows
			.iter()
			.map(|row| {
				row.methods
					.iter()
					.map(|method| ffi::GlowcapLoamMethod {
						verb: method.verb.as_ptr(),
						verb_len: method.verb.len(),
						retry: match method.retry {
							Retry::ReadOnly => 0,
							Retry::Idempotent => 1,
							Retry::Receipt => 2,
						},
					})
					.collect()
			})
			.collect();
		let graph_schemas: Vec<Vec<_>> = rows
			.iter()
			.map(|row| {
				row.graph
					.as_ref()
					.map(|graph| {
						graph
							.schemas
							.iter()
							.map(|schema| ffi::GlowcapLoamGraphSchema {
								id: schema.id,
								version: schema.version,
							})
							.collect()
					})
					.unwrap_or_default()
			})
			.collect();
		let graph_verbs: Vec<Vec<_>> = rows
			.iter()
			.map(|row| {
				row.graph
					.as_ref()
					.map(|graph| {
						graph
							.requirement_verbs
							.iter()
							.map(|verb| ffi::GlowcapLoamGraphVerb {
								verb: verb.as_ptr(),
								verb_len: verb.len(),
							})
							.collect()
					})
					.unwrap_or_default()
			})
			.collect();
		let graphs: Vec<_> = rows
			.iter()
			.zip(&graph_schemas)
			.zip(&graph_verbs)
			.map(|((row, schemas), verbs)| {
				row.graph.as_ref().map(|graph| ffi::GlowcapLoamGraph {
					schemas: schemas.as_ptr(),
					schema_count: schemas.len(),
					max_pages: graph.max_pages,
					max_payload_bytes: graph.max_payload_bytes,
					max_edges: graph.max_edges,
					requirement_verbs: verbs.as_ptr(),
					requirement_verb_count: verbs.len(),
				})
			})
			.collect();
		let declarations: Vec<_> = rows
			.iter()
			.zip(&method_tables)
			.zip(&callbacks)
			.zip(&graphs)
			.map(|(((row, methods), callback), graph)| ffi::GlowcapLoamContent {
				schema: row.schema,
				version: row.version,
				context: (callback as *const content::Callback).cast_mut().cast(),
				methods: methods.as_ptr(),
				method_count: methods.len(),
				requirement: Some(content::requirement),
				invoke: Some(content::invoke),
				references: Some(content::references),
				dependent_requirement: Some(content::dependent_requirement),
				graph: graph.as_ref().map_or(core::ptr::null(), |graph| graph as *const _),
			})
			.collect();

		Self {
			_rows: rows,
			_methods: method_tables,
			_schemas: graph_schemas,
			_graph_verbs: graph_verbs,
			_graphs: graphs,
			callbacks,
			declarations,
		}
	}
}
