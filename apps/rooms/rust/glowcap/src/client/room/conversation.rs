//! Conversation calls use membership authority; returned line capabilities
//! have their own lifetime and can be delegated independently.
use super::*;
use crate::client::posted_line::PostedLine;
use rooms_application::room::history::{self, History};

impl<D: Deadline + Tasks + Clone + 'static> Room<D> {
	pub async fn stage(
		&self,
		description: rooms_application::files::FileDescription,
	) -> Result<crate::client::files::Upload<D>, Error> {
		crate::client::files::Upload::stage(self.inner.client.clone(), &self.seat()?, description).await
	}
	pub fn file(
		&self,
		attachment: rooms_application::room::attachment::Attachment<Ref>,
	) -> crate::client::files::File<D> {
		crate::client::files::File::new(self.inner.client.clone(), attachment)
	}
	pub async fn say(&self, text: &str) -> Result<Option<PostedLine<D>>, Error> {
		let reply = self
			.inner
			.client
			.ask(&self.seat()?, "post", &[text], "the membership did not answer the line")
			.await?;
		Ok(PostedLine::from_reply(self.inner.client.clone(), reply))
	}
	pub async fn post_files(&self, caption: &str) -> Result<Option<PostedLine<D>>, Error> {
		let reply = self
			.inner
			.client
			.ask(
				&self.seat()?,
				"postFiles",
				&[caption],
				"the room did not answer posting the files",
			)
			.await?;
		Ok(PostedLine::from_reply(self.inner.client.clone(), reply))
	}
	pub async fn history(&self) -> Result<Vec<history::Line>, Error> {
		let reply = self
			.inner
			.client
			.call(
				&self.seat()?,
				history::VERB,
				&[],
				"the membership did not answer its history",
			)
			.await?;
		let mut history = History::default();
		if let Some(rows) = reply.0.as_list() {
			for row in rows {
				let Some(fields) = row.as_list() else {
					continue;
				};
				history.push(
					fields.first().and_then(Argument::as_str),
					fields.get(1).and_then(Argument::as_str),
					fields.get(2).and_then(number),
				)?;
			}
		}
		Ok(history.into_lines())
	}
}

// Numeric projection only: no timestamp policy or retained bignum copy. Rust's
// decimal-to-double conversion also handles integers outside i128, as JS does.
fn number(value: &Argument) -> Option<f64> {
	match value {
		Argument::Integer(value) => Some(*value as f64),
		Argument::Float(value) => Some(*value),
		Argument::BigInteger { negative, digits } => {
			digits
				.parse::<f64>()
				.ok()
				.map(|value| if *negative { -value } else { value })
		}
		_ => None,
	}
}
