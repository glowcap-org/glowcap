use crate::irc::{WriteReceipt, socket::Writer};
use rooms_application::server::irc::{front, protocol};
use std::{cell::RefCell, rc::Rc};
#[derive(Clone)]
pub(super) struct Output {
	pub writer: Writer,
	pub server: String,
	pub nick: String,
	names: Rc<RefCell<front::Names>>,
}
impl Output {
	pub fn new(writer: Writer, server: String, nick: &str) -> Result<Self, String> {
		Ok(Self {
			writer,
			server,
			nick: nick.into(),
			names: Rc::new(RefCell::new(front::Names::new(nick)?)),
		})
	}
	pub fn project(&self, name: &str) -> Result<String, String> {
		self.names.borrow_mut().project(name).map_err(String::from)
	}
	pub fn original(&self, name: &str) -> String {
		self.names.borrow().original(name).into()
	}
	pub fn enqueue(&self, bytes: Vec<u8>) -> Result<WriteReceipt, String> {
		self.writer.enqueue(bytes, false).map_err(|e| e.reason)
	}
	pub async fn send(&self, command: &str, params: &[&str], prefix: Option<&str>) -> Result<(), String> {
		let bytes = protocol::encode_message(command, params, prefix).map_err(|e| e.to_string())?;
		self.enqueue(bytes)?.wait().await.map_err(|e| e.reason)
	}
	pub async fn numeric(&self, command: &str, params: &[&str]) -> Result<(), String> {
		let (last, leading) = params.split_last().ok_or("numeric requires a recipient")?;
		let bytes = front::explanation(command, leading, &self.server, last).map_err(|e| e.to_string())?;
		self.enqueue(bytes)?.wait().await.map_err(|e| e.reason)
	}
	pub fn notice_bytes(&self, text: &str) -> Result<Vec<u8>, String> {
		front::explanation("NOTICE", &[&self.nick], &self.server, text).map_err(|e| e.to_string())
	}
	pub async fn notice(&self, text: &str) -> Result<(), String> {
		self.enqueue(self.notice_bytes(text)?)?
			.wait()
			.await
			.map_err(|e| e.reason)
	}
	pub fn chat_bytes(&self, from: &str, text: &str, target: &str) -> Result<Vec<u8>, String> {
		let projected = self.project(from)?;
		match protocol::encode_message(
			"PRIVMSG",
			&[target, text],
			Some(&front::member_prefix(&projected, &self.server)),
		) {
			Ok(bytes) => Ok(bytes),
			Err(protocol::Error::TooLong) => self.notice_bytes(&format!(
				"A {}-byte message from {from} could not fit one IRC line",
				text.len()
			)),
			Err(error) => Err(error.to_string()),
		}
	}
	pub async fn chat(&self, from: &str, text: &str, target: &str) -> Result<(), String> {
		self.enqueue(self.chat_bytes(from, text, target)?)?
			.wait()
			.await
			.map_err(|e| e.reason)
	}
}
