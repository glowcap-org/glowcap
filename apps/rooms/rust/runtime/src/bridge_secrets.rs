//! Credential custody for session-owned bridge intent.
//!
//! Checkpoints and operation material carry only public answers. Secret fields
//! live in this independently bounded document. A candidate and its previous
//! value remain together until the checkpoint outcome is known or recovered.
use crate::documents::{Completion, Document};
use rooms_application::{
	bridge::Answers,
	documents::{SessionDocument, WriteFailure},
	session::checkpoint::Checkpoint,
	text::DocumentText,
};
use std::{future::Future, pin::Pin, rc::Rc};

const VERSION: u8 = 1;
const MAX_SCOPES: usize = 64;
const MAX_DIRECTORY_UNITS: usize = 16 * 1024;
const MAX_SCOPE_UNITS: usize = 64;

type StoreFuture<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;
trait Store {
	fn read(&mut self) -> StoreFuture<'_, Result<Option<Vec<u8>>, String>>;
	fn replace(&mut self, bytes: Vec<u8>) -> StoreFuture<'_, Result<(), String>>;
	fn finish_pending(&mut self) -> StoreFuture<'_, Option<Result<(), String>>>;
}
impl<D: Document> Store for D {
	fn read(&mut self) -> StoreFuture<'_, Result<Option<Vec<u8>>, String>> {
		Box::pin(async move { Document::read(self).await.map_err(|error| error.to_string()) })
	}
	fn replace(&mut self, bytes: Vec<u8>) -> StoreFuture<'_, Result<(), String>> {
		Box::pin(async move {
			Document::replace(self, bytes).await.map_err(|error| match error {
				WriteFailure::Unchanged(error) => error.to_string(),
				WriteFailure::Indeterminate(error) => format!("bridge secret write outcome is indeterminate: {error}"),
			})
		})
	}
	fn finish_pending(&mut self) -> StoreFuture<'_, Option<Result<(), String>>> {
		Box::pin(async move {
			Document::finish_pending(self).await.map(|completion| match completion {
				Completion::Read(result) => result.map(|_| ()).map_err(|error| error.to_string()),
				Completion::Write(result) => result.map_err(|error| match error {
					WriteFailure::Unchanged(error) => error.to_string(),
					WriteFailure::Indeterminate(error) => {
						format!("bridge secret write outcome is indeterminate: {error}")
					}
				}),
			})
		})
	}
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Row {
	directory: DocumentText,
	scope: DocumentText,
	answers: Answers,
	revision: Option<DocumentText>,
}
#[derive(Clone, PartialEq, Eq)]
struct Key {
	directory: DocumentText,
	scope: DocumentText,
}
impl Key {
	fn new(directory: &DocumentText, scope: &DocumentText) -> Self {
		Self {
			directory: directory.clone(),
			scope: scope.lowercase(),
		}
	}
	fn of(row: &Row) -> Self {
		Self::new(&row.directory, &row.scope)
	}
}
struct Staged {
	key: Key,
	token: u64,
	previous: Option<Row>,
}
struct Owner {
	document: Box<dyn Store>,
	rows: Vec<Row>,
	staged: Vec<Staged>,
	unwitnessed: Vec<Key>,
	next_token: u64,
}

