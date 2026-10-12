use super::{channels::Channel, direct::Directs, output::Output, peer::Context};
use crate::irc::socket::Writer;
use futures_util::{StreamExt, stream::FuturesUnordered};
use glowcap::{ConnectOptions, PendingWork, Runtime, RuntimeConfig, Session, iroh, tcp};
use rooms_application::server::irc::{
	front,
	protocol::{self, LineReader, Message, fold},
	registration::validate_nick,
};
use rooms_glowcap::client::{Client, directory::Directory};
use rooms_platform::HostPlatform;
use std::{
	collections::{BTreeMap, VecDeque},
	rc::Rc,
	time::Duration,
};
use tokio::{
	io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
	sync::watch,
};
pub(super) trait Stream: AsyncRead + AsyncWrite + Unpin {}
impl<T: AsyncRead + AsyncWrite + Unpin> Stream for T {}
struct Input<R> {
	reader: R,
	framing: LineReader,
	pending: VecDeque<Message>,
}
impl<R: AsyncRead + Unpin> Input<R> {
	async fn next(&mut self) -> Result<Option<Message>, String> {
		loop {
			if let Some(message) = self.pending.pop_front() {
				return Ok(Some(message));
			}
			let mut bytes = [0u8; 4096];
			let size = self.reader.read(&mut bytes).await.map_err(|e| e.to_string())?;
			if size == 0 {
				self.framing.end().map_err(|e| e.to_string())?;
				return Ok(None);
			}
			self.pending
				.extend(self.framing.feed(&bytes[..size]).map_err(|e| e.to_string())?);
		}
	}
}
pub(super) async fn run(
	stream: Box<dyn Stream>,
	context: Rc<Context>,
	mut stop: watch::Receiver<bool>,
) -> Result<(), String> {
	let (read, write) = tokio::io::split(stream);
	let (writer, pump) = Writer::open(Duration::ZERO);
	let mut client = ClientState {
		nickname: None,
		context,
		writer: writer.clone(),
		output: None,
		directory: None,
		session: None,
		runtime: None,
		attachment: None,
		directs: None,
		channels: BTreeMap::new(),
	};
	let mut input = Input {
		reader: read,
		framing: LineReader::default(),
		pending: VecDeque::new(),
	};
	let mut pumping = tokio::task::JoinSet::new();
	let (finished, finish) = tokio::sync::oneshot::channel();
	let (close, closing) = tokio::sync::oneshot::channel();
	pumping.spawn_local(async move {
		let mut write = write;
		let _ = finished.send(pump.run(&mut write).await);
		// EOF/close_notify promises that this IRC user's application authority
		// is retired, so an immediate reconnect can claim the same name.
		let _ = closing.await;
		tokio::time::timeout(Duration::from_secs(3), write.shutdown())
			.await
			.map_err(|_| "IRC socket shutdown timed out".to_owned())
			.and_then(|r| r.map_err(|e| e.to_string()))
	});
	let mut finish = finish;
	let (mut result, mut registered, pump_result) = tokio::select! {
		_ = stop.changed() => (Ok(()), None, None),
		ended = &mut finish => (Ok(()), None, Some(ended.map_err(|_| "IRC output owner disappeared".to_owned()).and_then(|r| r))),
		(result, registered) = client.drive(&mut input) => (result, registered, None),
	};
	writer.fail("the IRC connection ended");
	result = crate::cleanup::combine(
		result,
		match registered.take() {
			Some(registered) => registered.close().await,
			None => client.close().await,
		},
	);
	let pump_result = match pump_result {
		Some(result) => result,
		None => finish
			.await
			.map_err(|_| "IRC output owner disappeared".to_owned())
			.and_then(|result| result),
	};
	result = crate::cleanup::combine(result, pump_result);
	let _ = close.send(());
	match pumping.join_next().await {
		Some(Ok(shutdown)) => result = crate::cleanup::combine(result, shutdown),
		Some(Err(error)) => result = crate::cleanup::combine(result, Err(error.to_string())),
		None => result = crate::cleanup::combine(result, Err("IRC output owner disappeared".into())),
	}
	result
}
struct ClientState {
	nickname: Option<super::names::Lease>,
	context: Rc<Context>,
	writer: Writer,
	output: Option<Output>,
	directory: Option<Directory<HostPlatform>>,
	session: Option<Session>,
	runtime: Option<Runtime>,
	attachment: Option<Rc<super::inboxes::Attachment>>,
	directs: Option<Directs>,
	channels: BTreeMap<String, Channel>,
}
impl ClientState {
	async fn drive(&mut self, input: &mut Input<impl AsyncRead + Unpin>) -> (Result<(), String>, Option<Registered>) {
		let registered = tokio::time::timeout(Duration::from_secs(30), self.register(input))
			.await
			.map_err(|_| "IRC registration timed out".to_owned())
			.and_then(|result| result);
		match registered {
			Err(error) => (Err(error), None),
			Ok(false) => (Ok(()), None),
			Ok(true) => {
				let mut registered = match self.take_registered() {
					Ok(registered) => registered,
					Err(error) => return (Err(error), None),
				};
				let result = async {
					while let Some(message) = input.next().await? {
						if registered.command(message).await? {
							break;
						}
					}
					Ok(())
				}
				.await;
				(result, Some(registered))
			}
		}
	}
	/// Hand the registered client its state. `register` fills every field
	/// before it answers `Ok(true)`, so a missing one means registration did
	/// not complete and the connection is refused rather than driven.
	fn take_registered(&mut self) -> Result<Registered, String> {
		let (
			Some(nickname),
			Some(output),
			Some(directory),
			Some(session),
			Some(runtime),
			Some(attachment),
			Some(directs),
		) = (
			self.nickname.take(),
			self.output.take(),
			self.directory.take(),
			self.session.take(),
			self.runtime.take(),
			self.attachment.take(),
			self.directs.take(),
		)
		else {
			return Err("IRC registration did not complete".into());
		};
		Ok(Registered {
			_nickname: nickname,
			report: self.context.report.clone(),
			output,
			directory,
			session,
			runtime,
			attachment,
			directs,
			channels: std::mem::take(&mut self.channels),
		})
	}
	async fn register(&mut self, input: &mut Input<impl AsyncRead + Unpin>) -> Result<bool, String> {
		let (mut nick, mut user, mut cap) = (None, false, false);
		while let Some(message) = input.next().await? {
			let recipient = nick.as_deref().unwrap_or("*");
			match message.command.as_str() {
				"QUIT" => return Ok(false),
				"PING" => {
					self.raw("PONG", &message.params.iter().map(String::as_str).collect::<Vec<_>>())
						.await?
				}
				"CAP" => match message.param(0).map(str::to_ascii_uppercase).as_deref() {
					Some("LS") => {
						cap = true;
						self.raw("CAP", &[recipient, "LS", ""]).await?;
					}
					Some("END") => cap = false,
					Some("REQ") => {
						self.raw("CAP", &[recipient, "NAK", message.last().unwrap_or("")])
							.await?
					}
					_ => {}
				},
				"NICK" => {
					let asked = message.param(0).unwrap_or("");
					let valid = validate_nick(asked)
						.map_err(String::from)
						.and_then(|_| rooms_application::room::inbox::nick_refusal(asked).map_or(Ok(()), Err));
					match valid {
						Ok(()) => nick = Some(asked.to_owned()),
						Err(error) => {
							self.raw("432", &["*", if asked.is_empty() { "*" } else { asked }, &error])
								.await?
						}
					}
				}
				"USER" if message.params.len() >= 4 => user = true,
				"USER" => self.raw("461", &[recipient, "USER", "Not enough parameters"]).await?,
				_ => self.raw("451", &[recipient, "You have not registered"]).await?,
			}
			if let Some(nick) = &nick
				&& user && !cap
			{
				match self.context.names.claim(nick) {
					Ok(lease) => self.nickname = Some(lease),
					Err(error) => {
						self.raw("433", &["*", nick, &error]).await?;
						return Ok(false);
					}
				}
				let mut providers = vec![tcp::provider(Default::default())];
				if let Some(reachability) = self.context.iroh {
					providers.push(iroh::provider(rooms_platform::serving::iroh_config(reachability)));
				}
				let runtime = Runtime::open(RuntimeConfig::providers(providers))
					.await
					.map_err(|e| e.to_string())?;
				let attachment = self.context.inboxes.attach(&runtime).await?;
				let session = runtime
					.connect(&self.context.directory, ConnectOptions::default())
					.await
					.map_err(|e| format!("Rooms directory connection failed: {e:?}"))?;
				self.runtime = Some(runtime);
				self.attachment = Some(attachment.clone());
				self.session = Some(session.borrowed());
				let directory = Directory::fetch(Client::new(session, HostPlatform))
					.await
					.map_err(|e| format!("Rooms directory fetch failed: {e}"))?;
				self.directory = Some(directory.clone());
				let mut registration = directory.registration();
				if let Err(error) = registration.register(nick, &attachment.identity, None).await {
					self.raw(
						super::failure::registration(&error.to_string()),
						&["*", nick, &error.to_string()],
					)
					.await?;
					return Err(error.to_string());
				}
				let output = Output::new(self.writer.clone(), self.context.server.clone(), nick)?;
				self.directs = Some(Directs::open(
					&self.context.publisher,
					attachment,
					directory,
					registration,
					output.clone(),
					self.context.report.clone(),
				)?);
				output
					.numeric("001", &[nick, &format!("Welcome to Rooms, {nick}")])
					.await?;
				output
					.numeric("002", &[nick, &format!("Your server is {}", output.server)])
					.await?;
				output
					.numeric(
						"005",
						&[
							nick,
							"CASEMAPPING=rfc1459",
							"CHANTYPES=#",
							"NICKLEN=28",
							"TOPICLEN=300",
							"are supported",
						],
					)
					.await?;
				output.numeric("376", &[nick, "End of MOTD"]).await?;
				self.output = Some(output);
				return Ok(true);
			}
		}
		Ok(false)
	}
	async fn raw(&self, command: &str, params: &[&str]) -> Result<(), String> {
		let bytes = protocol::encode_message(command, params, Some(&self.context.server)).map_err(|e| e.to_string())?;
		self.writer
			.enqueue(bytes, false)
			.map_err(|e| e.reason)?
			.wait()
			.await
			.map_err(|e| e.reason)
	}
	async fn close(&mut self) -> Result<(), String> {
		let mut result = Ok(());
		if let Some(directs) = self.directs.take() {
			result = crate::cleanup::combine(result, directs.close().await);
		}
		if let Some(session) = self.session.take() {
			result = crate::cleanup::combine(
				result,
				session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			);
		}
		self.directory = None;
		if let Some(attachment) = self.attachment.take() {
			result = crate::cleanup::combine(result, attachment.close().await);
		}
		if let Some(runtime) = self.runtime.take() {
			result = crate::cleanup::combine(
				result,
				runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
			);
		}
		self.nickname = None;
		result
	}
}

