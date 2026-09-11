use super::*;
use rooms_application::bridge::{self, Answers, Form};

impl<D: Deadline + Tasks + Clone + 'static> Room<D> {
	/// Fetch the membership's current form. An absent form and a refused call
	/// are distinct outcomes; no cached declaration stands in for the bridge.
	pub async fn bridge_form(&self) -> Result<Option<Form>, Error> {
		let answer = self
			.inner
			.client
			.call(
				&self.seat()?,
				bridge::ASK,
				&[],
				"the room did not answer its bridge form",
			)
			.await?;
		Ok(bridge::read_form(&Value(&answer.0))?)
	}
	pub async fn submit_bridge_form(&self, action: &str, answers: &Answers) -> Result<String, Error> {
		let seat = self.seat()?;
		let pending = {
			let args = [Argument::String(action.into()), Argument::String(answers.encode()?)];
			self.inner
				.client
				.call(&seat, bridge::SUBMIT, &args, "the room did not answer the bridge form")
		};
		let answer = pending.await?;
		Ok(match answer.0 {
			Argument::String(said) => said,
			_ => String::new(),
		})
	}
}
