use super::*;
use crate::Value;
use std::{future::poll_fn, task::Poll};
impl<D: Deadline + Tasks + Clone + 'static> Sources<D> {
	pub(super) fn behavior(
		&self,
		lease: policy::Lease<Source>,
		host: glowcap::Host,
	) -> impl FnMut(Option<&str>, &[Argument]) -> Result<Argument, String> + 'static {
		let state = Rc::downgrade(&self.state);
		let platform = self.platform.clone();
		move |verb, args| {
			let verb = verb.ok_or("direct invocation is not supported")?;
			let blob = lease.blob();
			let [offset, length] = args else {
				return Err(policy::Error::Arguments.to_string());
			};
			let Some(read) = blob
				.read_call(verb, &[Value(offset), Value(length)])
				.map_err(|e| e.to_string())?
			else {
				return Ok(Argument::Bytes(Vec::new()));
			};
			let range = read.range();
			let future = match &read.source().0.backing {
				Backing::Frozen(captured) => {
					// The binding's reply owns its span. This one bounded copy does
					// not keep the full backing allocation alive after completion.
					let bytes = captured.span(range.start as u64, range.len())?.into_vec();
					read.finish(bytes.len()).map_err(|e| e.to_string())?;
					return Ok(Argument::Bytes(bytes));
				}
				Backing::Reader(reader) => reader.read(range.start, range.len()),
			};
			let owner = state.upgrade().ok_or("the source owner has closed")?;
			let session = glowcap::current_session().map_err(|e| e.to_string())?;
			let mut resolver = host.defer_turn().map_err(|e| e.to_string())?;
			let job = Rc::new(Job { done: Cell::new(false) });
			let completion = Completion {
				state: state.clone(),
				job: job.clone(),
			};
			let clock = platform.clone();
			let weak = state.clone();
			let task = platform.spawn(async move {
				let _completion = completion;
				let work = async {
					let result = clock
						.within(rooms_application::files::transfer::STALL_MS, future)
						.await
						.ok_or("the source stopped answering")?;
					let bytes = result?;
					read.finish(bytes.len()).map_err(|e| e.to_string())?;
					Ok::<_, String>(Argument::Bytes(bytes))
				};
				let closed = async move {
					match session {
						Some(session) => session.closed().await,
						None => std::future::pending().await,
					}
				};
				let (mut work, mut closed) = (std::pin::pin!(work), std::pin::pin!(closed));
				let result = poll_fn(|cx| {
					if closed.as_mut().poll(cx).is_ready() {
						return Poll::Ready(None);
					}
					work.as_mut().poll(cx).map(Some)
				})
				.await;
				let result = match result {
					None => return, // Resolver drop retires an already-closed answer.
					Some(Ok(value)) => resolver.fulfill(&value),
					Some(Err(reason)) => resolver.break_with(&reason),
				};
				if let (Err(error), Some(state)) = (result, weak.upgrade()) {
					let mut failure = state.failure.borrow_mut();
					if let Some(failure) = failure.as_mut() {
						failure.count = failure.count.saturating_add(1);
					} else {
						*failure = Some(Failure { first: error, count: 1 });
					}
				}
			});
			if !job.done.get() {
				owner.jobs.borrow_mut().push((job, task));
			}
			Ok(Argument::Void)
		}
	}
}
