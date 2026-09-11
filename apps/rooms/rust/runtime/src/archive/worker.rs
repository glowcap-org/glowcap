use super::ingestion::Queue;
use super::*;
use rooms_application::fields::SafeInteger;
use rooms_glowcap::client::files::{capture::Captured as Bytes, File};
use std::collections::HashMap;
use tokio::task::{Id, JoinError, JoinSet};
enum Answer {
	Data(Argument),
	Capability(Ref),
}
fn revision(revision: u64) -> Result<Answer, String> {
	SafeInteger::<true>::new(revision).ok_or_else(|| "archive backend returned an invalid revision".to_string())?;
	Ok(Answer::Data(Argument::Integer(revision as i64)))
}
/// Backend completion and reply settlement are separate facts. A failed reply
/// does not turn a committed write into a failed write or stop sibling callers.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
	pub completed: u64,
	pub refused: u64,
	pub reply_failures: u64,
	pub publication_failures: u64,
}
/// A file put whose bytes are still arriving from the caller's sources. The
/// worker keeps answering every other caller while they do, and stores the
/// record when the last byte lands, so one slow caller holds only its own put.
struct Filing {
	record: Record,
	authority: Authority,
	reply: Reply,
	_permit: Permit,
	_files: FilePermit,
}
pub struct Worker<B, P: Platform> {
	pub(super) state: Rc<State<P>>,
	requests: Queue<Pending<P>>,
	finished: watch::Sender<Option<Report>>,
	pub(super) backend: B,
	pub(super) publications: Option<publications::Publications>,
	captures: JoinSet<Result<Vec<Bytes>, String>>,
	capturing: HashMap<Id, Filing>,
}
impl<B: Backend, P: Platform> Worker<B, P> {
	pub(super) fn new(
		state: Rc<State<P>>,
		requests: mpsc::Receiver<Pending<P>>,
		finished: watch::Sender<Option<Report>>,
		backend: B,
	) -> Self {
		Self {
			state,
			requests: Queue::new(requests),
			finished,
			backend,
			publications: None,
			captures: JoinSet::new(),
			capturing: HashMap::new(),
		}
	}
	pub async fn run(mut self) -> Report {
		let mut stop = self.state.stop.subscribe();
		let mut report = Report::default();
		loop {
			if *stop.borrow() {
				self.requests.close();
			}
			let pending = tokio::select! {
				pending = self.requests.next() => pending,
				Some(landed) = self.captures.join_next_with_id(), if !self.captures.is_empty() => {
					self.landed(landed, &mut report).await;
					continue;
				}
				_ = stop.changed(), if !self.requests.is_closed() => continue,
			};
			let Some(Pending {
				request,
				authority,
				reply,
				_permit,
			}) = pending
			else {
				break;
			};
			if let Operation::Files { record, sources, files } = request {
				match authority.check() {
					Ok(()) => {
						let id = self.captures.spawn_local(capture(sources)).id();
						self.capturing.insert(
							id,
							Filing {
								record,
								authority,
								reply,
								_permit,
								_files: files,
							},
						);
					}
					Err(error) => complete(reply, Err(error), &mut report),
				}
				continue;
			}
			let answer = match authority.check() {
				Err(error) => Err(error),
				Ok(()) => match request {
					Operation::Clear => {
						// An erasure covers every record admitted before it, including
						// those whose bytes are still arriving; they land refused.
						self.captures.abort_all();
						self.backend.clear().await.map(|()| Answer::Data(Argument::Void))
					}
					Operation::Shares(request) => self.share_request(request).await.map(Answer::Data),
					Operation::Record(Request::Put(record)) => self.backend.put(record).await.and_then(revision),
					Operation::Record(Request::Read { filter, after, limit }) => {
						self.backend.read(&filter, after, limit).await.and_then(|page| {
							wire::page_row(&page, &filter, after, limit)
								.map(Answer::Data)
								.map_err(|e| e.to_string())
						})
					}
					Operation::Digest {
						scope,
						digest,
						session,
						receiver,
					} => match blob_host::reader_facet(scope.clone()) {
						Err(error) => Err(error),
						Ok(facet) => self
							.backend
							.blob_reader(facet, digest.clone())
							.await
							.and_then(|reader| reader.restrict(&scope, &digest).map_err(|e| e.to_string()))
							.and_then(|reader| {
								receiver
									.spawn_reader(session, reader, authority.descendant())
									.map(Answer::Capability)
							}),
					},
					Operation::ReadBlob {
						reader,
						offset,
						maximum,
					} => self
						.backend
						.read_blob(reader, offset, maximum)
						.await
						.and_then(|bytes| checked_bytes(bytes, maximum).map(Argument::Bytes).map(Answer::Data)),
					Operation::Files { .. } => unreachable!("file puts are captured before they reach the backend"),
					Operation::Record(_) => unreachable!("only storage operations enter the backend queue"),
				},
			};
			complete(reply, answer, &mut report);
		}
		// Closing does not wait on callers that may never finish sending; a put
		// still capturing is refused, and its caller hears that rather than nothing.
		self.captures.abort_all();
		while let Some(landed) = self.captures.join_next_with_id().await {
			self.landed(landed, &mut report).await;
		}
		if let Some(publications) = &mut self.publications {
			if publications.close().is_err() {
				report.publication_failures += 1;
			}
		}
		self.finished.send_replace(Some(report.clone()));
		report
	}
	/// Store a file put whose capture landed, or refuse it with what cut the
	/// capture short.
	async fn landed(&mut self, landed: Result<(Id, Result<Vec<Bytes>, String>), JoinError>, report: &mut Report) {
		let (id, outcome) = match landed {
			Ok((id, outcome)) => (id, outcome),
			Err(error) if error.is_cancelled() => (
				error.id(),
				Err("the archive let this record go before its file bytes arrived".into()),
			),
			Err(error) => (error.id(), Err(error.to_string())),
		};
		let Some(Filing {
			record,
			authority,
			reply,
			_permit,
			_files,
		}) = self.capturing.remove(&id)
		else {
			unreachable!("every capture task parks its filing");
		};
		let answer = match (authority.check(), outcome) {
			(Err(error), _) | (Ok(()), Err(error)) => Err(error),
			(Ok(()), Ok(captured)) => self.backend.put_files(record, &captured).await.and_then(revision),
		};
		complete(reply, answer, report);
	}
}
/// Take every byte of a put's files from their sources, one file at a time.
async fn capture<P: Platform>(sources: Vec<File<P>>) -> Result<Vec<Bytes>, String> {
	let mut captured = Vec::with_capacity(sources.len());
	for source in &sources {
		captured.push(Bytes::read(source).await?);
	}
	Ok(captured)
}
impl<B, P: Platform> Drop for Worker<B, P> {
	fn drop(&mut self) {
		self.state.stop.send_replace(true);
		self.requests.close();
		// Orderly completion reports cleanup failures. Abandonment still
		// revokes held descendants and attempts to release owned lookup names.
		if let Some(publications) = &mut self.publications {
			let _ = publications.close();
		}
	}
}

fn complete(reply: Reply, answer: Result<Answer, String>, report: &mut Report) {
	if answer.is_ok() {
		report.completed = report.completed.saturating_add(1);
	} else {
		report.refused = report.refused.saturating_add(1);
	}
	let settled = match reply {
		Reply::Remote(mut reply) => match answer {
			Ok(Answer::Data(value)) => reply.fulfill(&value).map_err(|_| ()),
			Ok(Answer::Capability(reference)) => reply.fulfill_value(&reference.into()).map_err(|_| ()),
			Err(error) => reply
				.break_with(rooms_application::failure::reason_prefix(&error))
				.map_err(|_| ()),
		},
		Reply::Clear(reply) => reply
			.send(answer.map(|answer| match answer {
				Answer::Data(Argument::Void) => (),
				_ => unreachable!("local erasure completion"),
			}))
			.map_err(|_| ()),
	};
	if settled.is_err() {
		report.reply_failures = report.reply_failures.saturating_add(1);
	}
}
