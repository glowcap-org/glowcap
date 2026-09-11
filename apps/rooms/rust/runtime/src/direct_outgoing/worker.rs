use super::*;
use std::{
	future::{poll_fn, Future},
	pin::Pin,
	task::Poll,
};
type Operation = Pin<Box<dyn Future<Output = Result<Sent, Failure>>>>;
pub(super) struct Pending<P: Platform> {
	work: Operation,
	progress: Rc<Cell<Delivery>>,
	answer: oneshot::Sender<Result<Sent, Failure>>,
	_permit: Rc<Permit>,
	_busy: Busy<P>,
}
pub struct OutgoingWorker<P: Platform> {
	pub(super) routes: RouteReceiver<P>,
	pub(super) state: Rc<State<P>>,
	pub(super) sources: Rc<Sources<P>>,
	pub(super) media: MediaFiles<P>,
	pub(super) requests: mpsc::Receiver<Request<P>>,
	pub(super) stopping: watch::Receiver<bool>,
	pub(super) finished: watch::Sender<Option<Result<(), String>>>,
	pub(super) pending: Vec<Pending<P>>,
}
impl<P: Platform> OutgoingWorker<P> {
	/// The task owns delivery even after its caller abandons the receipt.
	/// Explicit shutdown observes media capture cancellation; Drop cannot.
	pub async fn run(mut self) -> Result<(), String> {
		let mut routes = self.routes.changes()?;
		loop {
			// Delegated edits own connection custody independently of the route.
			// Release retired conversations even when no further send arrives.
			self.state.rows.borrow_mut().retain(|row| row.context.current());
			if *self.stopping.borrow() || self.stopping.has_changed().is_err() {
				break;
			}
			tokio::select! {
				_ = self.stopping.changed() => {},
				change = routes.changed() => if change.is_err() { break; },
				request = self.requests.recv(), if self.pending.len() < OPERATION_LIMIT => {
					match request { Some(request) => self.begin(request), None => break }
				},
				(index, result) = ready(&mut self.pending) => {
					let pending = self.pending.remove(index);
					let _ = pending.answer.send(result);
					let remaining = self.pending.len();
					if remaining != 0 { self.pending.rotate_left(index % remaining); }
				}
			}
		}
		self.retire();
		for pending in self.pending.drain(..) {
			let _ = pending.answer.send(Err(failure(
				pending.progress.get(),
				"outgoing owner retired during delivery",
			)));
		}
		while let Ok(request) = self.requests.try_recv() {
			let _ = request.answer.send(Err(failure(
				Delivery::NotSent,
				"outgoing owner retired before delivery",
			)));
		}
		self.state.rows.borrow_mut().clear();
		let result = self.media.close().await;
		self.finished.send_replace(Some(result.clone()));
		result
	}
	fn begin(&mut self, request: Request<P>) {
		let Request {
			context,
			target,
			mut plan,
			event,
			progress,
			answer,
			_permit,
			_busy,
		} = request;
		let admitted = if context.current() {
			self.media.retain_sources(core::mem::take(&mut plan.fresh), &plan.kept)
		} else {
			Err("direct conversation retired before delivery".into())
		};
		let fresh = match admitted {
			Ok(files) => files,
			Err(error) => {
				let _ = answer.send(Err(failure(Delivery::NotSent, &error)));
				return;
			}
		};
		let mut files = core::mem::take(&mut plan.kept);
		let appended = files.len();
		files.extend(fresh);
		let selections: Vec<_> = files.iter().cloned().map(FileView::select).collect();
		// Pin new sources before yielding. Existing attachments need no read
		// for an edit or kept index; an expired preview cannot forbid those verbs.
		let captures: Vec<_> = files[appended..].iter().map(FileView::materialize).collect();
		let state = self.state.clone();
		let sources = self.sources.clone();
		let observed = progress.clone();
		let work = Box::pin(async move {
			let mut leases = Vec::with_capacity(captures.len());
			for capture in captures {
				leases.push(capture.await.map_err(|e| failure(Delivery::NotSent, &e))?);
			}
			if state.closed.get() || !context.current() {
				return Err(failure(
					Delivery::NotSent,
					"direct conversation retired before delivery",
				));
			}
			observed.set(Delivery::Uncertain);
			let result = match target {
				Target::Post(route) => if files.is_empty() {
					route.say(&plan.text).await
				} else {
					route
						.send_files(&plan.text, &sources, files.iter().map(FileView::source).collect())
						.await
				}
				.map(|line| line.map(Rc::new)),
				Target::Change(line) => {
					let result = match plan.kind {
						ChangeKind::Edited => line.edit(&plan.text).await,
						ChangeKind::Withdrawn if plan.keep.is_empty() && files.is_empty() => line.withdraw().await,
						_ => {
							line.refile_files(
								&plan.text,
								&plan.keep,
								&sources,
								files[appended..].iter().map(FileView::source).collect(),
							)
							.await
						}
					};
					result.map(|()| Some(line))
				}
			};
			let line = match result {
				Ok(line) => line,
				Err(error) => {
					// Keep actual authority for idempotent withdrawal, but refuse edits
					// and index-based changes until the peer's state is known.
					if let Some(row) = state
						.rows
						.borrow_mut()
						.iter_mut()
						.find(|r| r.id == event.id && r.context.same_context(&context))
					{
						row.uncertain = true;
					}
					return Err(failure(Delivery::Uncertain, &error.to_string()));
				}
			};
			observed.set(Delivery::Accepted);
			let id = event.id;
			let editable = line.is_some() && plan.kind != ChangeKind::Withdrawn;
			if state.closed.get() || !context.current() {
				return Err(failure(
					Delivery::Accepted,
					"peer accepted after local conversation retirement",
				));
			}
			event
				.commit(plan.text, plan.kind, files.clone(), editable)
				.map_err(|e| failure(Delivery::Accepted, &e))?;
			let mut rows = state.rows.borrow_mut();
			let previous = rows.iter().position(|r| r.id == id && r.context.same_context(&context));
			if plan.kind == ChangeKind::Withdrawn {
				if let Some(at) = previous {
					rows.remove(at);
				}
			} else {
				let row = Row {
					context,
					id,
					line,
					uncertain: false,
					files,
					_selections: selections,
				};
				if let Some(at) = previous {
					rows[at] = row;
				} else {
					rows.push(row);
				}
			}
			drop(leases);
			Ok(Sent { line: id, editable })
		});
		self.pending.push(Pending {
			work,
			progress,
			answer,
			_permit,
			_busy,
		});
	}
	fn retire(&mut self) {
		self.state.closed.set(true);
		self.requests.close();
	}
}
impl<P: Platform> Drop for OutgoingWorker<P> {
	fn drop(&mut self) {
		self.retire();
		self.state.rows.borrow_mut().clear();
	}
}
async fn ready<P: Platform>(pending: &mut [Pending<P>]) -> (usize, Result<Sent, Failure>) {
	poll_fn(|cx| {
		for (index, pending) in pending.iter_mut().enumerate() {
			if let Poll::Ready(result) = pending.work.as_mut().poll(cx) {
				return Poll::Ready((index, result));
			}
		}
		Poll::Pending
	})
	.await
}
