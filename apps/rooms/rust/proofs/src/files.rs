use rooms_application::files::*;
use std::{
	sync::{
		Arc,
		atomic::{AtomicUsize, Ordering},
	},
	task::{Context, Poll, Wake, Waker},
};

fn description(size: u64) -> FileDescription {
	FileDescription::new("file.bin".into(), "application/octet-stream".into(), size, 0, 0).unwrap()
}

fn limits() -> FileLimits {
	FileLimits {
		pending_bytes: 16,
		pending_files: 4,
		held_bytes: 12,
		held_files: 4,
		room_bytes: 8,
		room_files: 2,
	}
}

fn posted(store: &mut FileStore, member: &FileMember, bytes: &[u8]) -> HostedFile {
	let upload = store.attach(member, description(bytes.len() as u64)).unwrap();
	let file = store.post(member).unwrap().pop().unwrap();
	if !bytes.is_empty() {
		store.write(&upload, bytes).unwrap();
	}
	file
}

fn bytes(store: &mut FileStore, blob: &Blob) -> Vec<u8> {
	match store.read(blob, 0, u64::MAX).unwrap() {
		ReadOutcome::Ready(bytes) => bytes.to_vec(),
		ReadOutcome::Waiting(_) => panic!("expected complete bytes"),
	}
}

fn expired(store: &mut FileStore, blob: &Blob) {
	assert!(matches!(store.read(blob, 0, 1), Err(FileError::Expired)));
}

pub fn run() {
	multiple_rooms();
	pending_and_memberships();
	streaming_and_readers();
	dropped_owners();
	wrong_store_refuses_without_effect();
	empty_files_and_limits();
	chunk_bounds();
	line_mutations();
	attachment_custody();
	current_attachment_fixtures();
	file_calls();
}

fn file_calls() {
	use crate::arguments::{Arg, text};
	use std::{cell::Cell, rc::Rc};
	let mut store = FileStore::default();
	let room = store.room().unwrap();
	let member = store.member(&room).unwrap();
	let upload = store.attach(&member, description(2)).unwrap();
	let chunk = [Arg::Bytes(vec![1, 2])];
	assert_eq!(
		store.upload_call(&upload, "write", &chunk),
		Err(FileCallError::File(FileError::NotPublished))
	);
	let file = store.post(&member).unwrap().pop().unwrap();
	assert_eq!(
		store.upload_call(&upload, "write", &[text("bytes")]),
		Err(FileCallError::WriteArguments)
	);
	let unexpected = Rc::new(Cell::new(0));
	let args = [Arg::List(vec![Arg::Capability(unexpected.clone())])];
	assert_eq!(
		store.upload_call(&upload, "discard", &args),
		Err(FileCallError::UnexpectedCapability)
	);
	assert_eq!(unexpected.get(), 0);
	drop(args);
	assert_eq!(unexpected.get(), 1);
	store.upload_call(&upload, "write", &chunk).unwrap();
	let blob = file.blob();
	assert!(matches!(
		store.blob_call(&blob, "read", &[Arg::Float(0.0), Arg::Integer(1)]),
		Err(FileCallError::Offset)
	));
	assert!(matches!(
		store.blob_call(&blob, "read", &[Arg::Integer(0), Arg::Integer(0)]),
		Err(FileCallError::Length)
	));
	assert!(matches!(
		store
			.blob_call(&blob, "read", &[Arg::Integer(i128::MAX), Arg::Integer(i128::MAX)])
			.unwrap(),
		ReadOutcome::Ready([])
	));
	let args = [Arg::Integer(0), Arg::Integer(2)];
	assert!(matches!(
		store.blob_call(&blob, "read", &args).unwrap(),
		ReadOutcome::Ready([1, 2])
	));
	store.retire(&file).unwrap();
	assert!(matches!(
		store.blob_call(&blob, "read", &args),
		Err(FileCallError::File(FileError::Expired))
	));
}

