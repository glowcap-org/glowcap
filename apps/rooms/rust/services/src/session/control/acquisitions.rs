//! Socket lifetime lends a wait. The adapter retains the exact acquisition and
//! its actual receiver. Retrying cannot fetch capabilities or choose intent again.
use super::{Failure, peer_failure};
use rooms_application::content::session::{custody, records, workspace};
use rooms_glowcap::client::{
	Deadline,
	workspace::{Import, Release, ResultImport, Submission},
};
use rooms_platform::HostPlatform;
use rooms_runtime::platform::OwnedTask;
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
	ReleaseResult => "release-result" { operation: String, command_base: u64, name: String, args: Vec<String> },
}
}
/// What a request came to. The table keeps only a final answer: a request
/// that only learned the session is still busy answers again when asked, so a
/// retry of its id asks the session anew instead of replaying that answer.
#[derive(Clone)]
enum Answered {
	/// The request's end, whatever it was. It is kept under the id.
	Final(Result<(), Failure>),
	/// The session had not finished the work the request waits on, so asking
	/// again is the answer. It is never kept.
	Running(Failure),
}
impl Answered {
	fn into_result(self) -> Result<(), Failure> {
		match self {
			Self::Final(result) => result,
			Self::Running(failure) => Err(failure),
		}
	}
}
struct Pending {
	canonical: String,
	bytes: usize,
	result: watch::Receiver<Option<Answered>>,
	_task: OwnedTask,
}
impl Pending {
	async fn completed(result: &mut watch::Receiver<Option<Answered>>) -> Result<Answered, Failure> {
		loop {
			if let Some(answered) = result.borrow_and_update().as_ref() {
				return Ok(answered.clone());
			}
			result.changed().await.map_err(Failure::uncertain)?;
		}
	}
}
#[derive(Default)]
pub(super) struct Acquisitions(Mutex<BTreeMap<String, Pending>>);
impl Acquisitions {
	pub async fn submit(&self, app: &super::Application, id: &str, request: Request) -> Result<(), Failure> {
		let app = app.clone();
		self.admit(id, request, move |request| async move { request.run(&app).await })
			.await
	}
	/// Admit `request` under `id` and wait for what `run` answers, or join the
	/// request the id already retains.
	async fn admit<R: std::future::Future<Output = Answered> + 'static>(
		&self,
		id: &str,
		request: Request,
		run: impl FnOnce(Request) -> R,
	) -> Result<(), Failure> {
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
			let (completed, result) = watch::channel(None);
			let running = run(request);
			let task = OwnedTask::spawn_local(async move {
				completed.send_replace(Some(running.await));
			});
			pending.insert(
				id.into(),
				Pending {
					canonical,
					bytes,
					result,
					_task: task,
				},
			);
		}
		let mut result = pending
			.get(id)
			.ok_or_else(|| Failure::invalid("acquisition left the pending table before it was observed"))?
			.result
			.clone();
		drop(pending);
		let answered = tokio::time::timeout(std::time::Duration::from_secs(20), Pending::completed(&mut result))
			.await
			.map_err(|_| Failure::uncertain("acquisition remains pending; retry this exact request"))??;
		if matches!(answered, Answered::Running(_)) {
			// Its slot and byte charge go with it, unless another submit already
			// replaced the entry this one waited on.
			let mut pending = self.0.lock().await;
			if pending.get(id).is_some_and(|entry| entry.result.same_channel(&result)) {
				pending.remove(id);
			}
		}
		answered.into_result()
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
			Self::ReleaseResult {
				operation, name, args, ..
			} => {
				return size_of::<Self>()
					.saturating_add(operation.capacity())
					.saturating_add(name.capacity())
					.saturating_add(vector(args))
					.saturating_add(args.iter().map(String::capacity).sum());
			}
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
	async fn run(self, app: &super::Application) -> Answered {
		match self {
			Self::ReleaseResult {
				operation,
				command_base,
				name,
				args,
			} => Self::released(app, &operation, command_base, &name, &args).await,
			other => Answered::Final(other.submit(app).await),
		}
	}
	/// Give back the receipt of a result the plan will not adopt, so its place
	/// is free and the operation is settled. A release the session answers
	/// running is asked again for as long as the attached view asks
	/// (`released_within`). One still running then is not final.
	async fn released(
		app: &super::Application,
		operation: &str,
		command_base: u64,
		name: &str,
		args: &[String],
	) -> Answered {
		let command = match app.workspace.prepare_command(operation, command_base, name, args).await {
			Ok(command) => command,
			Err(error) => return Answered::Final(Err(peer_failure(error))),
		};
		match crate::session::attached::released_within(&HostPlatform, || command.release()).await {
			// An adopted result is the workspace's, and its receipt holds no
			// place either.
			Ok(Release::Released | Release::Kept) => Answered::Final(Ok(())),
			Ok(Release::Running) => Answered::Running(Failure::busy(
				"the session is still running the operation's executor, so its receipt is not released yet: release again",
			)),
			Err(error) => Answered::Final(Err(peer_failure(error))),
		}
	}
	async fn submit(self, app: &super::Application) -> Result<(), Failure> {
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
					.resolve_imported_rooms(&mut held, &mut intent)
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
			Self::ReleaseResult { .. } => unreachable!("`run` answers a release itself"),
		};
		submission.completed().await.map_err(peer_failure)
	}
}
fn coordinate(key: custody::FieldKey<custody::SessionAccess>) -> custody::Coordinate {
	custody::Coordinate {
		role: custody::Role::SessionAccess,
		key: key.retag(),
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::{cell::Cell, rc::Rc};

	fn release() -> Request {
		serde_json::from_str(
			r#"{"kind":"release-result","operation":"op","command_base":0,"name":"startDirect","args":[]}"#,
		)
		.unwrap()
	}

	/// A release the session answers running is not kept under its id: the
	/// retry asks again, and what a final answer then says is what stays.
	/// The slot and its byte charge go with the busy answer.
	#[tokio::test(flavor = "current_thread")]
	async fn a_running_release_is_asked_again_by_the_same_id() {
		tokio::task::LocalSet::new()
			.run_until(async {
				let table = Acquisitions::default();
				let asked = Rc::new(Cell::new(0));
				let answer = |asked: Rc<Cell<u32>>, answers: Vec<Answered>| {
					move |_request: Request| async move {
						let at = asked.get();
						asked.set(at + 1);
						answers[at as usize].clone()
					}
				};
				let busy = || Failure::busy("running");
				let first = table
					.admit("one", release(), answer(asked.clone(), vec![Answered::Running(busy())]))
					.await;
				assert!(first.is_err_and(|failure| failure.message.contains("running")));
				assert_eq!(table.0.lock().await.len(), 0, "a busy answer keeps no slot");
				let second = table
					.admit(
						"one",
						release(),
						answer(asked.clone(), vec![Answered::Running(busy()), Answered::Final(Ok(()))]),
					)
					.await;
				// The second closure's first answer is index 1 of its own list.
				assert_eq!(asked.get(), 2);
				assert!(second.is_ok(), "{second:?}");
				// A final answer stays under the id and is replayed, not asked again.
				let third = table.admit("one", release(), answer(asked.clone(), Vec::new())).await;
				assert!(third.is_ok());
				assert_eq!(asked.get(), 2, "a final answer is replayed");
				assert_eq!(table.0.lock().await.len(), 1);
			})
			.await;
	}
}