struct Registered {
	_nickname: super::names::Lease,
	report: super::notice::Report,
	output: Output,
	directory: Directory<HostPlatform>,
	session: Session,
	runtime: Runtime,
	attachment: Rc<super::inboxes::Attachment>,
	directs: Directs,
	channels: BTreeMap<String, Channel>,
}
impl Registered {
	async fn command(&mut self, message: Message) -> Result<bool, String> {
		let output = self.output.clone();
		let nick = output.nick.as_str();
		let directory = &self.directory;
		match message.command.as_str() {
			"QUIT" => return Ok(true),
			"PING" => {
				output
					.send(
						"PONG",
						&message.params.iter().map(String::as_str).collect::<Vec<_>>(),
						Some(&output.server),
					)
					.await?
			}
			"NICK" => {
				output
					.numeric(
						"438",
						&[
							nick,
							message.param(0).unwrap_or("*"),
							"Nick changes require a new IRC connection",
						],
					)
					.await?
			}
			"JOIN" => {
				if message.param(0).is_none_or(str::is_empty) {
					output.numeric("461", &[nick, "JOIN", "Not enough parameters"]).await?;
				}
				for channel in message.param(0).unwrap_or("").split(',').filter(|s| !s.is_empty()) {
					let key = fold(channel);
					if self.channels.contains_key(&key) {
						continue;
					}
					if self.channels.len() >= front::ROOMS {
						output
							.numeric("405", &[nick, channel, "You may join at most 32 rooms"])
							.await?;
						continue;
					}
					match Channel::join(directory, output.clone(), channel).await {
						Ok(held) => {
							self.channels.insert(key, held);
						}
						Err(error) => {
							output
								.numeric(super::failure::join(&error), &[nick, channel, &error])
								.await?
						}
					}
				}
			}
			"PART" => {
				if message.param(0).is_none_or(str::is_empty) {
					output.numeric("461", &[nick, "PART", "Not enough parameters"]).await?;
				}
				for channel in message.param(0).unwrap_or("").split(',').filter(|s| !s.is_empty()) {
					if let Some(held) = self.channels.remove(&fold(channel)) {
						held.close().await?;
						output
							.send("PART", &[channel], Some(&front::member_prefix(nick, &output.server)))
							.await?;
					} else {
						output
							.numeric("442", &[nick, channel, "You're not on that channel"])
							.await?;
					}
				}
			}
			"PRIVMSG" => match (message.param(0), message.param(1)) {
				(None, _) => output.numeric("411", &[nick, "No recipient given"]).await?,
				(_, None | Some("")) => output.numeric("412", &[nick, "No text to send"]).await?,
				(Some(target), Some(text)) if target.starts_with('#') => {
					if let Some(held) = self.channels.get(&fold(target)) {
						if let Err(error) = held.room.say(text).await {
							output.numeric("404", &[nick, target, &error.to_string()]).await?;
						}
					} else {
						output
							.numeric("442", &[nick, target, "You're not on that channel"])
							.await?;
					}
				}
				(Some(target), Some(text)) => {
					let peer = output.original(target);
					if fold(&peer) == fold(nick) {
						output.numeric("401", &[nick, target, "No such nick"]).await?;
					} else if let Err(error) = self.directs.say(directory, &peer, text).await {
						(self.report)(super::notice::Notice::DirectMessageRefused(error.clone()));
						output
							.numeric(super::failure::direct(&error), &[nick, target, &error])
							.await?;
					}
				}
			},
			"NAMES" => {
				for held in self.channels.values() {
					if message
						.param(0)
						.is_none_or(|raw| raw.split(',').any(|c| fold(c) == fold(&held.channel)))
					{
						held.names(&output).await?;
					}
				}
			}
			"LIST" => {
				output.numeric("321", &[nick, "Channel", "Users Name"]).await?;
				let mut omitted = 0;
				match directory.list().await {
					Ok(rooms) => {
						for row in rooms {
							if let (Some(channel), Some(count)) =
								(row.name.text().as_str().and_then(front::channel), row.count.as_ref())
							{
								output
									.numeric("322", &[nick, &channel, &count.get().to_string(), ""])
									.await?;
							} else {
								omitted += 1;
							}
						}
					}
					Err(error) => output.numeric("400", &[nick, &error.to_string()]).await?,
				}
				output.numeric("323", &[nick, "End of LIST"]).await?;
				if omitted > 0 {
					output
						.notice(&format!(
							"{omitted} room publication(s) were not addressable as counted IRC channels"
						))
						.await?;
				}
			}
			"TOPIC" => match message.param(0) {
				None => output.numeric("461", &[nick, "TOPIC", "Not enough parameters"]).await?,
				Some(channel) => {
					if let Some(held) = self.channels.get(&fold(channel)) {
						if let Some(text) = message.param(1) {
							if let Err(error) = held.room.set_topic(text).await {
								output.numeric("482", &[nick, channel, &error.to_string()]).await?;
							}
						} else {
							let topic = held.topic();
							output
								.numeric(
									if topic.is_some() { "332" } else { "331" },
									&[nick, channel, topic.as_deref().unwrap_or("No topic is set")],
								)
								.await?;
						}
					} else {
						output
							.numeric("442", &[nick, channel, "You're not on that channel"])
							.await?;
					}
				}
			},
			"WHOIS" => {
				// `split` yields at least one piece, the whole text when there is no comma.
				let asked = message.last().unwrap_or("*").split(',').next().unwrap_or("*");
				let peer = output.original(asked);
				if fold(&peer) == fold(nick) || self.channels.values().any(|c| c.knows(&peer)) {
					output
						.numeric("311", &[nick, asked, "rooms", &output.server, "*", &peer])
						.await?;
				} else {
					output.numeric("401", &[nick, asked, "No such nick"]).await?;
				}
				output.numeric("318", &[nick, asked, "End of WHOIS"]).await?;
			}
			"CAP" => {
				output
					.send(
						"CAP",
						&[nick, "NAK", message.last().unwrap_or("")],
						Some(&output.server),
					)
					.await?
			}
			_ => {
				output
					.numeric("421", &[nick, &message.command, "Unknown command"])
					.await?
			}
		}
		Ok(false)
	}
	async fn close(self) -> Result<(), String> {
		let Registered {
			_nickname: _,
			report: _,
			output: _,
			directory: _,
			session,
			runtime,
			attachment,
			directs,
			channels,
		} = self;
		let mut result = Ok(());
		result = crate::cleanup::combine(result, directs.close().await);
		// Memberships are independently owned and already bounded at admission.
		// One slow leave must not multiply its deadline by the number of rooms.
		let mut leaving: FuturesUnordered<_> = channels.into_values().map(Channel::close).collect();
		while let Some(ended) = leaving.next().await {
			result = crate::cleanup::combine(result, ended);
		}
		result = crate::cleanup::combine(
			result,
			session.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
		);
		result = crate::cleanup::combine(result, attachment.close().await);
		result = crate::cleanup::combine(
			result,
			runtime.close(PendingWork::Cancel).await.map_err(|e| e.to_string()),
		);
		result
	}
}