fn current_attachment_fixtures() {
	use crate::arguments::from_fixture;
	use rooms_application::room::attachment::{read_exact, read_prefix};
	use serde_json::{Value, json};
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/files-protocol.json")).unwrap();
	let defaults = FileLimits::default();
	assert_eq!(
		fixture["limits"],
		json!({"chunk": CHUNK_BYTES, "file": MAX_FILE_BYTES, "pending": defaults.pending_bytes, "held": defaults.held_bytes, "roomBytes": defaults.room_bytes, "roomFiles": defaults.room_files, "idle": UPLOAD_IDLE_MS, "readers": MAX_BLOB_READERS})
	);
	for row in fixture["fixtures"].as_array().unwrap() {
		let args: Vec<_> = row["args"].as_array().unwrap().iter().map(from_fixture).collect();
		assert_eq!(
			read_exact(&args, 0).is_ok(),
			row["exact"].as_bool().unwrap(),
			"attachment fixture: {row}"
		);
		let received: Vec<_> = read_prefix(&args, 0)
			.into_iter()
			.map(|file| {
				let d = &file.description;
				let (width, height) = d.dimensions();
				json!({"name": d.name(), "mime": d.mime(), "size": d.size(), "width": width, "height": height})
			})
			.collect();
		assert_eq!(Value::Array(received), row["prefix"]);
	}
}

fn attachment_custody() {
	use crate::arguments::{Arg, text};
	use rooms_application::room::attachment::{AttachmentError, read_exact, read_prefix};
	use std::{cell::Cell, rc::Rc};
	let kept = Rc::new(Cell::new(0));
	let unexpected = Rc::new(Cell::new(0));
	let mut args = vec![
		text("caption"),
		text("file"),
		text("one.bin"),
		text(""),
		Arg::Integer(1),
		Arg::Capability(kept.clone()),
		Arg::Integer(0),
		Arg::Integer(0),
	];
	args.extend([
		text("file"),
		text("bad.bin"),
		text(""),
		Arg::Integer(-1),
		Arg::Capability(unexpected.clone()),
		Arg::Integer(0),
		Arg::Integer(0),
	]);
	let prefix = read_prefix(&args, 1);
	assert_eq!(prefix.len(), 1);
	assert_eq!(prefix[0].description.name(), "one.bin");
	assert!(matches!(read_exact(&args, 1), Err(AttachmentError::MalformedRecord)));
	assert_eq!(Rc::strong_count(&kept), 3);
	assert_eq!(Rc::strong_count(&unexpected), 2);
	drop(args);
	assert_eq!(Rc::strong_count(&kept), 2);
	assert_eq!(Rc::strong_count(&unexpected), 1);
	drop(prefix);
	assert_eq!(Rc::strong_count(&kept), 1);
	let mut args = vec![];
	for _ in 0..9 {
		args.extend([
			text("file"),
			text("empty"),
			text(""),
			Arg::Integer(0),
			Arg::Capability(kept.clone()),
			Arg::Integer(0),
			Arg::Integer(0),
		]);
	}
	assert_eq!(read_prefix(&args, 0).len(), 8);
	assert!(matches!(read_exact(&args, 0), Err(AttachmentError::TooManyFiles)));
	assert!(matches!(
		read_exact(&args, usize::MAX),
		Err(AttachmentError::IncompleteRecords)
	));
	args.truncate(5);
	assert!(read_prefix(&args, 0).is_empty());
	assert!(matches!(read_exact(&args, 0), Err(AttachmentError::IncompleteRecords)));
	args[3] = Arg::Float(0.0);
	assert!(read_prefix(&args, 0).is_empty());
}

