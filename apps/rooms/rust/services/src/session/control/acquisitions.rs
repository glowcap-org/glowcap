//! Socket lifetime lends a wait. The adapter retains the exact acquisition and
//! its actual receiver. Retrying cannot fetch capabilities or choose intent again.
use super::{Failure, peer_failure};
use rooms_application::content::session::{custody, records, workspace};
use rooms_glowcap::client::{
	Deadline,
	workspace::{Import, ResultImport, Submission},
};
use rooms_platform::HostPlatform;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use tokio::sync::{Mutex, watch};

const MAX_BYTES: usize = 16 * 1024 * 1024;
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Incoming {
	coordinate: custody::Coordinate,
	uri: String,
}
super::request::request! {
pub(super) enum Request, kind = "kind" {
	PublicRoom => "public-room" { base: u64, selection: rooms_glowcap::client::workspace::PublicRoomImport },
	Workspace => "workspace" {
		base: u64,
		imports: Vec<Incoming>,
		releases: Vec<custody::Coordinate>,
		intent: workspace::Intent,
		source: Option<custody::FieldKey<custody::SessionAccess>>,
	},
	Result => "result" {
		operation: String,
		command_base: u64,
		name: String,
		args: Vec<String>,
		base: u64,
		mappings: Vec<[custody::Coordinate; 2]>,
		releases: Vec<custody::Coordinate>,
		intent: workspace::Intent,
		source: Option<custody::FieldKey<custody::SessionAccess>>,
	},
}
}
struct Pending {
	canonical: String,
	bytes: usize,
	result: watch::Receiver<Option<Result<(), Failure>>>,
	_task: Task,
}
struct Task(tokio::task::JoinHandle<()>);
impl Drop for Task {
	fn drop(&mut self) {
		self.0.abort();
	}
}
impl Pending {
	async fn completed(result: &mut watch::Receiver<Option<Result<(), Failure>>>) -> Result<(), Failure> {
		loop {
			if let Some(result) = result.borrow_and_update().as_ref() {
				return result.clone();
			}
			result.changed().await.map_err(Failure::uncertain)?;
		}
	}
}
#[derive(Default)]
pub(super) struct Acquisitions(Mutex<BTreeMap<String, Pending>>);
impl Acquisitions {
	pub async fn submit(&self, app: &super::Application, id: &str, request: Request) -> Result<(), Failure> {
		if id.is_empty() || id.len() > 128 {
			return Err(Failure::invalid("invalid acquisition identity"));
		}
		let canonical = serde_json::to_string(&request)?;
		let bytes = canonical.capacity().saturating_add(request.retained_bytes());
		let mut pending = self.0.lock().await;
		if let Some(prior) = pending.get(id) {
			if prior.canonical != canonical {
				return Err(Failure::invalid("acquisition already retains another request"));
			}
		} else {
			// Charge the replay spelling and actual typed candidate capacities.
			// The task moves the candidate into preparation; Host arguments and
			// reference lookup have independent shared call budgets. Fixed task,
			// watch and map state is bounded by MAX_EFFECTS. Retain the peak
			// candidate charge until explicit release, including during fetch.
			let retained = pending.values().map(|entry| entry.bytes).sum::<usize>();
			if pending.len() == custody::MAX_EFFECTS || bytes > MAX_BYTES.saturating_sub(retained) {
				return Err(Failure::exhausted(
					"release completed acquisitions before admitting another",
				));
			}
			let app = app.clone();
			let (completed, result) = watch::channel(None);
			let task = tokio::task::spawn_local(async move {
				completed.send_replace(Some(request.run(&app).await));
			});
			pending.insert(
				id.into(),
				Pending {
					canonical,
					bytes,
					result,
					_task: Task(task),
				},
			);
		}
		let mut result = pending
			.get(id)
			.ok_or_else(|| Failure::invalid("acquisition left the pending table before it was observed"))?
			.result
			.clone();
		drop(pending);
		tokio::time::timeout(std::time::Duration::from_secs(20), Pending::completed(&mut result))
			.await
			.map_err(|_| Failure::uncertain("acquisition remains pending; retry this exact request"))?
	}
	pub async fn release(&self, id: &str) -> Result<(), Failure> {
		let mut pending = self.0.lock().await;
		if let Some(entry) = pending.get(id)
			&& entry.result.borrow().is_none()
		{
			return Err(Failure::uncertain(
				"acquisition is unresolved; retain its original request",
			));
		}
		pending.remove(id);
		Ok(())
	}
	pub async fn close(&self) -> Result<(), Failure> {
		let mut pending = self.0.lock().await;
		for entry in pending.values_mut() {
			let _terminal = tokio::time::timeout(
				std::time::Duration::from_secs(20),
				Pending::completed(&mut entry.result),
			)
			.await
			.map_err(|_| Failure::uncertain("retain local control while acquisition is unresolved"))?;
		}
		pending.clear();
		Ok(())
	}
}
impl Request {
	fn retained_bytes(&self) -> usize {
		fn vector<T>(values: &Vec<T>) -> usize {
			values.capacity().saturating_mul(size_of::<T>())
		}
		let (intent, releases, other) = match self {
			Self::PublicRoom { selection, .. } => {
				return size_of::<Self>()
					+ selection
						.retained_bytes()
						.saturating_sub(size_of::<rooms_glowcap::client::workspace::PublicRoomImport>());
			}
			Self::Workspace {
				imports,
				releases,
				intent,
				..
			} => (
				intent,
				releases,
				vector(imports).saturating_add(imports.iter().map(|input| input.uri.capacity()).sum()),
			),
			Self::Result {
				operation,
				name,
				args,
				mappings,
				releases,
				intent,
				..
			} => (
				intent,
				releases,
				operation
					.capacity()
					.saturating_add(name.capacity())
					.saturating_add(vector(args))
					.saturating_add(args.iter().map(String::capacity).sum())
					.saturating_add(vector(mappings)),
			),
		};
		size_of::<Self>()
			.saturating_add(intent.retained_bytes().saturating_sub(size_of::<workspace::Intent>()))
			.saturating_add(vector(releases))
			.saturating_add(other)
	}
	async fn run(self, app: &super::Application) -> Result<(), Failure> {
		let mut submission: Submission<()> = match self {
			Self::PublicRoom { base, selection } => app
				.workspace
				.prepare_public_room(base, selection)
				.await
				.map_err(peer_failure)?
				.start_submission(),
			Self::Workspace {
				base,
				imports,
				releases,
				mut intent,
				source,
			} => {
				if imports.len() + usize::from(source.is_some()) > records::FIELDS_PER_PAGE {
					return Err(Failure::invalid("acquisition exceeds one custody page"));
				}
				let mut held = Vec::with_capacity(imports.len() + usize::from(source.is_some()));
				for incoming in imports {
					if incoming.coordinate.role.live()
						|| incoming.uri.len() > glowcap::loam::ReferenceRequest::MAX_URI_BYTES
					{
						return Err(Failure::invalid(
							"acquisition requires a bounded durable capability recipe",
						));
					}
					glowcap::parse_sturdyref(&incoming.uri, glowcap::CaptpVersion::V1_0).map_err(Failure::invalid)?;
					let reference = HostPlatform
						.within(
							rooms_application::room::authority::REQUEST_TIMEOUT_MS,
							app.host.enliven(&incoming.uri),
						)
						.await
						.ok_or_else(|| Failure::uncertain("capability acquisition did not answer"))?
						.map_err(Failure::invalid)?;
					held.push(Import {
						coordinate: incoming.coordinate,
						reference,
						uri: Some(incoming.uri),
					});
				}
				if let Some(key) = source {
					held.push(Import {
						coordinate: coordinate(key),
						reference: app.workspace.reference().clone(),
						uri: None,
					});
				}
				app.workspace
					.resolve_imported_room_names(&held, &mut intent)
					.await
					.map_err(Failure::invalid)?;
				app.workspace
					.validate_room_authority_imports(&held, &intent)
					.await
					.map_err(Failure::invalid)?;
				app.workspace
					.prepare_acquisition(base, held, &releases, &intent)
					.map_err(Failure::invalid)?
					.start_submission()
			}
			Self::Result {
				operation,
				command_base,
				name,
				args,
				base,
				mappings,
				releases,
				intent,
				source,
			} => {
				let command = app
					.workspace
					.prepare_command(&operation, command_base, &name, &args)
					.await
					.map_err(peer_failure)?;
				let mappings: Vec<_> = mappings
					.into_iter()
					.map(|[result, destination]| ResultImport { result, destination })
					.collect();
				let request = command
					.prepare_result_acquisition_with_source(base, &mappings, &releases, &intent, source)
					.map_err(Failure::invalid)?;
				let request = if name == "openManagedRoom" {
					request.created_room().map_err(Failure::invalid)?
				} else {
					request
				};
				request.start_submission()
			}
		};
		submission.completed().await.map_err(peer_failure)
	}
}
fn coordinate(key: custody::FieldKey<custody::SessionAccess>) -> custody::Coordinate {
	custody::Coordinate {
		role: custody::Role::SessionAccess,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
