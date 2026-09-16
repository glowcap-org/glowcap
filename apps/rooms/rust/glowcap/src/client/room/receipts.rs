//! Pending payloads belong to the membership, not the future awaiting its
//! reply. A cancelled call can still receive its authoritative ordered receipt.
use super::*;
use rooms_application::{
	open_graph::Selection,
	room::{
		inbox::{Message, queue::Queue},
		message::{ChangeKind, LineMarker},
		receipt::{self, Receipt},
	},
};
use std::{collections::VecDeque, rc::Weak};

/// A single-use send identity, scoped to the membership that reserved it.
/// Reserving adds no allocation and retains no message body.
pub struct Request {
	id: u64,
	owner: Weak<std::cell::RefCell<messages::Delivery>>,
}
impl Request {
	pub fn id(&self) -> u64 {
		self.id
	}
	pub(super) fn consume(self, owner: &messages::Shared) -> Result<u64, Error> {
		if self.owner.as_ptr() != Rc::as_ptr(owner) {
			return Err(Error::Receipt(receipt::Error::InvalidRequest));
		}
		Ok(self.id)
	}
}

#[cfg(test)]
mod tests;

#[derive(Default)]
pub(super) struct Pending {
	next: u64,
	posts: VecDeque<(u64, Payload)>,
}
struct Payload {
	text: String,
	bytes: usize,
}
impl Pending {
	pub fn next(&mut self) -> Result<u64, Error> {
		let id = self.next;
		if id > receipt::MAX_REQUEST {
			return Err(Error::Receipt(receipt::Error::Exhausted));
		}
		self.next += 1;
		Ok(id)
	}
	pub fn clear(&mut self) {
		self.posts.clear();
	}
	pub fn insert(&mut self, id: u64, text: &str, queue: &mut Queue<Ref>) -> Result<(), Error> {
		if id >= self.next
			|| self.posts.iter().any(|(held, _)| *held == id)
			|| text.len() > rooms_application::room::line::MAX_LINE_BYTES
		{
			return Err(Error::Receipt(receipt::Error::InvalidRequest));
		}
		let bytes = text.len() + core::mem::size_of::<(u64, Payload)>();
		queue.reserve(bytes).map_err(|_| Error::Receipt(receipt::Error::Full))?;
		self.posts.push_back((
			id,
			Payload {
				text: text.into(),
				bytes,
			},
		));
		Ok(())
	}
	pub fn discard(&mut self, id: u64, queue: &mut Queue<Ref>) {
		if let Some(index) = self.posts.iter().position(|(held, _)| *held == id) {
			let (_, payload) = self.posts.remove(index).expect("located request");
			queue.release(payload.bytes);
		}
	}
	pub fn complete(
		&mut self,
		receipt: Receipt<'_, Ref>,
		queue: &mut Queue<Ref>,
	) -> Result<Message<String, Ref>, receipt::Error> {
		let index = self
			.posts
			.iter()
			.position(|(held, _)| *held == receipt.request)
			.ok_or(receipt::Error::Unknown)?;
		let previews = Selection::decode(receipt.text.unwrap_or(&self.posts[index].1.text), receipt.previews)
			.map_err(|_| receipt::Error::Malformed)?;
		let (_, payload) = self.posts.remove(index).expect("located request");
		queue.release(payload.bytes);
		let text = receipt.text.map(String::from).unwrap_or(payload.text);
		Ok(Message {
			metadata: Some(rooms_application::room::inbox::metadata::Metadata::Receipt(
				receipt.request,
			)),
			from: receipt.from.into(),
			text,
			previews,
			attachments: receipt.attachments,
			marker: Some(LineMarker {
				id: receipt.line,
				kind: ChangeKind::Said,
			}),
		})
	}
}

impl<D: Deadline + Tasks + Clone + 'static> Room<D> {
	/// Reserve a correlation identity before any asynchronous staging begins.
	pub fn next_request(&self) -> Result<Request, Error> {
		Ok(Request {
			id: self.inner.messages.borrow_mut().pending.next()?,
			owner: Rc::downgrade(&self.inner.messages),
		})
	}
	pub fn supports_retained(&self) -> bool {
		self.carries().is_some_and(|carries| carries.retained)
	}
	pub(super) async fn retained_post(
		&self,
		target: &Ref,
		verb: &'static str,
		text: &str,
		previews: &Selection,
		request: u64,
	) -> Result<Option<crate::client::posted_line::PostedLine<D>>, Error> {
		let empty = Selection::default();
		let previews = if self.carries().is_some_and(|c| c.previews) {
			previews
		} else {
			&empty
		};
		{
			let mut delivery = self.inner.messages.borrow_mut();
			let messages::Delivery { queue, pending, .. } = &mut *delivery;
			pending.insert(request, text, queue)?;
		}
		let selection = if previews.is_empty() {
			Argument::Boolean(false)
		} else {
			previews.encode().into()
		};
		let pending = self.inner.client.admitted_call(
			target,
			verb,
			&[text.into(), selection, Argument::Integer(request as i64)],
			"the room did not answer its retained post",
		);
		let pending = match pending {
			Ok(pending) => pending,
			Err(error) => {
				let mut delivery = self.inner.messages.borrow_mut();
				let messages::Delivery { queue, pending, .. } = &mut *delivery;
				pending.discard(request, queue);
				return Err(error);
			}
		};
		// Once admitted, inbox completion owns the body on both acceptance and
		// rejection. Losing or cancelling the reply observer cannot leak it.
		let reply = pending.await?;
		Ok(crate::client::posted_line::PostedLine::from_reply(
			self.inner.client.clone(),
			reply,
		))
	}
}
