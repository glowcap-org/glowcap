//! A local operator may let one registered directory's room offers join this
//! session. The stored selection names its held directory access. An incoming
//! activity token must still pass the managed owner's callback and grant checks.
use super::{Failure, peer_failure};
use crate::session::Local;
use rooms_application::content::session::{custody, workspace};
use rooms_platform::storage::{self, atomic};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use tokio::sync::Mutex;

const FILE: &str = "invitation-policy.json";

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
	recipe: [u8; 32],
	directory: workspace::Id,
	access: custody::FieldKey<custody::DirectoryAccess>,
}

pub(super) struct Invitations {
	path: PathBuf,
	after: std::cell::Cell<u64>,
	selection: Mutex<Option<Selection>>,
}

impl Selection {
	async fn directory(
		app: &Local,
		directory: &workspace::Directory,
		selected: Option<&Self>,
	) -> Result<Option<(Self, glowcap::Ref)>, Failure> {
		use sha2::{Digest, Sha256};
		let coord = custody::Coordinate::new(custody::Role::DirectoryAccess, directory.access);
		let held = app
			.custody
			.restore_publication(&[coord])
			.await
			.map_err(Failure::uncertain)?;
		let [(actual, Some(uri))] = held.as_slice() else {
			return Err(Failure::invalid("automatic invitations require a saved directory link"));
		};
		let selection = Self {
			directory: directory.id.clone(),
			access: directory.access,
			recipe: Sha256::digest(uri.as_bytes()).into(),
		};
		if selected.is_some_and(|held| *held != selection) {
			return Ok(None);
		}
		let expected = tokio::time::timeout(std::time::Duration::from_secs(10), app.host.enliven(uri))
			.await
			.map_err(|_| Failure::uncertain("the saved directory link did not answer"))?
			.map_err(Failure::uncertain)?;
		if expected != *actual {
			return Err(Failure::invalid(
				"the saved directory link no longer reaches the held directory capability",
			));
		}
		Ok(Some((selection, expected)))
	}
}

impl Invitations {
	pub fn open(path: &Path) -> Result<Self, Failure> {
		let selection = Self::read(path)?;
		Ok(Self {
			path: path.into(),
			after: Default::default(),
			selection: Mutex::new(selection),
		})
	}

	fn read(path: &Path) -> Result<Option<Selection>, Failure> {
		Ok(match storage::read(&path.join(FILE), 16 * 1024)? {
			Some(data) => serde_json::from_slice(&data)?,
			None => None,
		})
	}

	pub async fn configure(&self, app: &Local, id: &str, mode: Option<&str>) -> Result<Value, Failure> {
		let mut policy = self.selection.lock().await;
		let selected_id = policy
			.as_ref()
			.is_some_and(|current| current.directory.text().as_str() == Some(id));
		if !matches!(mode, None | Some("auto" | "review")) {
			return Err(Failure::invalid("invitation mode must be auto or review"));
		}
		let target = if mode == Some("auto") || (mode.is_none() && selected_id) {
			let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
			let directory = snapshot
				.intent
				.directories
				.as_slice()
				.iter()
				.find(|row| row.id.text().as_str() == Some(id) && row.name.is_some() && row.inbox.is_some());
			match directory {
				Some(directory) => {
					Selection::directory(app, directory, if mode.is_none() { policy.as_ref() } else { None })
						.await?
						.map(|(selection, _)| selection)
				}
				None if mode == Some("auto") => {
					return Err(Failure::invalid(
						"register this session in the directory before enabling automatic invitations",
					));
				}
				None => None,
			}
		} else {
			None
		};
		let next = match mode {
			Some("auto") => target.clone(),
			Some("review") if selected_id => None,
			_ => policy.clone(),
		};
		if *policy != next {
			let bytes = serde_json::to_vec(&next)?;
			if let Err(error) = atomic::replace_at(&self.path, FILE, [bytes.as_slice()]) {
				use rooms_application::documents::WriteFailure;
				match error {
					WriteFailure::Unchanged(cause) => return Err(cause.into()),
					WriteFailure::Indeterminate(cause) => {
						*policy = None;
						*policy = Self::read(&self.path)?;
						return Err(Failure::uncertain(format!("saving invitation policy: {cause}")));
					}
				}
			}
			self.after.set(app.activity.cursor());
			*policy = next;
		}
		Ok(
			json!({"ok":true,"directory":id,"mode":if target.is_some() && *policy == target { "auto" } else { "review" }}),
		)
	}

