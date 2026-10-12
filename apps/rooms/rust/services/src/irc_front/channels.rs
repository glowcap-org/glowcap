use super::output::Output;
use rooms_application::{
	room::inbox::{self, metadata::Presence},
	server::irc::{
		front,
		protocol::{self, fold},
	},
};
use rooms_glowcap::client::{
	directory::Directory,
	room::{Messages, Room, SubscribeOptions},
};
use rooms_platform::HostPlatform;
use std::{cell::RefCell, collections::BTreeMap, rc::Rc};
use tokio::{sync::watch, task::JoinHandle};
#[derive(Default)]
struct View {
	roster: BTreeMap<String, String>,
	topic: Option<String>,
}
pub(super) struct Channel {
	pub room: Room<HostPlatform>,
	pub channel: String,
	view: Rc<RefCell<View>>,
	stop: watch::Sender<bool>,
	pump: Option<JoinHandle<Result<(), String>>>,
}
impl Channel {
	pub async fn join(directory: &Directory<HostPlatform>, output: Output, channel: &str) -> Result<Self, String> {
		let name = front::room_name(channel)?;
		let reference = directory.enter(name).await.map_err(|e| e.to_string())?;
		let (room, messages) = Room::subscribe(
			directory.client().clone(),
			reference,
			&output.nick,
			SubscribeOptions::default(),
		)
		.await
		.map_err(|e| e.to_string())?;
		let view = Rc::new(RefCell::new(View::default()));
		let (stop, stopping) = watch::channel(false);
		let mut held = Self {
			room,
			channel: channel.into(),
			view: view.clone(),
			stop,
			pump: None,
		};
		if let Err(error) = output
			.send(
				"JOIN",
				&[channel],
				Some(&front::member_prefix(&output.nick, &output.server)),
			)
			.await
		{
			return Err(crate::cleanup::failed(
				error,
				held.room.leave().await.map_err(|e| e.to_string()),
			));
		}
		let channel = channel.to_owned();
		held.pump = Some(tokio::task::spawn_local(async move {
			let result = pump(messages, &output, &channel, view, stopping).await;
			if let Err(reason) = &result {
				output.writer.fail(reason.clone());
			}
			result
		}));
		Ok(held)
	}
	pub async fn names(&self, output: &Output) -> Result<(), String> {
		names(output, &self.channel, &self.view).await
	}
	pub fn topic(&self) -> Option<String> {
		self.view.borrow().topic.clone()
	}
	pub fn knows(&self, name: &str) -> bool {
		self.view.borrow().roster.contains_key(&name.to_lowercase())
	}
	pub async fn close(mut self) -> Result<(), String> {
		self.stop.send_replace(true);
		let mut result = self.room.leave().await.map_err(|e| e.to_string());
		if let Some(task) = self.pump.take() {
			result = crate::cleanup::combine(result, task.await.map_err(|e| e.to_string()).and_then(|r| r));
		}
		result
	}
}
impl Drop for Channel {
	fn drop(&mut self) {
		self.stop.send_replace(true);
		if let Some(task) = self.pump.take() {
			task.abort();
		}
	}
}
async fn names(output: &Output, channel: &str, view: &Rc<RefCell<View>>) -> Result<(), String> {
	let members: Vec<_> = std::iter::once(output.nick.clone())
		.chain(view.borrow().roster.values().cloned())
		.collect();
	let mut batch = String::new();
	for member in members {
		let nick = output.project(&member)?;
		let candidate = if batch.is_empty() {
			nick.clone()
		} else {
			format!("{batch} {nick}")
		};
		if protocol::encode_message("353", &[&output.nick, "=", channel, &candidate], Some(&output.server)).is_err()
			&& !batch.is_empty()
		{
			output.numeric("353", &[&output.nick, "=", channel, &batch]).await?;
			batch = nick;
		} else {
			batch = candidate;
		}
	}
	if !batch.is_empty() {
		output.numeric("353", &[&output.nick, "=", channel, &batch]).await?;
	}
	output
		.numeric("366", &[&output.nick, channel, "End of NAMES list"])
		.await
}
async fn pump(
	mut messages: Messages,
	output: &Output,
	channel: &str,
	view: Rc<RefCell<View>>,
	mut stop: watch::Receiver<bool>,
) -> Result<(), String> {
	loop {
		let item = tokio::select! {
			_ = stop.changed() => return Ok(()),
			item = messages.next() => item.map_err(|e|e.to_string())?,
		};
		let Some(mut message) = item else { return Ok(()) };
		let attachments = message.attachments.len();
		message.attachments.clear();
		let (presence, facts) = match message.metadata.take() {
			Some(rooms_application::room::inbox::metadata::Metadata::Presence(value)) => (Some(value), None),
			Some(rooms_application::room::inbox::metadata::Metadata::Facts(value)) => (None, Some(value)),
			_ => (None, None),
		};
		match presence {
			Some(Presence::Roster { names: roster }) => {
				let mut next = BTreeMap::new();
				for name in roster {
					if fold(&name) != fold(&output.nick) {
						if next.len() >= front::PROJECTED_NAMES {
							return Err("IRC roster is full".into());
						}
						next.insert(name.to_lowercase(), name);
					}
				}
				view.borrow_mut().roster = next;
				names(output, channel, &view).await?;
			}
			Some(Presence::Join { name }) if fold(&name) != fold(&output.nick) => {
				if view.borrow().roster.len() >= front::PROJECTED_NAMES {
					return Err("IRC roster is full".into());
				}
				view.borrow_mut().roster.insert(name.to_lowercase(), name.clone());
				let nick = output.project(&name)?;
				output
					.send("JOIN", &[channel], Some(&front::member_prefix(&nick, &output.server)))
					.await?;
			}
			Some(Presence::Leave { name }) => {
				if view.borrow_mut().roster.remove(&name.to_lowercase()).is_none() {
					continue;
				}
				let nick = output.project(&name)?;
				output
					.send("PART", &[channel], Some(&front::member_prefix(&nick, &output.server)))
					.await?;
			}
			Some(Presence::Offline { names }) => {
				for name in names {
					if view.borrow_mut().roster.remove(&name.to_lowercase()).is_some() {
						let nick = output.project(&name)?;
						output
							.send("PART", &[channel], Some(&front::member_prefix(&nick, &output.server)))
							.await?;
					}
				}
			}
			_ => {}
		}
		if let Some(topic) = facts.and_then(|f| f.topic) {
			view.borrow_mut().topic = Some(topic.clone());
			match protocol::encode_message("TOPIC", &[channel, &topic], Some(&output.server)) {
				Ok(bytes) => output.enqueue(bytes)?.wait().await.map_err(|e| e.reason)?,
				Err(protocol::Error::TooLong) => {
					output
						.notice(&format!(
							"{channel} has a {}-byte topic that cannot fit one IRC line",
							topic.len()
						))
						.await?
				}
				Err(error) => return Err(error.to_string()),
			}
		}
		if message.from != inbox::ROOM && fold(&message.from) != fold(&output.nick) {
			output.chat(&message.from, &message.text, channel).await?;
			if attachments > 0 {
				output
					.notice(&format!(
						"{} sent {attachments} file(s) in {channel}; IRC cannot carry their capabilities",
						message.from
					))
					.await?;
			}
		}
	}
}
