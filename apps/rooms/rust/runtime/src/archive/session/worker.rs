use super::{issuer::Issuer, share::Work, *};
use crate::archive::{
	BlobAccess,
	ingestion::{self, Queue, Reads},
};
use glowcap::{Argument, Host, Locator};
use rooms_application::archive::{
	MAX_READ, MAX_RECORDS,
	index::Scan,
	merge::{self, Account, Limits},
};
use std::collections::HashMap;
use targets::{Selection, Targets};
use tokio::task::{Id, JoinError, JoinSet};
mod reads;
mod recording;
mod shares;
use reads::ReadReplies;
mod shared_blobs;
enum Files<P: Platform> {
	Live(Vec<File<P>>),
	Captured(Vec<capture::Captured>),
}
impl<P: Platform> Files<P> {
	fn is_empty(&self) -> bool {
		match self {
			Self::Live(files) => files.is_empty(),
			Self::Captured(files) => files.is_empty(),
		}
	}
}
/// A recording whose file bytes are still arriving from their source. The
/// worker keeps answering everything else meanwhile and stores the record
/// when the last byte lands, so one slow or vanished source never holds
/// history reads behind it.
struct Capturing<P: Platform> {
	abort: tokio::task::AbortHandle,
	erased: bool,
	record: Record,
	nick: String,
	writer: Keeper<P>,
	files: FileRecording,
	answer: Answer<Recorded>,
	/// Admission charged until the record is stored or refused.
	_custody: Custody,
}
pub struct Worker<B, P: Platform> {
	state: Rc<State<P>>,
	requests: Queue<Pending<P>>,
	finished: watch::Sender<Option<Report>>,
	backend: B,
	sources: rooms_glowcap::client::sources::Sources<P>,
	targets: Targets<P>,
	erase_required: bool,
	erase_source_required: Option<rooms_application::text::DocumentText>,
	standings: rooms_application::archive::recording::Standings,
	issuer: Option<Issuer>,
	captures: JoinSet<Result<Vec<capture::Captured>, Error>>,
	capturing: HashMap<Id, Capturing<P>>,
}
fn peer_unavailable() -> Error {
	Error::closed("the selected archive peer is unavailable")
}
impl<B: Backend, P: Platform> Worker<B, P> {
	/// The selected peer is lost: later work refuses as closed, with the cause
	/// in the sentence the session shows as its selection issue.
	fn selected_peer_unavailable(&mut self, cause: impl std::fmt::Display) -> Error {
		self.targets.mark_selected_unavailable();
		let reason = format!("the selected archive peer is unavailable: {cause}");
		let issue = Some(rooms_application::failure::reason_prefix(&reason).to_owned());
		if *self.state.selection_issue.borrow() != issue {
			*self.state.selection_issue.borrow_mut() = issue;
			self.state.status.send_replace(());
		}
		let _ = self.state.changes.send(rooms_application::archive::change::Change::All);
		Error::closed(reason)
	}
	pub(super) fn new(
		runtime: Rc<Runtime>,
		backend: B,
		state: Rc<State<P>>,
		requests: mpsc::Receiver<Pending<P>>,
		finished: watch::Sender<Option<Report>>,
	) -> Self {
		Self {
			state: state.clone(),
			requests: Queue::new(requests),
			finished,
			backend,
			sources: rooms_glowcap::client::sources::Sources::new(state.platform.clone()),
			targets: Targets::new(state.platform.clone(), runtime),
			erase_required: false,
			erase_source_required: None,
			standings: Default::default(),
			issuer: None,
			captures: JoinSet::new(),
			capturing: HashMap::new(),
		}
	}
	pub fn with_issuer(mut self, host: Host, locator: Locator, entropy: [u8; Host::DURABLE_ENTROPY_BYTES]) -> Self {
		self.issuer = Some(Issuer::new(host, locator, entropy));
		self
	}
	pub async fn run(mut self) -> Report {
		let mut stop = self.state.stop.subscribe();
		let mut report = Report::default();
		if let Err(error) = self.restore_issued().await {
			report.refused += 1;
			report.restore_failure = Some(error.to_string());
		}
		loop {
			if *stop.borrow() {
				self.requests.close();
			}
			let notify = self.targets.notify.clone();
			let pending = tokio::select! {
				pending = self.requests.next() => pending,
				Some(landed) = self.captures.join_next_with_id(), if !self.captures.is_empty() => {
					self.captured(landed, &mut report).await;
					report.cleanup_failures += self.targets.collect(false).await;
					continue;
				}
				_ = stop.changed(), if !self.requests.is_closed() => continue,
				_ = notify.notified() => {
					if self.targets.selected_closed() {
						self.selected_peer_unavailable("the archive connection closed");
					}
					report.cleanup_failures += self.targets.collect(false).await;
					continue;
				}
			};
			let Some(Pending { command, _permit }) = pending else {
				break;
			};
			match command {
				Command::SharedReader(mut request) => {
					let result = self.shared_reader(&request).await.map(Argument::Reference);
					resolve(&mut request.reply, result, &mut report);
				}
				Command::SharedRead(work, reader, offset, maximum, mut reply) => {
					let result = self
						.shared_read(&work, &reader, offset, maximum)
						.await
						.map(Argument::Bytes);
					resolve(&mut reply, result, &mut report);
				}
				Command::BlobReader(digest, answer) => {
					let result = match self.local_ready().await {
						Ok(()) => {
							match rooms_application::archive::Facet::new(
								Filter::default(),
								rooms_application::archive::Access::Read,
							) {
								Ok(facet) => self.backend.blob_reader(facet, digest).await,
								Err(error) => Err(Error::invalid_by(error)),
							}
						}
						Err(e) => Err(e),
					};
					complete(answer, result, &mut report);
				}
				Command::ReadBlob(reader, offset, maximum, answer) => {
					let result = match self.local_ready().await {
						Ok(()) => self
							.backend
							.read_blob(reader, offset, maximum)
							.await
							.and_then(|bytes| crate::archive::checked_bytes(bytes, maximum)),
						Err(e) => Err(e),
					};
					complete(answer, result, &mut report);
				}

				Command::Lend(session, facet, answer) => {
					let source = match &self.targets.selected {
						Selection::Local => Ok(Keeper::Local(Local {
							owner: Rc::downgrade(&self.state),
						})),
						Selection::Peer(peer) => Ok(Keeper::Peer(peer.lease())),
						Selection::Unavailable(_) => Err(peer_unavailable()),
					};
					let result = source.and_then(|source| Work::selected(&self.state, source).spawn(&session, facet));
					complete(answer, result, &mut report);
				}
				Command::SharedPage(work, filter, after, limit, mut reply) => {
					let result = self.shared_page(&work, &filter, after, limit).await.and_then(|page| {
						rooms_glowcap::archive::page_row(&page, &filter, after, limit).map_err(Error::invalid_by)
					});
					let delivered = match result {
						Ok(page) => {
							report.completed += 1;
							reply.fulfill(&page)
						}
						Err(error) => {
							report.refused += 1;
							reply.break_with(&error.into_refusal())
						}
					};
					if delivered.is_err() {
						report.lost_replies += 1;
					}
				}
				Command::Share(share, answer) => complete(answer, self.issue_share(share).await, &mut report),
				Command::Revoke(id, answer) => complete(answer, self.revoke_share(id).await, &mut report),
				Command::Shares(answer) => {
					let result = match &self.targets.selected {
						Selection::Peer(peer) => peer.archive.shares().await.map_err(Error::peer),
						_ => Err(Error::refused(
							"a selected archive peer is required to list durable shares",
						)),
					};
					complete(answer, result, &mut report);
				}
				Command::Issued(answer) => complete(answer, self.issued_shares().await, &mut report),
				Command::Select(link, answer) => {
					let result = self.targets.select(link).await;
					let issue = result
						.as_ref()
						.err()
						.map(|reason| rooms_application::failure::reason_prefix(&reason.to_string()).to_owned());
					if *self.state.selection_issue.borrow() != issue {
						*self.state.selection_issue.borrow_mut() = issue;
						self.state.status.send_replace(());
					}
					if !matches!(result, Ok(false)) {
						let _ = self.state.changes.send(rooms_application::archive::change::Change::All);
					}
					complete(answer, result.map(|_| ()), &mut report);
				}
				Command::Prepare(link, answer) => complete(answer, self.targets.prepare(link).await, &mut report),
				Command::Clear(answer) => {
					// An erasure covers every line admitted before it, including
					// those whose bytes are still arriving; they land refused.
					self.captures.abort_all();
					for capture in self.capturing.values_mut() {
						capture.erased = true;
					}
					self.erase_required = true;
					let result = self.local_ready().await;
					complete(answer, result, &mut report);
				}
				Command::ClearSource(source, answer) => {
					let result = async {
						self.local_ready().await?;
						for capture in self
							.capturing
							.values_mut()
							.filter(|capture| capture.record.coordinates().source == source)
						{
							capture.erased = true;
							capture.abort.abort();
						}
						self.erase_source_required = Some(source);
						self.local_ready().await
					}
					.await;
					complete(answer, result, &mut report);
				}
				Command::Record(destination, record, nick, capture, files, answer) => match capture {
					None => {
						let result = match self.recording_writer(destination).await {
							Ok(writer) => self.store(&writer, record, &nick, Vec::new(), files, &mut report).await,
							Err(error) => Err(error),
						};
						recorded(answer, result, &mut report);
					}
					Some(capture) => match self.recording_writer(destination).await {
						Ok(writer) => {
							let abort = self.captures.spawn_local(capture.finish());
							let id = abort.id();
							self.capturing.insert(
								id,
								Capturing {
									abort,
									erased: false,
									record,
									nick,
									writer,
									files,
									answer,
									_custody: _permit,
								},
							);
						}
						Err(error) => {
							capture.discard().await;
							complete(answer, Err(error), &mut report);
						}
					},
				},
				Command::Put(record, sources, answer) => {
					let result = match self.selected_writer() {
						Ok(writer) => self.put(&writer, record, Files::Live(sources), &mut report).await,
						Err(error) => Err(error),
					};
					complete(answer, result, &mut report);
				}
				Command::Read(filter, answer) => {
					let result = self.read(filter).await.map(|view| view.records);
					complete(answer, result, &mut report);
				}
				Command::ReadView(filter, answer) => {
					let result = self.read(filter).await;
					complete(answer, result, &mut report);
				}
				Command::Page(filter, after, limit, answer) => {
					let result = self.page(filter, after, limit).await;
					complete(answer, result, &mut report);
				}
			}
			report.cleanup_failures += self.targets.collect(false).await;
		}
		// Closing does not wait on sources that may never answer; a line still
		// capturing is refused, and its owner hears that rather than nothing.
		self.captures.abort_all();
		while let Some(landed) = self.captures.join_next_with_id().await {
			self.captured(landed, &mut report).await;
		}
		report.cleanup_failures += self.targets.collect(true).await;
		if let Some(issuer) = &mut self.issuer {
			report.cleanup_failures += issuer.close();
		}
		self.finished.send_replace(Some(report.clone()));
		report
	}