fn line_mutations() {
	use crate::arguments::{Arg, text};
	use rooms_application::room::{line::LineError, message::LineId};
	let mut store = FileStore::new(limits());
	let room = store.room().unwrap();
	let first = store.member(&room).unwrap();
	let second = store.member(&room).unwrap();
	let file = posted(&mut store, &first, &[1; 4]);
	let old_blob = file.blob();
	let mut line = store
		.line(&room, LineId::new(1).unwrap(), "author".into(), &mut vec![file])
		.unwrap();
	let foreign_room = store.room().unwrap();
	let foreign_member = store.member(&foreign_room).unwrap();
	let foreign_upload = store.attach(&foreign_member, description(1)).unwrap();
	let foreign_args = [text("cross-room")];
	assert_eq!(
		store
			.dispatch_line(Some(&foreign_member), &mut line, "refile", &foreign_args)
			.unwrap_err(),
		FileLineError::Files(FileError::WrongRoom)
	);
	assert_eq!(store.staged_count(&foreign_member).unwrap(), 1);
	assert_eq!(store.write(&foreign_upload, &[0]), Err(FileError::NotPublished));
	store.discard(&foreign_upload).unwrap();
	let other_upload = store.attach(&first, description(1)).unwrap();
	let upload = store.attach(&second, description(4)).unwrap();
	let rejected = [text("caption"), Arg::Integer(0), Arg::Integer(0)];
	assert_eq!(
		store
			.dispatch_line(Some(&second), &mut line, "refile", &rejected)
			.unwrap_err(),
		FileLineError::Line(LineError::DuplicateFile(0))
	);
	assert_eq!(store.staged_count(&second).unwrap(), 1);
	assert_eq!(store.write(&upload, &[2]), Err(FileError::NotPublished));
	assert_eq!(bytes(&mut store, &old_blob), [1; 4]);
	// A different holder supplies its own staged files; the line keeps its author.
	let args = [text("caption")];
	let change = store
		.dispatch_line(Some(&second), &mut line, "refile", &args)
		.unwrap()
		.unwrap();
	assert_eq!(change.from, "author");
	assert_eq!(change.files.len(), 1);
	let replacement_blob = change.files[0].blob();
	drop(change);
	expired(&mut store, &old_blob);
	store.write(&upload, &[2; 4]).unwrap();
	assert_eq!(bytes(&mut store, &replacement_blob), [2; 4]);
	assert_eq!(store.staged_count(&first).unwrap(), 1);
	assert_eq!(store.write(&other_upload, &[3]), Err(FileError::NotPublished));
	let change = store
		.dispatch_line::<Arg>(None, &mut line, "withdraw", &[])
		.unwrap()
		.unwrap();
	drop(change);
	expired(&mut store, &replacement_blob);
	assert_eq!(store.usage().held_files, 0);
	assert_eq!(store.usage().pending_bytes, 1);
	assert!(
		store
			.dispatch_line::<Arg>(None, &mut line, "withdraw", &[])
			.unwrap()
			.is_none()
	);
}

fn multiple_rooms() {
	let mut store = FileStore::new(limits());
	let room_a = store.room().unwrap();
	let room_b = store.room().unwrap();
	let alice = store.member(&room_a).unwrap();
	let bob = store.member(&room_b).unwrap();
	let a1 = posted(&mut store, &alice, &[1; 4]);
	let a1_alias = a1.blob();
	let b1 = posted(&mut store, &bob, &[2; 4]);
	let a2 = posted(&mut store, &alice, &[3; 4]);
	assert_eq!(store.usage().held_bytes, 12);
	assert_eq!(store.room_usage(&room_a).unwrap().held_bytes, 8);
	assert_eq!(bytes(&mut store, &a1_alias), [1; 4]);
	let b2 = posted(&mut store, &bob, &[4; 4]);
	// Global oldest-first evicts room A's oldest; other aliases still work.
	expired(&mut store, &a1_alias);
	assert_eq!(bytes(&mut store, &b1.blob()), [2; 4]);
	assert_eq!(bytes(&mut store, &a2.blob()), [3; 4]);
	assert_eq!(store.usage().held_files, 3);
	store.close_room(&room_a).unwrap();
	expired(&mut store, &a2.blob());
	assert_eq!(bytes(&mut store, &b2.blob()), [4; 4]);
	assert_eq!(store.usage().held_bytes, 8);
	assert!(matches!(store.member(&room_a), Err(FileError::Closed)));
	assert!(matches!(store.attach(&alice, description(1)), Err(FileError::Closed)));
	// Recreating a room never reuses any old file capability identity.
	let replacement = store.room().unwrap();
	let member = store.member(&replacement).unwrap();
	let fresh = posted(&mut store, &member, &[5; 4]);
	expired(&mut store, &a1_alias);
	assert_eq!(bytes(&mut store, &fresh.blob()), [5; 4]);
	store.close_room(&room_b).unwrap();
	assert_eq!(store.usage().held_bytes, 4);
	store.close_room(&replacement).unwrap();
	assert_eq!(store.usage(), FileUsage::default());
}

