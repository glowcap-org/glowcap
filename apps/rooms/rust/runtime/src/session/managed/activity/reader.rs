//! Local actors own asynchronous original-source checks. Managed read facades
//! additionally check the viewer before dispatch and after every result wait.
use super::*;
use glowcap::{Argument, Host};
use rooms_glowcap::client::workspace::Workspace;
use serde_json::json;
use std::future::Future;

/// One fixed file actor state shares event metadata and its live byte charge.
/// The ring holds the actor root. Returned facades can retain it after eviction.
/// Its weak Activity link cannot keep session retirement alive.
struct File<P: Tasks> {
	activity: Weak<Activity<P>>,
	host: Host,
	platform: P,
	event: Rc<Event<P>>,
	index: usize,
	reader: tokio::sync::Mutex<Option<Ref>>,
}
pub(super) fn file_bytes<P: Tasks>() -> usize {
	size_of::<File<P>>() + 2 * size_of::<usize>() + size_of::<Rc<File<P>>>() + size_of::<Ref>()
}
impl<P: Tasks + Deadline + Clone + 'static> Activity<P> {
	pub(in crate::session::managed) fn reader(self: &Rc<Self>, host: &Host, platform: P) -> Result<Ref> {
		if let Some(reader) = &*self.reader.borrow() {
			return Ok(reader.clone());
		}
		let weak = Rc::downgrade(self);
		let actor_host = host.clone();
		let reader = host.spawn(move |verb, args| {
			let [Argument::String(cursor), Argument::Boolean(wait)] = args else {
				return Err("activity read takes a cursor and wait choice".into());
			};
			if verb != "read" {
				return Err("activity reader accepts only read".into());
			}
			let activity = weak.upgrade().ok_or("Session activity has closed")?;
			let cursor = if cursor.is_empty() {
				0
			} else {
				activity.parse_token(cursor).map_err(|e| e.to_string())?
			};
			let weak_read = weak.clone();
			let host = actor_host.clone();
			let platform_read = platform.clone();
			let wait = *wait;
			answer(&weak, &actor_host, &platform, async move {
				next(&weak_read, &host, platform_read, cursor, wait).await
			})
		})?;
		*self.reader.borrow_mut() = Some(reader.clone());
		Ok(reader)
	}
	pub(in crate::session::managed) fn file_actor(
		self: &Rc<Self>,
		host: &Host,
		platform: P,
		event: Rc<Event<P>>,
		index: usize,
	) -> Result<Ref> {
		if index >= event.files.len() {
			return Err(loam::refusal("activity file index is absent"));
		}
		let file = Rc::new(File {
			activity: Rc::downgrade(self),
			host: host.clone(),
			platform,
			event,
			index,
			reader: tokio::sync::Mutex::new(None),
		});
		host.spawn(move |verb, args| {
			let [Argument::Integer(offset), Argument::Integer(maximum)] = args else {
				return Err("file read takes offset and bounded chunk length".into());
			};
			if verb != rooms_application::protocol_data::READ {
				return Err("file reader accepts only read".into());
			}
			let offset = u64::try_from(*offset).map_err(|_| "invalid file offset")?;
			let maximum = usize::try_from(*maximum).map_err(|_| "invalid chunk length")?;
			if maximum == 0 || maximum > rooms_application::files::CHUNK_BYTES {
				return Err("file read exceeds chunk bound".into());
			}
			let reading = file.clone();
			answer(&file.activity, &file.host, &file.platform, async move {
				let File {
					host,
					platform,
					event,
					index,
					reader,
					..
				} = &*reading;
				event.origin.check(host, platform.clone()).await?;
				let file = &event.files[*index];
				let length = rooms_application::files::transfer::read_length(file.description.size(), offset, maximum)
					.map_err(|e| loam::refusal(e.to_string()))?;
				let mut reader = reader.lock().await;
				if reader.is_none() {
					let source = Workspace::local(host.clone(), platform.clone(), event.origin.source().clone());
					*reader = Some(
						source
							.file_reader(&file.blob)
							.await
							.map_err(|e| loam::refusal(e.to_string()))?,
					);
				}
				let result = host
					.send(
						reader
							.as_ref()
							.ok_or_else(|| loam::refusal("file reader is not held"))?,
						rooms_application::protocol_data::READ,
						&[(offset as i64).into(), (maximum as i64).into()],
					)
					.await?;
				event.origin.check(host, platform.clone()).await?;
				match result {
					Argument::Bytes(bytes) if bytes.len() <= length => Ok(Argument::Bytes(bytes)),
					_ => Err(loam::refusal("file returned an invalid chunk")),
				}
			})
		})
	}
}

