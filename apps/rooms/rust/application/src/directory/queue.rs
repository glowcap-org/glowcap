//! A slow directory observer loses the whole view explicitly. Continuing after
//! a missing update would leave counts and registration identities misleading.
use super::{Error, Event, MAX_ROWS};
use alloc::collections::VecDeque;

#[derive(Default)]
pub struct Queue {
	events: VecDeque<Event>,
	ended: bool,
	failure: Option<Error>,
}
impl Queue {
	pub fn status(&self) -> Result<(), Error> {
		if let Some(error) = self.failure {
			Err(error)
		} else if self.ended {
			Err(Error::Closed)
		} else {
			Ok(())
		}
	}
	pub fn push(&mut self, event: Event) -> Result<(), Error> {
		self.status()?;
		if self.events.len() == MAX_ROWS {
			self.close();
			self.failure = Some(Error::Overflow);
			return Err(Error::Overflow);
		}
		self.events.push_back(event);
		Ok(())
	}
	pub fn pop(&mut self) -> Result<Option<Event>, Error> {
		if let Some(error) = self.failure {
			return Err(error);
		}
		if self.ended {
			return Err(Error::Closed);
		}
		Ok(self.events.pop_front())
	}
	pub fn close(&mut self) {
		self.ended = true;
		self.events = VecDeque::new();
	}
}
