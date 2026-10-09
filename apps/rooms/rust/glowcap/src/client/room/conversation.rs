//! Conversation calls use membership authority; returned line capabilities
//! have their own lifetime and can be delegated independently.
use super::*;
use crate::client::posted_line::PostedLine;
use rooms_application::room::history::{self, History};

impl<D: Deadline + Tasks + Clone + 'static> Room<D> {
	/// Whether the previews verbs are worth sending: the room said it carries
	/// previews. A room that said nothing gets the plain verb, which every
	/// room answers, so the previews are dropped rather than the line.
	fn supports_preview_messages(&self) -> bool {
		self.carries().is_some_and(|carries| carries.previews)
	}

	pub async fn stage(
		&self,
		description: rooms_application::files::FileDescription,
	) -> Result<crate::client::files::Upload<D>, Error> {
		crate::client::files::Upload::stage(
			self.inner.client.clone(),
			&self.files()?,
			description,
			self.supports_retained(),
		)
		.await
	}
	pub fn file(
		&self,
		attachment: rooms_application::room::attachment::Attachment<Ref>,
	) -> crate::client::files::File<D> {
		crate::client::files::File::new(self.inner.client.clone(), attachment)
	}
	pub async fn say(&self, text: &str) -> Result<Option<PostedLine<D>>, Error> {
		self.say_with_previews(text, &rooms_application::open_graph::Selection::default())
			.await
	}
	pub async fn say_with_previews(
		&self,
		text: &str,
		previews: &rooms_application::open_graph::Selection,
	) -> Result<Option<PostedLine<D>>, Error> {
		self.say_retained(text, previews, self.next_request()?).await
	}
	pub async fn say_retained(
		&self,
		text: &str,
		previews: &rooms_application::open_graph::Selection,
		request: Request,
	) -> Result<Option<PostedLine<D>>, Error> {
		let request = request.consume(&self.inner.messages)?;
		if self.supports_retained() {
			return self
				.retained_post(
					&self.seat()?,
					rooms_application::room::receipt::POST,
					text,
					previews,
					request,
				)
				.await;
		}
		let supported = !previews.is_empty() && self.supports_preview_messages();
		let encoded = if supported { previews.encode() } else { String::new() };
		let fields: &[&str] = if supported { &[text, &encoded] } else { &[text] };
		let reply = self
			.inner
			.client
			.ask(
				&self.seat()?,
				if supported {
					rooms_application::open_graph::ROOM_POST_VERB
				} else {
					rooms_application::protocol_data::POST
				},
				fields,
				"the membership did not answer the line",
			)
			.await?;
		PostedLine::from_room_reply(self.inner.client.clone(), reply)
	}
	pub async fn post_files(&self, caption: &str) -> Result<Option<PostedLine<D>>, Error> {
		self.post_files_with_previews(caption, &rooms_application::open_graph::Selection::default())
			.await
	}
	pub async fn post_files_with_previews(
		&self,
		caption: &str,
		previews: &rooms_application::open_graph::Selection,
	) -> Result<Option<PostedLine<D>>, Error> {
		self.post_files_retained(caption, previews, self.next_request()?).await
	}
	pub async fn post_files_retained(
		&self,
		caption: &str,
		previews: &rooms_application::open_graph::Selection,
		request: Request,
	) -> Result<Option<PostedLine<D>>, Error> {
		let request = request.consume(&self.inner.messages)?;
		if self.supports_retained() {
			return self
				.retained_post(
					&self.files()?,
					rooms_application::room::receipt::POST_FILES,
					caption,
					previews,
					request,
				)
				.await;
		}
		let supported = !previews.is_empty() && self.supports_preview_messages();
		let encoded = if supported { previews.encode() } else { String::new() };
		let fields: &[&str] = if supported { &[caption, &encoded] } else { &[caption] };
		let reply = self
			.inner
			.client
			.ask(
				&self.files()?,
				if supported {
					rooms_application::open_graph::ROOM_POST_FILES_VERB
				} else {
					rooms_application::protocol_data::POST_FILES
				},
				fields,
				"the room did not answer posting the files",
			)
			.await?;
		PostedLine::from_room_reply(self.inner.client.clone(), reply)
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
				history.push_with_previews(
					fields.first().and_then(Argument::as_str),
					fields.get(1).and_then(Argument::as_str),
					fields.get(2).and_then(number),
					fields.get(3).and_then(Argument::as_str),
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
		Argument::BigInteger { negative, digits } => digits
			.parse::<f64>()
			.ok()
			.map(|value| if *negative { -value } else { value }),
		_ => None,
	}
}