/// This queue bounds real reads, including admission and long-poll waits.
/// Tasks hold weak journal ownership across waits, so retirement cannot cycle.
pub(in crate::session::managed) fn answer<P: Tasks + Deadline + Clone + 'static>(
	weak: &Weak<Activity<P>>,
	host: &Host,
	platform: &P,
	work: impl Future<Output = Result<Argument>> + 'static,
) -> core::result::Result<Argument, String> {
	let activity = weak.upgrade().ok_or("Session activity has closed")?;
	if activity.closed.get() {
		return Err("Session activity has closed".into());
	}
	if activity.reads.borrow().len() == MAX_READS {
		return Err("Session activity read queue is full".into());
	}
	let id = activity.next_read.get();
	let next = id.checked_add(1).ok_or("Activity read identities exhausted")?;
	let mut resolver = host
		.defer_turn_if_answer()
		.map_err(|e| e.to_string())?
		.ok_or("activity reads require an answer")?;
	let weak = weak.clone();
	let task = platform.spawn(async move {
		let result = work.await;
		let outcome = match result {
			Ok(value) => resolver.fulfill_value(&value),
			Err(error) => resolver.break_with(&error.to_string()),
		};
		if let Some(activity) = weak.upgrade() {
			if let Err(error) = outcome {
				let cleanup = resolver.break_with(&error.to_string());
				let error = error.with_cleanup(cleanup);
				activity.failure.borrow_mut().get_or_insert(error);
			}
			activity.reads.borrow_mut().remove(&id);
			activity.changed.notify_waiters();
		}
	});
	activity.reads.borrow_mut().insert(id, task);
	activity.next_read.set(next);
	Ok(Argument::Void)
}

async fn next<P: Tasks + Deadline + Clone + 'static>(
	weak: &Weak<Activity<P>>,
	host: &Host,
	platform: P,
	cursor: u64,
	wait: bool,
) -> Result<Argument> {
	let delivery = receive(weak, host, platform, cursor, wait).await?;
	let activity = weak
		.upgrade()
		.ok_or_else(|| loam::refusal("Session activity has closed"))?;
	let token = activity.token(delivery.cursor)?;
	if delivery.unavailable {
		return Ok(json!({"cursor":token,"unavailable":true}).to_string().into());
	}
	if delivery.gap {
		return Ok(json!({"cursor":token,"gap":true}).to_string().into());
	}
	let Some(event) = delivery.event else {
		return Ok(json!({"cursor":token}).to_string().into());
	};
	let files = event
		.files
		.iter()
		.map(|file| {
			let (width, height) = file.description.dimensions();
			json!({"name":file.description.name(),"mime":file.description.mime(),"size":file.description.size(),
			"width":width,"height":height})
		})
		.collect::<Vec<_>>();
	Ok(
		json!({"cursor":token,"data":event.data,"files":files,"history":event.history().map(rooms_application::archive::history_data),
		"incoming":event.incoming.as_ref().map(super::Incoming::role)})
		.to_string()
		.into(),
	)
}
pub(super) async fn receive<P: Tasks + Deadline + Clone + 'static>(
	weak: &Weak<Activity<P>>,
	host: &Host,
	platform: P,
	cursor: u64,
	wait: bool,
) -> Result<ActivityDelivery<P>> {
	loop {
		let activity = weak
			.upgrade()
			.ok_or_else(|| loam::refusal("Session activity has closed"))?;
		if activity.closed.get() {
			return Err(loam::refusal("Session activity has closed"));
		}
		let changed = activity.changed.clone();
		let notified = changed.notified();
		tokio::pin!(notified);
		notified.as_mut().enable();
		let end = activity.cursor();
		if cursor > end {
			return Err(loam::refusal("activity cursor belongs to another incarnation"));
		}
		let selected = activity
			.entries
			.borrow()
			.iter()
			.find(|entry| entry.id > cursor)
			.map(|entry| (entry.id, entry.event.clone()));
		let oldest = activity.entries.borrow().front().map(|entry| entry.id);
		drop(activity);
		if let Some(oldest) = oldest
			&& cursor + 1 < oldest
		{
			return Ok(ActivityDelivery {
				cursor: oldest - 1,
				gap: true,
				unavailable: false,
				event: None,
			});
		}
		if let Some((id, event)) = selected {
			let admitted = event.origin.admitted(host, platform.clone()).await?;
			return Ok(ActivityDelivery {
				cursor: id,
				gap: false,
				unavailable: !admitted,
				event: admitted.then_some(event),
			});
		}
		if !wait {
			return Ok(ActivityDelivery {
				cursor: end,
				gap: false,
				unavailable: false,
				event: None,
			});
		}
		if platform.within(5_000, notified).await.is_none() {
			return Ok(ActivityDelivery {
				cursor: end,
				gap: false,
				unavailable: false,
				event: None,
			});
		}
	}
}