#[derive(Clone)]
pub struct BridgeSecrets(Rc<tokio::sync::Mutex<Owner>>);
impl BridgeSecrets {
	/// Absence is an empty ledger. Corrupt custody refuses session startup rather
	/// than silently asking the user for credentials again.
	pub async fn open<D: Document + 'static>(document: D) -> Result<Self, String> {
		if document.document() != SessionDocument::BridgeSecrets {
			return Err("bridge secret custody received the wrong document role".into());
		}
		let mut document: Box<dyn Store> = Box::new(document);
		if let Some(result) = document.finish_pending().await {
			result?;
		}
		let (rows, staged) = match document.read().await? {
			None => (Vec::new(), Vec::new()),
			Some(bytes) => decode(&bytes)?,
		};
		let next_token = u64::try_from(staged.len()).map_err(|_| "bridge secret staging token overflow")?;
		Ok(Self(Rc::new(tokio::sync::Mutex::new(Owner {
			document,
			rows,
			staged,
			unwitnessed: Vec::new(),
			next_token,
		}))))
	}

	/// Durably replace one scope before committing the checkpoint that says a
	/// secret was supplied. Empty answers explicitly remove prior custody.
	pub async fn stage(
		&self,
		directory: DocumentText,
		scope: DocumentText,
		answers: Answers,
		revision: Option<DocumentText>,
	) -> Result<u64, String> {
		validate_key(&directory, &scope)?;
		if answers.is_empty() != revision.is_none() {
			return Err("bridge secret revision does not match its answers".into());
		}
		let mut owner = self.0.lock().await;
		let key = Key::new(&directory, &scope);
		if owner.staged.iter().any(|entry| entry.key == key) {
			return Err("bridge secret custody still has an unresolved checkpoint outcome".into());
		}
		let previous = remove(&mut owner.rows, &key);
		let next = (!answers.is_empty()).then_some(Row {
			directory,
			scope,
			answers,
			revision,
		});
		if let Some(row) = next {
			owner.rows.push(row);
		}
		owner.next_token = owner
			.next_token
			.checked_add(1)
			.ok_or("bridge secret staging token exhausted")?;
		let token = owner.next_token;
		owner.staged.push(Staged {
			key: key.clone(),
			token,
			previous: previous.clone(),
		});
		owner.unwitnessed.retain(|held| held != &key);
		if let Err(error) = write(&mut owner).await {
			remove(&mut owner.rows, &key);
			if let Some(row) = previous {
				owner.rows.push(row);
			}
			owner.staged.retain(|entry| entry.key != key || entry.token != token);
			return Err(error);
		}
		Ok(token)
	}

	pub async fn settle(&self, directory: &DocumentText, scope: &DocumentText, token: u64) -> Result<(), String> {
		let mut owner = self.0.lock().await;
		let key = Key::new(directory, scope);
		if let Some(index) = owner
			.staged
			.iter()
			.position(|entry| entry.key == key && entry.token == token)
		{
			let staged = owner.staged.remove(index);
			if let Err(error) = write(&mut owner).await {
				owner.staged.push(staged);
				return Err(error);
			}
			if owner.rows.iter().any(|row| Key::of(row) == key) && !owner.unwitnessed.contains(&key) {
				owner.unwitnessed.push(key);
			}
		}
		Ok(())
	}

	pub async fn discard(&self, directory: &DocumentText, scope: &DocumentText, token: u64) -> Result<(), String> {
		let mut owner = self.0.lock().await;
		let key = Key::new(directory, scope);
		let Some(index) = owner
			.staged
			.iter()
			.position(|entry| entry.key == key && entry.token == token)
		else {
			return Ok(());
		};
		let staged = owner.staged.remove(index);
		let current = remove(&mut owner.rows, &key);
		if let Some(previous) = staged.previous.clone() {
			owner.rows.push(previous);
		}
		if let Err(error) = write(&mut owner).await {
			remove(&mut owner.rows, &key);
			if let Some(row) = current {
				owner.rows.push(row);
			}
			owner.staged.push(staged);
			return Err(error);
		}
		if staged.previous.is_some() && !owner.unwitnessed.contains(&key) {
			owner.unwitnessed.push(key);
		}
		Ok(())
	}

	pub async fn answers(
		&self,
		directory: &DocumentText,
		scope: &DocumentText,
	) -> Option<(Answers, Option<DocumentText>)> {
		let owner = self.0.lock().await;
		let key = Key::new(directory, scope);
		owner
			.rows
			.iter()
			.find(|row| Key::of(row) == key)
			.map(|row| (row.answers.clone(), row.revision.clone()))
	}

	/// Resolve a staged row after startup against the checkpoint that storage
	/// actually recovered. The previous and candidate answers remain together in
	/// this document until that decision is durable.
	pub async fn recover(
		&self,
		witnesses: &[(DocumentText, DocumentText, Option<DocumentText>)],
	) -> Result<(), String> {
		let mut owner = self.0.lock().await;
		if let Some(result) = owner.document.finish_pending().await {
			result?;
		}
		if owner.staged.is_empty() {
			return Ok(());
		}
		let staged = core::mem::take(&mut owner.staged);
		let current = owner.rows.clone();
		for pending in &staged {
			let candidate = owner
				.rows
				.iter()
				.find(|row| Key::of(row) == pending.key)
				.and_then(|row| row.revision.as_ref());
			let recovered = match candidate {
				Some(candidate) => witnesses.iter().any(|(directory, scope, revision)| {
					Key::new(directory, scope) == pending.key && revision.as_ref() == Some(candidate)
				}),
				None => !witnesses
					.iter()
					.any(|(directory, scope, _)| Key::new(directory, scope) == pending.key),
			};
			if !recovered {
				remove(&mut owner.rows, &pending.key);
				if let Some(previous) = pending.previous.clone() {
					owner.rows.push(previous);
				}
			}
		}
		if let Err(error) = write(&mut owner).await {
			owner.rows = current;
			owner.staged = staged;
			return Err(error);
		}
		Ok(())
	}

	/// Remove custody once a committed checkpoint no longer names a secret-using
	/// room in that directory and scope. In-flight and newly settled rows stay
	/// until a later checkpoint witnesses them.
	pub async fn retain(&self, checkpoint: &Checkpoint) -> Result<(), String> {
		let wanted: Vec<Key> = checkpoint
			.rooms()
			.filter_map(|room| {
				let bridge = room.bridge.filter(|bridge| bridge.secrets_given)?;
				Some(Key::new(room.directory.text(), bridge.scope))
			})
			.collect();
		let mut owner = self.0.lock().await;
		let staged: Vec<Key> = owner.staged.iter().map(|entry| entry.key.clone()).collect();
		let unwitnessed = owner.unwitnessed.clone();
		let mut dropped = Vec::new();
		owner.rows.retain(|row| {
			let key = Key::of(row);
			let keep = wanted.contains(&key) || staged.contains(&key) || unwitnessed.contains(&key);
			if !keep {
				dropped.push(row.clone());
			}
			keep
		});
		owner.unwitnessed.retain(|key| !wanted.contains(key));
		if dropped.is_empty() {
			return Ok(());
		}
		if let Err(error) = write(&mut owner).await {
			owner.rows.extend(dropped);
			return Err(error);
		}
		Ok(())
	}
}

