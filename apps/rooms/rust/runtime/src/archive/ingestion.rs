//! A serial archive queue can serve committed-byte callbacks during ingestion.
//! Deferred commands keep their original admission permits and FIFO order.
use std::{collections::VecDeque, future::Future};
use tokio::sync::mpsc;

pub trait Request {
	fn reads_blob(&self) -> bool;
	fn fences_blob_reads(&self) -> bool;
}
pub trait Reads<P> {
	fn answer(&mut self, pending: P, fenced: bool) -> impl Future<Output = ()>;
}
pub struct Queue<P> {
	requests: mpsc::Receiver<P>,
	deferred: VecDeque<P>,
}
impl<P> Queue<P> {
	pub fn new(requests: mpsc::Receiver<P>) -> Self {
		Self {
			requests,
			deferred: VecDeque::new(),
		}
	}
	pub fn close(&mut self) {
		self.requests.close();
	}
	pub fn is_closed(&self) -> bool {
		self.requests.is_closed()
	}
	pub async fn next(&mut self) -> Option<P> {
		match self.deferred.pop_front() {
			Some(pending) => Some(pending),
			None => self.requests.recv().await,
		}
	}
}
impl<P: Request> Queue<P> {
	/// Ingestion owns its source waits. Only committed-byte reads may pass it;
	/// a queued erasure or revocation fences all later callbacks until applied.
	/// Admission must charge P until it is dropped, including while deferred.
	pub async fn during<T>(&mut self, writing: impl Future<Output = T>, reads: &mut impl Reads<P>) -> T {
		tokio::pin!(writing);
		let mut receiving = true;
		let mut fenced = self.deferred.iter().any(Request::fences_blob_reads);
		loop {
			tokio::select! {
				biased;
				result = &mut writing => return result,
				pending = self.requests.recv(), if receiving => {
					let Some(pending) = pending else { receiving = false; continue; };
					if pending.reads_blob() {
						reads.answer(pending, fenced).await;
					} else {
						fenced |= pending.fences_blob_reads();
						self.deferred.push_back(pending);
					}
				}
			}
		}
	}
}