	pub async fn receive(
		&self,
		app: &Local,
		position: u64,
		token: &str,
		event: &Value,
		origin: &glowcap::Ref,
	) -> Result<(), Failure> {
		let policy = self.selection.lock().await;
		if position <= self.after.get() {
			return Ok(());
		}
		let Some(policy) = policy.as_ref() else { return Ok(()) };
		if event["target"]["kind"] != "direct"
			|| !matches!(event["notice"]["kind"].as_str(), Some("offerRoom" | "handRoom"))
		{
			return Ok(());
		}
		let direct = event["target"]["id"]
			.as_str()
			.ok_or_else(|| Failure::invalid("room invitation has no arrival conversation"))?;
		let name = event["notice"]["label"]
			.as_str()
			.and_then(|s| rooms_application::fields::Text::new(s.into()))
			.ok_or_else(|| Failure::invalid("room invitation has an invalid room label"))?;
		let id = workspace::Id::new(format!("arrival:{token}").as_str().into())
			.ok_or_else(|| Failure::invalid("invalid invitation identity"))?;
		let access = super::accesses::fresh_key::<custody::RoomAccess>()?;
		let source = super::accesses::fresh_key::<custody::SessionAccess>()?;
		let incoming = rooms_glowcap::client::workspace::Workspace::local(
			app.host.clone(),
			rooms_platform::HostPlatform,
			origin.clone(),
		);
		for _ in 0..4 {
			let snapshot = app.workspace.snapshot().await.map_err(peer_failure)?;
			let mut intent = snapshot.intent;
			let Some(directory) = intent.directories.as_slice().iter().find(|row| {
				row.id == policy.directory && row.access == policy.access && row.name.is_some() && row.inbox.is_some()
			}) else {
				return Ok(());
			};
			let Some(dm) = intent.conversations.as_slice().iter().find_map(|row| match row {
				workspace::Conversation::Direct(dm)
					if dm.id.text().as_str() == Some(direct) && dm.directory == policy.directory && !dm.closed =>
				{
					Some(dm.id.clone())
				}
				_ => None,
			}) else {
				return Ok(());
			};
			let Some((_, witness)) = Selection::directory(app, directory, Some(policy)).await? else {
				return Ok(());
			};
			let (access, source) = match intent.invitations.as_slice().iter().find(|inv| inv.id == id) {
				Some(inv) => match (inv.authority, inv.source) {
					(workspace::InvitationAuthority::RoomAccess(key), Some(origin)) => (key, origin),
					_ => {
						return Err(Failure::invalid(
							"the retained invitation has no room entrance or incoming source",
						));
					}
				},
				None => (access, source),
			};
			let selection = workspace::RoomInvitation {
				id: id.clone(),
				name: name.clone(),
				access,
				source,
			};
			if !selection
				.stage(&mut intent, &dm, &policy.directory)
				.map_err(Failure::invalid)?
			{
				return Ok(());
			}
			let acquisition = app
				.custody
				.prepare_room_invitation(&incoming, &witness, token, &selection, snapshot.revision, &intent)
				.await
				.map_err(peer_failure)?;
			match acquisition.submit().await {
				Ok(()) => return Ok(()),
				Err(rooms_glowcap::client::Error::WorkspaceConflict) => continue,
				Err(error) => return Err(peer_failure(error)),
			}
		}
		Err(Failure::conflict(
			"the workspace changed throughout invitation acceptance",
		))
	}
}

/// The terminal journal can pause at a gap. A separate, bounded observer still
/// handles room offers received while the operator is away.
pub(super) fn observe(feed: std::rc::Rc<super::Feed>, report: super::Report) -> super::Observer {
	let mut offers = feed.app.activity.room_offers();
	let (stop, mut stopping) = tokio::sync::watch::channel(false);
	let task = tokio::task::spawn_local(async move {
		let work = async {
			loop {
				match offers.recv().await {
					Ok((position, event)) => {
						let result = async {
							let token = feed.app.activity.token(position).map_err(Failure::uncertain)?;
							let data = serde_json::from_str(&event.data)?;
							feed.invitations
								.receive(&feed.app, position, &token, &data, event.origin.source())
								.await
						}
						.await;
						if let Err(failure) = result {
							let message = format!("automatic room invitation: {}", failure.message);
							report(failure.explained(message));
						}
					}
					Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => report(Failure::exhausted(
						format!("missed {count} room invitations; review pending offers"),
					)),
					Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
				}
			}
		};
		tokio::select! {biased; _=stopping.changed()=>{}, _=work=>{}}
	});
	super::Observer { stop, task }
}
