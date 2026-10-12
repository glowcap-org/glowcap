//! Archive sharing retains exact source and recipient through both upstream acts.
use super::{State, executor::Seat, records, results::Settlement};
use glowcap::{
	Argument, Ref, Result,
	loam::{self, Call, Continuation, EffectExecution, EffectResult, Invocation, ReferenceRequest},
};
use rooms_application::{
	archive::{Filter, ShareKind, shares::Share},
	content::session::{custody, workspace},
	fields::Text,
	room::ArgumentView,
	session::command::{Effect, Request, Route},
};
use rooms_glowcap::client::{Deadline, Tasks};
use std::rc::Rc;

pub(super) fn recognizes(route: Route) -> bool {
	matches!(
		route,
		Route::Effect(Effect::ShareArchiveHistory | Effect::OfferDurableArchive | Effect::RevokeIssuedArchiveShare)
	)
}
pub(super) struct Intent {
	pub filter: Filter,
	pub directory: String,
	pub kind: ShareKind,
	pub conversation: Option<String>,
	pub durable: bool,
	pub share: Option<Share>,
}
struct Selection {
	archive: Option<custody::Coordinate>,
	direct: Option<custody::Coordinate>,
	intent: Option<Intent>,
	revoke: Option<String>,
}
fn coordinate<K>(role: custody::Role, key: custody::FieldKey<K>) -> custody::Coordinate {
	custody::Coordinate {
		role,
		key: custody::FieldKey::new(key.slot(), key.generation()),
	}
}
fn selection(request: &Request<'_, impl ArgumentView>, intent: &workspace::Intent) -> Result<Selection> {
	let archive = intent.archive.map(|key| coordinate(custody::Role::ArchiveAccess, key));
	let args: Vec<_> = request.args().collect();
	if request.route() == Route::Effect(Effect::RevokeIssuedArchiveShare) {
		let [id] = args.as_slice() else {
			return Err(loam::refusal("archive revocation requires one share ID"));
		};
		if id.len() > 128 || archive.is_none() {
			return Err(loam::refusal("archive issuer and bounded share ID required"));
		}
		return Ok(Selection {
			archive,
			direct: None,
			intent: None,
			revoke: Some((*id).into()),
		});
	}
	let [conversation, recipient, kind, id, label] = args.as_slice() else {
		return Err(loam::refusal(
			"archive sharing requires conversation, recipient, scope, share ID and label",
		));
	};
	let row = intent
		.conversations
		.as_slice()
		.iter()
		.find(|row| row.id().text().as_str() == Some(*conversation))
		.ok_or_else(|| loam::refusal("original archive conversation is absent"))?;
	let (directory, expected_kind) = match row {
		workspace::Conversation::Room(row) => (&row.directory, ShareKind::Room),
		workspace::Conversation::Direct(row) => (&row.directory, ShareKind::Direct),
	};
	let kind = match *kind {
		"room" => ShareKind::Room,
		"direct" => ShareKind::Direct,
		"standing" => ShareKind::Standing,
		_ => return Err(loam::refusal("invalid archive scope")),
	};
	if kind != ShareKind::Standing && kind != expected_kind {
		return Err(loam::refusal("archive scope does not match its conversation"));
	}
	let direct = intent
		.conversations
		.as_slice()
		.iter()
		.find_map(|row| match row {
			workspace::Conversation::Direct(row)
				if row.id.text().as_str() == Some(*recipient) && &row.directory == directory && !row.closed =>
			{
				row.access
			}
			_ => None,
		})
		.ok_or_else(|| loam::refusal("original archive recipient is not held in this directory"))?;
	let directory = directory
		.text()
		.as_str()
		.ok_or_else(|| loam::refusal("invalid archive directory"))?
		.to_owned();
	let conversation = (kind != ShareKind::Standing)
		.then(|| {
			row.history_id()
				.text()
				.as_str()
				.map(str::to_owned)
				.ok_or_else(|| loam::refusal("invalid archive conversation"))
		})
		.transpose()?;
	let filter = Filter::shared(kind, directory.clone().into(), conversation.clone().map(Into::into))
		.map_err(|error| loam::refusal(error.to_string()))?;
	let durable = request.route() == Route::Effect(Effect::OfferDurableArchive);
	if durable && archive.is_none() {
		return Err(loam::refusal(
			"select an archive issuer before offering durable history",
		));
	}
	let share = durable
		.then(|| Share::new((*id).into(), (*label).into(), filter.clone()))
		.transpose()
		.map_err(|error| loam::refusal(error.to_string()))?;
	Ok(Selection {
		archive,
		direct: Some(coordinate(custody::Role::DirectAccess, direct)),
		intent: Some(Intent {
			filter,
			directory,
			kind,
			conversation,
			durable,
			share,
		}),
		revoke: None,
	})
}
pub(super) fn references(
	input: Invocation<'_>,
	record: &super::content::MetadataRecord,
) -> Result<Vec<ReferenceRequest>> {
	let declared = super::content::values(input.args);
	let request = Request::parse(&declared).map_err(|error| loam::refusal(error.to_string()))?;
	let selected = selection(&request, &record.intent)?;
	selected
		.archive
		.into_iter()
		.chain(selected.direct)
		.map(|coordinate| {
			let held = record
				.custody
				.get(coordinate)
				.ok_or_else(|| loam::refusal("archive sharing custody is absent"))?;
			let location = records::location(&held);
			Ok(ReferenceRequest::RestorePage {
				page: location
					.page
					.checked_sub(1)
					.ok_or_else(|| loam::refusal("invalid archive share page"))?,
				field: location.field,
			})
		})
		.collect()
}
pub(super) fn admit<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
	mut record: records::Record,
	request: &Request<'_, impl ArgumentView>,
) -> Result<Argument> {
	let selected = selection(request, &record.intent)?;
	let resolve = |call: &mut Call<'_>, coordinate| {
		let held = record
			.custody
			.get(coordinate)
			.ok_or_else(|| loam::refusal("archive sharing custody is absent"))?;
		records::reference(&held).resolve(call, input)
	};
	let archive = match selected.archive {
		Some(coordinate) => resolve(call, coordinate)?,
		None => owner
			.recording
			.borrow()
			.as_ref()
			.map(|sink| sink.reader().clone())
			.ok_or_else(|| loam::refusal("session archive is not installed"))?,
	};
	let mut targets = vec![archive.clone()];
	if let Some(direct) = selected.direct {
		targets.push(resolve(call, direct)?);
	}
	let seat = Seat::reserve(owner, request.id())?;
	let (reservation, pending) = call.reserve_continuation_copying(&targets)?;
	let source = reservation.source()?;
	let canonical = request
		.canonical()
		.map_err(|_| loam::refusal("invalid archive share intent"))?;
	let operation = Text::new(request.id().into()).ok_or_else(|| loam::refusal("invalid archive share operation"))?;
	let intent = Text::new(canonical.clone().into())
		.ok_or_else(|| loam::refusal("archive share intent exceeds receipt capacity"))?;
	let mut retained = Vec::with_capacity(2);
	if let Some(coordinate) = selected.archive {
		retained.push(records::restored(coordinate, records::Field::Held(archive)));
	}
	if let Some(direct) = selected.direct {
		retained.push(records::restored(direct, records::Field::Held(targets[1].clone())));
	}
	let receipt = super::content::commands::receipt(input, operation, intent, source.clone(), retained)?;
	super::content::commands::reserve(owner, &mut record, receipt)?;
	records::replace_effects(call, input, &record)?;
	if let Some(id) = selected.revoke {
		seat.start(
			pending,
			source,
			canonical,
			super::executor::CallIntent {
				reply: rooms_application::session::effect::Reply::Boolean,
				verb: rooms_application::archive::shares::protocol::REVOKE.into(),
				args: vec![id.into()],
			},
			None,
		)?;
	} else {
		seat.start_archive(
			pending,
			source,
			canonical,
			selected
				.intent
				.ok_or_else(|| loam::refusal("archive sharing intent is absent"))?,
		)?;
	}
	Ok("pending".into())
}