pub(crate) fn checkpoint_witnesses(checkpoint: &Checkpoint) -> Vec<(DocumentText, DocumentText, Option<DocumentText>)> {
	checkpoint
		.rooms()
		.filter_map(|room| {
			let bridge = room.bridge.filter(|bridge| bridge.secrets_given)?;
			Some((
				room.directory.text().clone(),
				bridge.scope.clone(),
				bridge.credential_revision.cloned(),
			))
		})
		.collect()
}

fn remove(rows: &mut Vec<Row>, key: &Key) -> Option<Row> {
	rows.iter()
		.position(|row| Key::of(row) == *key)
		.map(|index| rows.remove(index))
}
fn validate_key(directory: &DocumentText, scope: &DocumentText) -> Result<(), String> {
	if directory.utf16().take(MAX_DIRECTORY_UNITS + 1).count() > MAX_DIRECTORY_UNITS
		|| scope.utf16().next().is_none()
		|| scope.utf16().take(MAX_SCOPE_UNITS + 1).count() > MAX_SCOPE_UNITS
	{
		return Err("bridge secret directory or scope exceeds its bound".into());
	}
	Ok(())
}
fn decode(bytes: &[u8]) -> Result<(Vec<Row>, Vec<Staged>), String> {
	let text = SessionDocument::BridgeSecrets
		.decode(bytes)
		.map_err(|error| format!("Rooms session bridge secrets are invalid: {error}"))?;
	let mut disk: serde_json::Value =
		serde_json::from_str(text).map_err(|error| format!("Rooms session bridge secrets are invalid: {error}"))?;
	let object = disk
		.as_object_mut()
		.ok_or("Rooms session bridge secrets are not an object")?;
	let version = object.remove("version").and_then(|value| value.as_u64());
	if version != Some(u64::from(VERSION)) || object.keys().any(|key| key != "secrets" && key != "pending") {
		return Err("Rooms session bridge secrets have an unsupported version or shape".into());
	}
	let values = object
		.remove("secrets")
		.and_then(|value| value.as_array().cloned())
		.ok_or("Rooms session bridge secrets have no row list")?;
	if values.len() > MAX_SCOPES {
		return Err("Rooms session bridge secrets exceed their row limit".into());
	}
	let mut rows = Vec::with_capacity(values.len());
	for value in values {
		let row = decode_row(value)?;
		if rows.iter().any(|held| Key::of(held) == Key::of(&row)) {
			return Err("Rooms session bridge secrets contain a duplicate scope".into());
		}
		rows.push(row);
	}
	let values = object
		.remove("pending")
		.map(|value| value.as_array().cloned().ok_or("bridge secret pending list is invalid"))
		.transpose()?
		.unwrap_or_default();
	if values.len() > MAX_SCOPES {
		return Err("Rooms session bridge secrets exceed their pending limit".into());
	}
	let mut staged = Vec::with_capacity(values.len());
	for (index, mut value) in values.into_iter().enumerate() {
		let object = value
			.as_object_mut()
			.ok_or("bridge secret pending row is not an object")?;
		if object.len() != 3 {
			return Err("bridge secret pending row has an invalid shape".into());
		}
		let directory: DocumentText = serde_json::from_value(
			object
				.remove("directory")
				.ok_or("bridge secret pending row has no directory")?,
		)
		.map_err(|error| error.to_string())?;
		let scope: DocumentText =
			serde_json::from_value(object.remove("scope").ok_or("bridge secret pending row has no scope")?)
				.map_err(|error| error.to_string())?;
		let previous = object
			.remove("previous")
			.filter(|value| !value.is_null())
			.map(decode_row)
			.transpose()?;
		let key = Key::new(&directory, &scope);
		if previous.as_ref().is_some_and(|row| Key::of(row) != key) {
			return Err("bridge secret pending row names a different previous scope".into());
		}
		if staged.iter().any(|held: &Staged| held.key == key) {
			return Err("Rooms session bridge secrets contain duplicate pending scopes".into());
		}
		staged.push(Staged {
			key,
			token: u64::try_from(index + 1).map_err(|_| "bridge secret pending token overflow")?,
			previous,
		});
	}
	Ok((rows, staged))
}
fn decode_row(mut value: serde_json::Value) -> Result<Row, String> {
	let object = value
		.as_object_mut()
		.ok_or("Rooms session bridge secret row is not an object")?;
	if !(3..=4).contains(&object.len())
		|| object
			.keys()
			.any(|key| !matches!(key.as_str(), "directory" | "scope" | "answers" | "revision"))
	{
		return Err("Rooms session bridge secret row has an invalid shape".into());
	}
	let answers = object.remove("answers").ok_or("bridge secret row has no answers")?;
	let row = Row {
		directory: serde_json::from_value(object.remove("directory").ok_or("bridge secret row has no directory")?)
			.map_err(|error| error.to_string())?,
		scope: serde_json::from_value(object.remove("scope").ok_or("bridge secret row has no scope")?)
			.map_err(|error| error.to_string())?,
		answers: Answers::decode(&serde_json::to_string(&answers).map_err(|error| error.to_string())?)
			.map_err(|error| error.to_string())?,
		revision: object
			.remove("revision")
			.filter(|value| !value.is_null())
			.map(serde_json::from_value)
			.transpose()
			.map_err(|error| error.to_string())?,
	};
	validate_key(&row.directory, &row.scope)?;
	if row.answers.is_empty() {
		return Err("Rooms session bridge secret row has no secret answers".into());
	}
	if row
		.revision
		.as_ref()
		.is_some_and(|revision| revision.utf16().next().is_none() || revision.utf16().take(129).count() > 128)
	{
		return Err("Rooms session bridge secret revision exceeds its bound".into());
	}
	Ok(row)
}
fn row_value(row: &Row) -> Result<serde_json::Value, String> {
	Ok(serde_json::json!({
		"directory": serde_json::to_value(&row.directory).map_err(|error| error.to_string())?,
		"scope": serde_json::to_value(&row.scope).map_err(|error| error.to_string())?,
		"answers": serde_json::to_value(&row.answers).map_err(|error| error.to_string())?,
		"revision": serde_json::to_value(&row.revision).map_err(|error| error.to_string())?,
	}))
}
async fn write(owner: &mut Owner) -> Result<(), String> {
	if owner.rows.len() > MAX_SCOPES || owner.staged.len() > MAX_SCOPES {
		return Err("Rooms session bridge secrets exceed their row limit".into());
	}
	let rows = owner.rows.iter().map(row_value).collect::<Result<Vec<_>, _>>()?;
	let pending = owner
		.staged
		.iter()
		.map(|staged| {
			Ok(serde_json::json!({
				"directory": &staged.key.directory,
				"scope": &staged.key.scope,
				"previous": staged.previous.as_ref().map(row_value).transpose()?,
			}))
		})
		.collect::<Result<Vec<_>, String>>()?;
	let mut bytes = serde_json::to_vec(&serde_json::json!({ "version": VERSION, "secrets": rows, "pending": pending }))
		.map_err(|error| error.to_string())?;
	bytes.push(b'\n');
	if bytes.len() > SessionDocument::BridgeSecrets.max_bytes() {
		return Err("Rooms session bridge secrets exceed their byte ceiling".into());
	}
	owner.document.replace(bytes).await
}

#[cfg(test)]
mod tests;