fn pending_and_memberships() {
	let mut store = FileStore::new(limits());
	let room = store.room().unwrap();
	let alice = store.member(&room).unwrap();
	let bob = store.member(&room).unwrap();
	let a = store.attach(&alice, description(8)).unwrap();
	let b = store.attach(&bob, description(8)).unwrap();
	assert_eq!(store.usage().pending_bytes, 16);
	assert!(matches!(store.attach(&bob, description(1)), Err(FileError::Capacity)));
	assert_eq!(store.write(&a, &[1]), Err(FileError::NotPublished));
	let file = store.post(&alice).unwrap().pop().unwrap();
	store.write(&a, &[1; 8]).unwrap();
	store.close_member(&alice).unwrap();
	assert_eq!(bytes(&mut store, &file.blob()), [1; 8]);
	assert_eq!(store.staged_count(&bob).unwrap(), 1);
	store.close_member(&bob).unwrap();
	assert_eq!(store.usage().pending_bytes, 0);
	assert_eq!(store.write(&b, &[2]), Err(FileError::Spent));
	let replacement = store.member(&room).unwrap();
	assert_eq!(store.staged_count(&replacement).unwrap(), 0);
	assert!(matches!(store.post(&alice), Err(FileError::Closed)));
}

#[derive(Default)]
struct WakeCount(AtomicUsize);
impl Wake for WakeCount {
	fn wake(self: Arc<Self>) {
		self.0.fetch_add(1, Ordering::Relaxed);
	}
}

fn streaming_and_readers() {
	let mut store = FileStore::default();
	let room = store.room().unwrap();
	let member = store.member(&room).unwrap();
	let upload = store.attach(&member, description(8)).unwrap();
	let file = store.post(&member).unwrap().pop().unwrap();
	let blob = file.blob();
	let count = Arc::new(WakeCount::default());
	let waker = Waker::from(count.clone());
	let mut cx = Context::from_waker(&waker);
	let mut tickets = Vec::new();
	for _ in 0..MAX_BLOB_READERS {
		let ReadOutcome::Waiting(ticket) = store.read(&blob, 4, 8).unwrap() else {
			panic!("unwritten bytes")
		};
		assert!(store.poll_read(&ticket, &mut cx).is_pending());
		tickets.push(ticket);
	}
	assert!(matches!(store.read(&blob, 4, 8), Err(FileError::ReadersFull)));
	drop(tickets.pop());
	let ReadOutcome::Waiting(cancel_replacement) = store.read(&blob, 4, 8).unwrap() else {
		panic!("waiting")
	};
	drop(cancel_replacement);
	store.write(&upload, &[1, 2, 3, 4]).unwrap();
	assert_eq!(count.0.load(Ordering::Relaxed), 0);
	assert!(store.poll_read(&tickets[0], &mut cx).is_pending());
	assert_eq!(bytes(&mut store, &blob), [1, 2, 3, 4]);
	store.advance(UPLOAD_IDLE_MS - 1).unwrap();
	store.write(&upload, &[5, 6]).unwrap();
	assert_eq!(store.next_deadline(), Some(2 * UPLOAD_IDLE_MS - 1));
	assert_eq!(
		store.poll_read(&tickets[0], &mut cx),
		Poll::Ready(Ok([5, 6].as_slice()))
	);
	// Ready tickets still held by callers must not consume waiting slots.
	let mut later = Vec::new();
	for _ in 0..MAX_BLOB_READERS {
		let ReadOutcome::Waiting(ticket) = store.read(&blob, 6, 2).unwrap() else {
			panic!("later offset is pending")
		};
		assert!(store.poll_read(&ticket, &mut cx).is_pending());
		later.push(ticket);
	}
	let wakes = count.0.load(Ordering::Relaxed);
	store.retire(&file).unwrap();
	assert_eq!(count.0.load(Ordering::Relaxed), wakes + MAX_BLOB_READERS);
	assert_eq!(
		store.poll_read(&tickets[0], &mut cx),
		Poll::Ready(Err(FileError::Expired))
	);
	assert_eq!(store.usage(), FileUsage::default());
	assert_eq!(store.write(&upload, &[7, 8]), Err(FileError::Spent));

	let next = store.attach(&member, description(1)).unwrap();
	let waiting_file = store.post(&member).unwrap().pop().unwrap();
	let waiting_blob = waiting_file.blob();
	let ReadOutcome::Waiting(ticket) = store.read(&waiting_blob, 0, 1).unwrap() else {
		panic!("waiting")
	};
	assert!(store.poll_read(&ticket, &mut cx).is_pending());
	let wakes = count.0.load(Ordering::Relaxed);
	store.advance(2 * UPLOAD_IDLE_MS - 1).unwrap();
	assert!(count.0.load(Ordering::Relaxed) > wakes);
	assert_eq!(store.poll_read(&ticket, &mut cx), Poll::Ready(Err(FileError::Expired)));
	assert_eq!(store.write(&next, &[1]), Err(FileError::Spent));
	assert_eq!(store.advance(0), Err(FileError::ClockReversed));
}