/// The two bounded calls keep their actual observations through interruption.
/// Narrowing returns a source-restricted read facet. Delivery retains it until
/// the recipient has acknowledged. No workspace authority row is synthesized.
pub(super) struct Pipeline {
	host: glowcap::Host,
	continuation: Continuation,
	intent: Intent,
	reply_bytes: usize,
	pending: Option<EffectExecution>,
	prepared: Option<Argument>,
	read: Option<std::pin::Pin<Box<dyn std::future::Future<Output = Result<Argument>>>>>,
	read_result: Option<Result<Argument>>,
	finished: bool,
}
pub(super) enum Completion {
	Settled(Settlement),
	Unknown(glowcap::Error),
}
impl Pipeline {
	pub fn new(host: glowcap::Host, continuation: Continuation, intent: Intent, reply_bytes: usize) -> Self {
		Self {
			host,
			continuation,
			intent,
			reply_bytes,
			pending: None,
			prepared: None,
			read: None,
			read_result: None,
			finished: false,
		}
	}
	async fn perform(&mut self, index: usize, verb: &str, args: &[Argument]) -> Result<EffectResult> {
		if self.pending.is_none() {
			self.pending = Some(match self.continuation.execute(index, verb, args, self.reply_bytes) {
				Ok(execution) => execution,
				Err(error) => return Ok(EffectResult::Unsent(error)),
			});
		}
		let result = self
			.pending
			.as_mut()
			.ok_or_else(|| loam::refusal("private archive execution is absent"))?
			.completed()
			.await?;
		Ok(result)
	}
	pub async fn advance(&mut self) -> Result<Option<Completion>> {
		if self.finished {
			return Ok(None);
		}
		if self.prepared.is_none() {
			let (verb, args) = if let Some(share) = &self.intent.share {
				(
					rooms_application::archive::shares::protocol::ISSUE,
					rooms_glowcap::archive::share_issue(share).map_err(|error| loam::refusal(error.to_string()))?,
				)
			} else {
				(
					rooms_application::archive::protocol::NARROW,
					vec![
						rooms_glowcap::archive::filter_row(&self.intent.filter)
							.map_err(|error| loam::refusal(error.to_string()))?,
						"read".into(),
					],
				)
			};
			let observed = if self.intent.durable {
				self.perform(0, verb, &args).await?
			} else {
				// Read projection belongs to the confirmed continuation. The
				// recursive narrow result retains its original issuing admission.
				// Retain the one observation across worker interruption; a terminal
				// refusal supplies no reason to start another upstream request.
				if self.read_result.is_none() {
					if self.read.is_none() {
						let reader = super::content::reads::retained_archive_reader(&self.continuation, 0, true)?;
						let host = self.host.clone();
						self.read = Some(Box::pin(async move { host.send(&reader, verb, &args).await }));
					}
					let reading = self
						.read
						.as_mut()
						.ok_or_else(|| loam::refusal("archive read is not started"))?;
					self.read_result = Some(reading.await);
					self.read = None;
				}
				EffectResult::Ready(
					self.read_result
						.as_ref()
						.ok_or_else(|| loam::refusal("archive read is not observed"))?
						.clone()?,
				)
			};
			match observed {
				EffectResult::Ready(value) => {
					if self.intent.durable {
						let uri = value
							.as_str()
							.ok_or_else(|| loam::refusal("archive issuer returned no recipe"))?;
						glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0)?;
					} else {
						Ref::try_from(&value).map_err(|_| loam::refusal("archive narrowing returned no capability"))?;
					}
					self.prepared = Some(value);
					self.read_result = None;
					self.pending = None;
				}
				EffectResult::Unsent(_) => {
					self.finished = true;
					return Ok(Some(Completion::Settled(Settlement::absent())));
				}
				EffectResult::Unknown(error) => {
					self.finished = true;
					return Ok(Some(Completion::Unknown(error)));
				}
				EffectResult::Pending => unreachable!("completed archive observation"),
			}
		}
		let prepared = self
			.prepared
			.clone()
			.ok_or_else(|| loam::refusal("prepared archive authority is absent"))?;
		let args = [
			self.intent.directory.clone().into(),
			self.intent.kind.wire().into(),
			self.intent.conversation.clone().map_or(Argument::Void, Into::into),
			prepared,
		];
		let verb = if self.intent.durable {
			rooms_application::direct::OFFER_ARCHIVE
		} else {
			rooms_application::direct::HAND_ARCHIVE
		};
		match self.perform(1, verb, &args).await? {
			EffectResult::Ready(value) => {
				let super::results::Prepared::Complete(outcome) = super::results::Prepared::read(
					rooms_application::session::effect::Reply::Acknowledgment,
					&value,
					"",
				)?
				else {
					unreachable!("acknowledgment carries no acquisition")
				};
				self.finished = true;
				self.pending = None;
				self.prepared.take();
				Ok(Some(Completion::Settled(outcome)))
			}
			EffectResult::Unsent(_) => {
				self.finished = true;
				Ok(Some(Completion::Settled(Settlement::absent())))
			}
			EffectResult::Unknown(error) => {
				self.finished = true;
				Ok(Some(Completion::Unknown(error)))
			}
			EffectResult::Pending => unreachable!("completed archive delivery"),
		}
	}
}
