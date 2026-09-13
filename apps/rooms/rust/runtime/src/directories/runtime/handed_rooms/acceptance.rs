use super::*;
use crate::session::commands::Admission;
use rooms_application::{session::checkpoint::commands::Command, text::DocumentText};
use rooms_glowcap::client::stewardship::Stewardship;

pub const ACCEPTANCE_LIMIT: usize = 16;
pub const ACCEPTANCE_BYTES: usize = 2 * 1024 * 1024;
pub const OBSERVER_LIMIT: usize = 32;

pub struct Acceptance {
	job: Rc<Job>,
	_observer: Observer,
}
struct Observer(Rc<Cell<usize>>);
impl Drop for Observer {
	fn drop(&mut self) {
		self.0.set(self.0.get() - 1);
	}
}
pub(super) struct Job {
	operation: OperationId,
	base: u64,
	id: Id,
	conversation: Id,
	result: watch::Sender<Option<Result<u64, Error>>>,
	bytes: usize,
}
impl Acceptance {
	pub async fn wait(self) -> Result<u64, Error> {
		let mut result = self.job.result.subscribe();
		loop {
			if let Some(result) = result.borrow().clone() {
				return result;
			}
			result
				.changed()
				.await
				.map_err(|_| Error::closed("room acceptance ended without an outcome"))?;
		}
	}
}
impl<P: Platform> State<P> {
	pub(super) fn accept(
		&self,
		operation: OperationId,
		base: u64,
		id: Id,
		conversation: Id,
	) -> Result<Acceptance, Error> {
		self.require_open()?;
		if self.observers.get() == OBSERVER_LIMIT {
			return Err(Error::busy("too many room acceptance observers"));
		}
		self.observers.set(self.observers.get() + 1);
		let observer = Observer(self.observers.clone());
		let mut jobs = self.jobs.borrow_mut();
		jobs.retain(|job| job.strong_count() != 0);
		for job in jobs.iter().filter_map(Weak::upgrade) {
			if job.operation != operation {
				continue;
			}
			if job.result.borrow().as_ref().is_some_and(Result::is_err) {
				continue;
			}
			if job.id != id || job.conversation != conversation {
				return Err(Error::invalid("operation id was reused with different arguments"));
			}
			return Ok(Acceptance {
				job,
				_observer: observer,
			});
		}
		let bytes = core::mem::size_of::<Job>()
			+ operation.text().heap_bytes()
			+ id.text().heap_bytes()
			+ conversation.text().heap_bytes();
		let held: usize = jobs.iter().filter_map(Weak::upgrade).map(|job| job.bytes).sum();
		if jobs.len() == ACCEPTANCE_LIMIT || bytes > ACCEPTANCE_BYTES.saturating_sub(held) {
			return Err(Error::busy("the room acceptance queue is full"));
		}
		let job = Rc::new(Job {
			operation,
			base,
			id,
			conversation,
			result: watch::channel(None).0,
			bytes,
		});
		jobs.push(Rc::downgrade(&job));
		self.queued.borrow_mut().push(job.clone());
		self.changed.send_replace(());
		Ok(Acceptance {
			job,
			_observer: observer,
		})
	}
	async fn invitation(&self, attempt: &handoff::Acceptance<Live<P>>, job: &Job) -> Result<Admission<u64>, Error> {
		let row = attempt.held();
		let live = row.value();
		let cached = live.link.borrow().as_ref().map(|link| link.text().clone());
		let link = match cached {
			Some(link) => link,
			None => {
				let link = Stewardship::new(live.client.clone(), live.room.clone())
					.link()
					.await
					.map_err(Error::peer)?;
				let bearer =
					Bearer::new(link.into()).ok_or_else(|| Error::invalid("the handed room link is too large"))?;
				let link = bearer.text().clone();
				*live.link.borrow_mut() = Some(bearer);
				link
			}
		};
		let nick = self
			.commands
			.view()
			.read(|state| {
				state.checkpoint().map(|checkpoint| {
					checkpoint
						.directories()
						.find(|directory| directory.id == &row.view().directory)
						.map(|directory| directory.nick.text().clone())
				})
			})??
			.ok_or_else(|| Error::stale("the handed room directory has retired"))?;
		fn text(value: &DocumentText) -> Result<&str, Error> {
			value
				.as_str()
				.ok_or_else(|| Error::invalid("handed room metadata is not valid text"))
		}
		let invitation = rooms_glowcap::routes::received_room_link(
			text(job.id.text())?,
			text(&nick)?,
			text(row.view().label.text())?,
			text(row.view().from.text())?,
			text(&link)?,
		)
		.map_err(Error::invalid_by)?
		.encoded()
		.map_err(Error::invalid_by)?;
		Ok(self.commands.prepare_handed_invitation(
			job.operation.clone(),
			job.base,
			invitation,
			[job.id.text().clone(), job.conversation.text().clone()],
		)?)
	}
	async fn retired(&self, held: &Held<Live<P>>) {
		let mut changed = self.changed.subscribe();
		while self.current(held) {
			if changed.changed().await.is_err() {
				break;
			}
		}
	}
}
impl Job {
	pub(super) fn abandoned(&self) {
		if self.result.borrow().is_none() {
			self.result.send_replace(Some(Err(Error::closed(
				"room acceptance worker retired without observing completion",
			))));
		}
	}
	pub(super) async fn run<P: Platform>(self: Rc<Self>, state: Rc<State<P>>) {
		let result = self.execute(&state).await;
		self.result.send_replace(Some(result));
	}
	async fn execute<P: Platform>(&self, state: &State<P>) -> Result<u64, Error> {
		let args = [self.id.text().clone(), self.conversation.text().clone()];
		let material = Command::AcceptInvitation.material(&args).map_err(Error::invalid_by)?;
		let committed = state
			.commands
			.inspect_command(self.operation.clone(), self.base, material)?
			.send()?
			.wait()
			.await?;
		if let Some(revision) = committed {
			return Ok(revision);
		}
		state.reconcile();
		let attempt = state.rows.borrow().begin(&self.id).map_err(Error::stale_by)?;
		let admission = tokio::select! {
			_ = state.retired(attempt.held()) => return Err(Error::stale_by(handoff::Error::Missing)),
			admission = state.invitation(&attempt, self) => admission?,
		};
		if !state.current(attempt.held()) {
			return Err(Error::stale_by(handoff::Error::Missing));
		}
		// Sending the validated bearer is the durable admission boundary. Keep
		// observing its transaction even after decline, disconnect, or shutdown.
		let revision = admission.send()?.wait().await?;
		if state.rows.borrow_mut().complete(&attempt) {
			state.changed.send_replace(());
		}
		Ok(revision)
	}
}
