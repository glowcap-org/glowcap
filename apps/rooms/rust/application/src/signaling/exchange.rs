//! Signaling exchanges bind one bounded offer and answer lifecycle to two peers.
use super::*;
/// Acceptance and answer settle independently. Platform failures use the same
/// owner as protocol refusals; E never changes a committed milestone.
pub struct Exchange<E> {
	started: bool,
	ended: bool,
	acceptance: Option<Result<Id, E>>,
	answer: Option<Result<Description, E>>,
	candidates: Queue<Candidate>,
}
impl<E> Default for Exchange<E> {
	fn default() -> Self {
		Self {
			started: false,
			ended: false,
			acceptance: None,
			answer: None,
			candidates: Default::default(),
		}
	}
}
impl<E: Clone + From<Error>> Exchange<E> {
	pub fn start(&mut self) -> Result<(), E> {
		if self.ended {
			return Err(Error::Ended.into());
		}
		if self.started {
			return Err(Error::Duplicate.into());
		}
		self.started = true;
		Ok(())
	}
	pub fn receive(&mut self, reply: Reply) -> Result<(), E> {
		if self.ended {
			return Err(Error::Ended.into());
		}
		match reply {
			Reply::Accepted(id) => {
				if self.acceptance.is_none() {
					self.acceptance = Some(Ok(id));
				}
			}
			Reply::Answer(answer) => {
				if self.started && self.answer.is_none() {
					self.answer = Some(Ok(answer));
				}
			}
			Reply::Rejected(reason) => self.fail(Error::Rejected(reason).into()),
			Reply::Candidate(candidate) => self.candidates.push(candidate).map_err(E::from)?,
		}
		Ok(())
	}
	pub fn fail(&mut self, error: E) {
		if self.ended {
			return;
		}
		if self.acceptance.is_none() {
			self.acceptance = Some(Err(error.clone()));
		}
		if self.answer.is_none() {
			self.answer = Some(Err(error));
		}
	}
	pub fn accepted(&self) -> Result<Option<Id>, E> {
		if self.ended {
			return Err(Error::Ended.into());
		}
		self.acceptance.clone().transpose()
	}
	pub fn settled(&self) -> Option<Result<(), E>> {
		if self.ended {
			return Some(Err(Error::Ended.into()));
		}
		if !self.started {
			return Some(Err(Error::NotStarted.into()));
		}
		match (&self.acceptance, &self.answer) {
			(Some(Err(e)), _) | (_, Some(Err(e))) => Some(Err(e.clone())),
			(Some(Ok(_)), Some(Ok(_))) => Some(Ok(())),
			_ => None,
		}
	}
	pub fn answer(&self) -> Result<Option<Description>, E> {
		match self.settled() {
			Some(Ok(())) => self.answer.clone().transpose(),
			Some(Err(e)) => Err(e),
			None => Ok(None),
		}
	}
	pub fn candidate(&mut self) -> Result<Option<Candidate>, E> {
		if self.ended {
			return Ok(None);
		}
		if let Some(Err(error)) = &self.acceptance {
			return Err(error.clone());
		}
		if let Some(Err(error)) = &self.answer {
			return Err(error.clone());
		}
		self.candidates.pop().map_err(E::from)
	}
	pub fn ended(&self) -> bool {
		self.ended
	}
	/// Transfer the known exchange ID once for signalDone, and retire buffers.
	pub fn retire(&mut self) -> Option<Id> {
		self.ended = true;
		self.answer = None;
		self.candidates = Default::default();
		self.acceptance.take().and_then(Result::ok)
	}
}
