use super::{issuer::Issuer, share::Work, *};
use crate::archive::{
	ingestion::{self, Queue, Reads},
	BlobAccess,
};
use glowcap::{Host, Locator};
use rooms_application::archive::{
	index::Scan,
	merge::{self, Account, Limits},
	MAX_READ, MAX_RECORDS,
};
use std::collections::HashMap;
use targets::{Selection, Targets};
use tokio::task::{Id, JoinError, JoinSet};
mod shares;
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
struct Capturing {
	record: Record,
	nick: String,
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
	standings: rooms_application::archive::recording::Standings,
	issuer: Option<Issuer>,
	captures: JoinSet<Result<Vec<capture::Captured>, String>>,
	capturing: HashMap<Id, Capturing>,
}
impl<B: Backend, P: Platform> Worker<B, P> {
	fn selected_peer_unavailable(&mut self, cause: String) -> String {
		self.targets.mark_selected_unavailable();
		let reason = format!("the selected archive peer is unavailable: {cause}");
		let issue = Some(rooms_application::failure::reason_prefix(&reason).to_owned());
		if *self.state.selection_issue.borrow() != issue {
			*self.state.selection_issue.borrow_mut() = issue;
			self.state.status.send_replace(());
		}
		let _ = self.state.changes.send(rooms_application::archive::change::Change::All);
		reason
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
			report.restore_failure = Some(error);
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
						self.selected_peer_unavailable("the archive connection closed".into());
					}
					report.cleanup_failures += self.targets.collect(false).await;
					continue;
				}
			};
			let Some(Pending { command, _permit }) = pending else {
				break;
			};
			match command {
				Command::BlobReader(digest, answer) => {
					let result = match self.local_ready().await {
						Ok(()) => {
							self.backend
								.blob_reader(
									rooms_application::archive::Facet::new(
										Filter::default(),
										rooms_application::archive::Access::Read,
									)
									.unwrap(),
									digest,
								)
								.await
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
						Selection::Unavailable(why) => Err(why.clone()),
					};
					let result = source.and_then(|source| Work::selected(&self.state, source).spawn(&session, facet));
					complete(answer, result, &mut report);
				}
				Command::SharedPage(work, filter, after, limit, mut reply) => {
					let result = self.shared_page(&work, &filter, after, limit).await.and_then(|page| {
						rooms_glowcap::archive::page_row(&page, &filter, after, limit).map_err(|e| e.to_string())
					});
					let delivered = match result {
						Ok(page) => {
							report.completed += 1;
							reply.fulfill(&page)
						}
						Err(error) => {
							report.refused += 1;
							reply.break_with(&error)
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
						Selection::Peer(peer) => peer.archive.shares().await.map_err(|e| e.to_string()),
						_ => Err("a selected archive peer is required to list durable shares".into()),
					};
					complete(answer, result, &mut report);
				}
				Command::Issued(answer) => complete(answer, self.issued_shares().await, &mut report),
				Command::Select(link, answer) => {
					let result = self.targets.select(link).await;
					let issue = result
						.as_ref()
						.err()
						.map(|reason| rooms_application::failure::reason_prefix(reason).to_owned());
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
					self.erase_required = true;
					let result = self.local_ready().await;
					complete(answer, result, &mut report);
				}
				Command::Record(record, nick, capture, files, answer) => match capture {
					None => {
						let result = self.store(record, &nick, Vec::new(), files, &mut report).await;
						recorded(answer, result, &mut report);
					}
					Some(capture) => match self.target_ready().await {
						Ok(()) => {
							let id = self.captures.spawn_local(capture.finish()).id();
							self.capturing.insert(
								id,
								Capturing {
									record,
									nick,
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
					let result = self.put(record, Files::Live(sources), &mut report).await;
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
	/// Store a recording whose capture landed. Bytes the source could not
	/// deliver leave the line archived without them, the same line the room
	/// keeps; a capture cut short by an erasure or by closing is refused.
	async fn captured(
		&mut self,
		landed: Result<(Id, Result<Vec<capture::Captured>, String>), JoinError>,
		report: &mut Report,
	) {
		let (id, outcome) = match landed {
			Ok((id, Ok(captured))) => (id, Ok(captured)),
			Ok((id, Err(reason))) => (id, Err(Cut::Failed(reason))),
			Err(error) if error.is_cancelled() => (error.id(), Err(Cut::Cancelled)),
			Err(error) => (error.id(), Err(Cut::Failed(error.to_string()))),
		};
		let Some(Capturing {
			record,
			nick,
			files,
			answer,
			_custody,
		}) = self.capturing.remove(&id)
		else {
			unreachable!("every capture task parks its recording");
		};
		let result = match outcome {
			Ok(captured) => self.store(record, &nick, captured, files, report).await,
			Err(Cut::Failed(reason)) => {
				let files = FileRecording::MetadataOnly(MetadataReason::SourceFailed(reason));
				self.store(record, &nick, Vec::new(), files, report).await
			}
			Err(Cut::Cancelled) => Err("the archive let this line go before its file bytes arrived".into()),
		};
		recorded(answer, result, report);
	}
	async fn local_ready(&mut self) -> Result<(), String> {
		if self.erase_required {
			self.backend.clear().await?;
			self.standings.clear();
			self.erase_required = false;
			let _ = self.state.changes.send(rooms_application::archive::change::Change::All);
		}
		Ok(())
	}
	/// Whether the selected target can take a recording now.
	async fn target_ready(&mut self) -> Result<(), String> {
		match &self.targets.selected {
			Selection::Local => self.local_ready().await,
			Selection::Unavailable(_) => Err("the selected archive peer is unavailable".into()),
			Selection::Peer(_) => Ok(()),
		}
	}
	/// Write one recording and its standing to the selected target.
	async fn store(
		&mut self,
		record: Record,
		nick: &str,
		captured: Vec<capture::Captured>,
		files: FileRecording,
		report: &mut Report,
	) -> Result<Recorded, String> {
		self.target_ready().await?;
		let standing = match &self.targets.selected {
			Selection::Local => self.standings.prepare(&record, nick),
			Selection::Peer(peer) => peer.standings.borrow().prepare(&record, nick),
			Selection::Unavailable(_) => return Err("the selected archive peer is unavailable".into()),
		}
		.map_err(|e| e.to_string())?;
		let revision = self.put(record, Files::Captured(captured), report).await?;
		let standing = match standing {
			None => Ok(None),
			Some(standing) => match self.put(standing.clone(), Files::Live(Vec::new()), report).await {
				Err(error) => Err(error),
				Ok(revision) => {
					match &self.targets.selected {
						Selection::Local => self.standings.remember(standing),
						Selection::Peer(peer) => peer.standings.borrow_mut().remember(standing),
						Selection::Unavailable(_) => unreachable!("selection cannot overtake an admitted recording"),
					}
					.expect("prepared standing has validated kind");
					Ok(Some(revision))
				}
			},
		};
		Ok(Recorded {
			revision,
			standing,
			files,
		})
	}
	async fn put(&mut self, record: Record, sources: Files<P>, report: &mut Report) -> Result<u64, String> {
		let change = rooms_application::archive::change::Change::of(&record);
		if matches!(self.targets.selected, Selection::Local) {
			self.local_ready().await?;
		}
		let mut reads = ReadReplies {
			reads: self.backend.blob_access(),
			report,
			erase_required: self.erase_required,
		};
		let mut peer_failed = false;
		let result: Result<u64, String> = match &self.targets.selected {
			Selection::Unavailable(_) => Err("the selected archive peer is unavailable".into()),
			Selection::Peer(peer) => {
				let result = if sources.is_empty() {
					peer.archive.put(&record).await
				} else {
					match sources {
						Files::Live(sources) => {
							let attachments: Vec<_> = sources.iter().map(|s| s.attachment().clone()).collect();
							self.requests
								.during(peer.archive.put_files(&record, &attachments), &mut reads)
								.await
						}
						Files::Captured(sources) => {
							let sources = sources.into_iter().map(capture::Captured::into_source).collect();
							self.requests
								.during(peer.archive.put_sources(&self.sources, &record, sources), &mut reads)
								.await
						}
					}
				};
				result.map_err(|error| {
					peer_failed = error.connection_failed();
					error.to_string()
				})
			}
			Selection::Local => {
				if sources.is_empty() {
					self.backend.put(record).await
				} else {
					match sources {
						Files::Live(sources) => {
							self.requests
								.during(self.backend.put_files(record, &sources), &mut reads)
								.await
						}
						Files::Captured(sources) => {
							self.requests
								.during(self.backend.put_files(record, &sources), &mut reads)
								.await
						}
					}
				}
			}
		};
		let result = result.map_err(|error| {
			if peer_failed {
				self.selected_peer_unavailable(error)
			} else {
				error
			}
		});
		let revision = result.and_then(|revision| {
			rooms_application::fields::SafeInteger::<true>::new(revision)
				.map(|n| n.get())
				.ok_or_else(|| "archive backend returned an invalid revision".into())
		})?;
		if let Some(change) = change {
			let _ = self.state.changes.send(change);
		}
		Ok(revision)
	}

	async fn shared_page(&mut self, work: &Work<P>, filter: &Filter, after: u64, limit: usize) -> Result<Page, String> {
		work.check()?;
		let page = match &work.source {
			Keeper::Local(_) => {
				self.local_ready().await?;
				self.backend.read(filter, after, limit).await?
			}
			Keeper::Peer(peer) => peer.page(filter, after, limit).await?,
		};
		work.check()?;
		page.validate(filter, after, limit).map_err(|e| e.to_string())?;
		Ok(page)
	}
	async fn page(&mut self, filter: Filter, after: u64, limit: usize) -> Result<Page, String> {
		let page = match &self.targets.selected {
			Selection::Unavailable(_) => return Err("the selected archive peer is unavailable".into()),
			Selection::Peer(peer) => peer
				.archive
				.read(&filter, after, limit)
				.await
				.map_err(|e| e.to_string())?,
			Selection::Local => {
				self.local_ready().await?;
				self.backend.read(&filter, after, limit).await?
			}
		};
		page.validate(&filter, after, limit).map_err(|e| e.to_string())?;
		Ok(page)
	}
	async fn read(&mut self, filter: Filter) -> Result<HistoryView<P>, String> {
		self.local_ready().await?;
		let mut scan = Scan::new(filter.clone()).map_err(|e| e.to_string())?;
		while !scan.is_complete() {
			let page = self.backend.read(scan.filter(), scan.after(), MAX_READ).await?;
			scan.push(page).map_err(|e| e.to_string())?;
		}
		let local = scan.finish().map_err(|e| e.to_string())?;
		let remote = match &self.targets.selected {
			Selection::Unavailable(_) => return Err("the selected archive peer is unavailable".into()),
			Selection::Peer(peer) => peer.archive.read_all(&filter).await.map_err(|e| e.to_string())?,
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
		.map_err(|e| e.to_string())?;
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
fn complete<T>(answer: Answer<T>, result: Result<T, String>, report: &mut Report) {
	if result.is_ok() {
		report.completed += 1;
	} else {
		report.refused += 1;
	}
	if answer.send(result).is_err() {
		report.lost_replies += 1;
	}
}
/// `complete` for a recording, counting what it could not fully keep.
fn recorded(answer: Answer<Recorded>, result: Result<Recorded, String>, report: &mut Report) {
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
	Failed(String),
}

impl<B, P: Platform> Drop for Worker<B, P> {
	fn drop(&mut self) {
		self.state.stop.send_replace(true);
	}
}

impl<P: Platform> ingestion::Request for Pending<P> {
	fn reads_blob(&self) -> bool {
		matches!(self.command, Command::ReadBlob(..))
	}
	fn fences_blob_reads(&self) -> bool {
		matches!(self.command, Command::Clear(_) | Command::Revoke(..))
	}
}
struct ReadReplies<'a, R> {
	reads: R,
	report: &'a mut Report,
	erase_required: bool,
}
impl<R: BlobAccess, P: Platform> Reads<Pending<P>> for ReadReplies<'_, R> {
	async fn answer(&mut self, pending: Pending<P>, fenced: bool) {
		let Command::ReadBlob(reader, offset, maximum, answer) = pending.command else {
			unreachable!("classified blob read")
		};
		let result = if fenced || self.erase_required {
			Err("archive byte reads are fenced by queued erasure or revocation".into())
		} else {
			self.reads
				.read(reader, offset, maximum)
				.await
				.and_then(|bytes| crate::archive::checked_bytes(bytes, maximum))
		};
		complete(answer, result, self.report);
	}
}