fn dropped_owners() {
	let mut store = FileStore::new(limits());
	let room = store.room().unwrap();
	let member = store.member(&room).unwrap();
	let file = posted(&mut store, &member, &[1; 4]);
	let blob = file.blob();
	drop(file);
	expired(&mut store, &blob);
	assert_eq!(store.usage(), FileUsage::default());
	let file = posted(&mut store, &member, &[2; 4]);
	drop(room);
	expired(&mut store, &file.blob());
	assert_eq!(store.usage(), FileUsage::default());
}

fn wrong_store_refuses_without_effect() {
	let mut first = FileStore::new(limits());
	let mut second = FileStore::new(limits());
	let room = first.room().unwrap();
	let member = first.member(&room).unwrap();
	let file = posted(&mut first, &member, &[9; 4]);
	assert_eq!(second.close_room(&room), Err(FileError::WrongStore));
	assert_eq!(second.close_member(&member), Err(FileError::WrongStore));
	assert_eq!(second.retire(&file), Err(FileError::WrongStore));
	assert!(matches!(second.read(&file.blob(), 0, 1), Err(FileError::WrongStore)));
	assert_eq!(bytes(&mut first, &file.blob()), [9; 4]);
}

fn empty_files_and_limits() {
	let mut store = FileStore::new(FileLimits {
		pending_files: 2,
		held_files: 2,
		room_files: 2,
		..limits()
	});
	let room = store.room().unwrap();
	let member = store.member(&room).unwrap();
	let empty = store.attach(&member, description(0)).unwrap();
	store.discard(&empty).unwrap();
	assert!(store.post(&member).unwrap().is_empty());
	let a = posted(&mut store, &member, &[]);
	let b = posted(&mut store, &member, &[]);
	let c = posted(&mut store, &member, &[]);
	expired(&mut store, &a.blob());
	assert!(bytes(&mut store, &b.blob()).is_empty());
	assert!(bytes(&mut store, &c.blob()).is_empty());
	assert_eq!(store.usage().held_files, 2);
	let _first = store.attach(&member, description(0)).unwrap();
	let _second = store.attach(&member, description(0)).unwrap();
	assert!(matches!(
		store.attach(&member, description(0)),
		Err(FileError::Capacity)
	));
	assert!(FileDescription::new("🙂".repeat(81), "".into(), 0, 0, 0).is_err());
	assert_eq!(
		FileDescription::new("".into(), "".into(), 0, 0, 0),
		Err(FileError::Description)
	);
	assert_eq!(
		FileDescription::new("a".into(), "".into(), MAX_FILE_BYTES as u64 + 1, 0, 0),
		Err(FileError::Size)
	);
}

fn chunk_bounds() {
	let mut store = FileStore::default();
	let room = store.room().unwrap();
	let member = store.member(&room).unwrap();
	let upload = store.attach(&member, description(CHUNK_BYTES as u64 + 1)).unwrap();
	let file = store.post(&member).unwrap().pop().unwrap();
	assert_eq!(
		store.write(&upload, &vec![0; CHUNK_BYTES + 1]),
		Err(FileError::ChunkTooLarge)
	);
	store.write(&upload, &vec![7; CHUNK_BYTES]).unwrap();
	assert_eq!(store.write(&upload, &[8, 9]), Err(FileError::PastEnd));
	store.write(&upload, &[8]).unwrap();
	assert_eq!(bytes(&mut store, &file.blob()).len(), CHUNK_BYTES);
	assert!(matches!(
		store.read(&file.blob(), u64::MAX, u64::MAX).unwrap(),
		ReadOutcome::Ready([])
	));
	assert!(matches!(store.read(&file.blob(), 0, 0), Err(FileError::InvalidRead)));
	assert_eq!(store.write(&upload, &[]), Err(FileError::Spent));
}