	async fn shared_page(&mut self, work: &Work<P>, filter: &Filter, after: u64, limit: usize) -> Result<Page, Error> {
		work.check()?;
		let page = match &work.source {
			Keeper::Local(_) => {
				self.local_ready().await?;
				self.backend.read(filter, after, limit).await?
			}
			Keeper::Peer(peer) => peer.page(filter, after, limit).await?,
		};
		work.check()?;
		page.validate(filter, after, limit).map_err(invalid_page)?;
		Ok(page)
	}
	async fn page(&mut self, filter: Filter, after: u64, limit: usize) -> Result<Page, Error> {
		let page = match &self.targets.selected {
			Selection::Unavailable(_) => return Err(peer_unavailable()),
			Selection::Peer(peer) => peer.archive.read(&filter, after, limit).await.map_err(Error::peer)?,
			Selection::Local => {
				self.local_ready().await?;
				self.backend.read(&filter, after, limit).await?
			}
		};
		page.validate(&filter, after, limit).map_err(invalid_page)?;
		Ok(page)
	}
	async fn read(&mut self, filter: Filter) -> Result<HistoryView<P>, Error> {
		self.local_ready().await?;
		let mut scan = Scan::new(filter.clone()).map_err(Error::invalid_by)?;
		while !scan.is_complete() {
			let page = self.backend.read(scan.filter(), scan.after(), MAX_READ).await?;
			scan.push(page).map_err(invalid_page)?;
		}
		let local = scan.finish().map_err(invalid_page)?;
		let remote = match &self.targets.selected {
			Selection::Unavailable(_) => return Err(peer_unavailable()),
			Selection::Peer(peer) => peer.archive.read_all(&filter).await.map_err(Error::peer)?,
			Selection::Local => Vec::new(),
		};
		let local_keeper = Keeper::Local(Local {
			owner: Rc::downgrade(&self.state),
		});
		let peer_keeper = match &self.targets.selected {
			Selection::Peer(peer) => Keeper::Peer(peer.lease()),
			_ => local_keeper.clone(),
		};
		let accounts = [
			Account {
				keeper: &peer_keeper,
				writes: true,
				records: &remote,
			},
			Account {
				keeper: &local_keeper,
				writes: matches!(self.targets.selected, Selection::Local),
				records: &local,
			},
		];
		let kept = merge::merge(
			&accounts,
			Limits {
				accounts: 2,
				records: 2 * MAX_RECORDS,
			},
		)
		.map_err(|error| Error::exhausted(error.to_string()))?;
		let local = !local.is_empty();
		let peer = !remote.is_empty();
		let records = kept
			.into_iter()
			.map(|k| KeptRecord {
				record: k.record.clone(),
				keeper: k.keeper.clone(),
			})
			.collect();
		Ok(HistoryView { records, local, peer })
	}
}
/// A page the archive answered with that does not fit the read it answered
/// is the archive's failure, whichever archive it was.
fn invalid_page(error: impl std::fmt::Display) -> Error {
	Error::storage_message(error.to_string())
}
fn complete<T>(answer: Answer<T>, result: Result<T, Error>, report: &mut Report) {
	if result.is_ok() {
		report.completed += 1;
	} else {
		report.refused += 1;
	}
	if answer.send(result).is_err() {
		report.lost_replies += 1;
	}
}
fn resolve(reply: &mut glowcap::Resolver, result: Result<glowcap::Argument, Error>, report: &mut Report) {
	let delivered = match result {
		Ok(value) => match reply.fulfill_value(&value) {
			Ok(()) => {
				report.completed += 1;
				Ok(())
			}
			Err(error) => {
				report.refused += 1;
				reply.break_with(&error.to_string())
			}
		},
		Err(error) => {
			report.refused += 1;
			reply.break_with(&error.into_refusal())
		}
	};
	if delivered.is_err() {
		report.lost_replies += 1;
	}
}
/// `complete` for a recording, counting what it could not fully keep.
fn recorded(answer: Answer<Recorded>, result: Result<Recorded, Error>, report: &mut Report) {
	if let Ok(receipt) = &result {
		if receipt.standing.is_err() {
			report.partial_recordings += 1;
		}
		if matches!(receipt.files, FileRecording::MetadataOnly(_)) {
			report.metadata_only_recordings += 1;
		}
	}
	complete(answer, result, report);
}
/// How a capture landed without its bytes: cut off by this worker, or failed
/// by its source.
enum Cut {
	Cancelled,
	Failed(Error),
}

impl<B, P: Platform> Drop for Worker<B, P> {
	fn drop(&mut self) {
		self.state.stop.send_replace(true);
	}
}
