//! Custody and ordering are independent of the future awaiting a post reply.
use super::*;
use rooms_application::room::inbox::{
	metadata::Metadata,
	queue::{self, MAX_MESSAGES},
};

fn receipt(request: u64, line: u64) -> Receipt<'static, Ref> {
	Receipt {
		request,
		line: rooms_application::room::message::LineId::new(line).unwrap(),
		from: "Alice",
		text: None,
		previews: "[]",
		attachments: vec![],
	}
}

#[test]
fn requests_are_bounded_and_scoped_without_retaining_the_membership() {
	let owner = Rc::new(RefCell::new(messages::Delivery {
		queue: Queue::default(),
		pending: Pending::default(),
		waiter: None,
	}));
	let other = Rc::new(RefCell::new(messages::Delivery {
		queue: Queue::default(),
		pending: Pending::default(),
		waiter: None,
	}));
	let request = Request {
		id: owner.borrow_mut().pending.next().unwrap(),
		owner: Rc::downgrade(&owner),
	};
	assert_eq!(
		Rc::strong_count(&owner),
		1,
		"a reserved identity does not keep a membership alive"
	);
	assert!(matches!(
		request.consume(&other),
		Err(Error::Receipt(receipt::Error::InvalidRequest))
	));
	let request = Request {
		id: owner.borrow_mut().pending.next().unwrap(),
		owner: Rc::downgrade(&owner),
	};
	assert_eq!(request.consume(&owner).unwrap(), 1);
	let mut pending = Pending {
		next: receipt::MAX_REQUEST,
		..Default::default()
	};
	assert_eq!(pending.next().unwrap(), receipt::MAX_REQUEST);
	assert!(matches!(pending.next(), Err(Error::Receipt(receipt::Error::Exhausted))));
}

#[test]
fn correlation_moves_the_right_owned_payload_in_receipt_order() {
	let mut pending = Pending::default();
	let mut queue = Queue::default();
	let first = pending.next().unwrap();
	let second = pending.next().unwrap();
	pending.insert(first, "first", &mut queue).unwrap();
	pending.insert(second, "second", &mut queue).unwrap();
	let pointer = pending.posts[1].1.text.as_ptr();
	let message = pending.complete(receipt(second, 1), &mut queue).unwrap();
	assert_eq!(
		message.text.as_ptr(),
		pointer,
		"retained text moves without another allocation"
	);
	queue.push_owned(message).unwrap();
	let message = pending.complete(receipt(first, 2), &mut queue).unwrap();
	queue.push_owned(message).unwrap();
	let second_message = queue.pop().unwrap().unwrap();
	assert_eq!(second_message.text.as_ptr(), pointer);
	assert_eq!(
		(
			second_message.text.as_str(),
			match second_message.metadata {
				Some(Metadata::Receipt(request)) => Some(request),
				_ => None,
			}
		),
		("second", Some(second))
	);
	assert_eq!(queue.pop().unwrap().unwrap().text, "first");
	assert!(pending.posts.is_empty());
	assert!(matches!(
		pending.complete(receipt(first, 2), &mut queue),
		Err(receipt::Error::Unknown)
	));
}

#[test]
fn pending_and_unread_messages_share_admission_until_the_consumer_closes() {
	let mut pending = Pending::default();
	let mut queue = Queue::default();
	for _ in 0..MAX_MESSAGES {
		let id = pending.next().unwrap();
		pending.insert(id, "x", &mut queue).unwrap();
	}
	let extra = pending.next().unwrap();
	assert!(pending.insert(extra, "x", &mut queue).is_err());
	let message = pending.complete(receipt(0, 1), &mut queue).unwrap();
	queue.push_owned(message).unwrap();
	assert!(
		pending.insert(extra, "x", &mut queue).is_err(),
		"a receipt transfers rather than frees its backlog slot"
	);
	queue.pop().unwrap().unwrap();
	pending.insert(extra, "x", &mut queue).unwrap();
	let shared = Rc::new(RefCell::new(messages::Delivery {
		pending,
		queue,
		waiter: None,
	}));
	drop(messages::Messages { shared: shared.clone() });
	assert!(
		shared.borrow().pending.posts.is_empty(),
		"consumer closure releases outgoing retained bytes too"
	);
	assert!(matches!(shared.borrow_mut().queue.pop(), Err(queue::Error::Closed)));
}

#[test]
fn large_pending_bodies_spend_the_byte_budget_before_the_line_limit() {
	let mut pending = Pending::default();
	let mut queue = Queue::default();
	let text = "x".repeat(rooms_application::room::line::MAX_LINE_BYTES);
	let refused = loop {
		let request = pending.next().unwrap();
		match pending.insert(request, &text, &mut queue) {
			Ok(()) => assert!(
				pending.posts.len() < MAX_MESSAGES,
				"body and metadata must share the byte ceiling"
			),
			Err(Error::Receipt(receipt::Error::Full)) => break request,
			Err(error) => panic!("unexpected admission refusal: {error}"),
		}
	};
	assert!(pending.posts.len() > 1);
	pending.discard(0, &mut queue);
	pending.insert(refused, &text, &mut queue).unwrap();
	let extra = pending.next().unwrap();
	assert!(matches!(
		pending.insert(extra, &text, &mut queue),
		Err(Error::Receipt(receipt::Error::Full))
	));
}

#[test]
fn server_caption_and_preview_normalization_win_over_the_retained_request() {
	let mut pending = Pending::default();
	let mut queue = Queue::default();
	let request = pending.next().unwrap();
	pending.insert(request, "", &mut queue).unwrap();
	let mut notice = receipt(request, 1);
	notice.text = Some("first-file.png");
	assert_eq!(pending.complete(notice, &mut queue).unwrap().text, "first-file.png");
	let request = pending.next().unwrap();
	pending
		.insert(request, "https://example.org/a https://example.org/b", &mut queue)
		.unwrap();
	let mut notice = receipt(request, 2);
	notice.previews = "[\"https://example.org/a\",\"https://example.org/b\"]";
	let message = pending.complete(notice, &mut queue).unwrap();
	assert_eq!(
		message.previews.urls(),
		["https://example.org/a", "https://example.org/b"]
	);
}

#[test]
fn malformed_receipt_preserves_payload_and_shared_admission_for_a_valid_retry() {
	let mut pending = Pending::default();
	let mut queue = Queue::default();
	for _ in 0..MAX_MESSAGES {
		let request = pending.next().unwrap();
		pending.insert(request, "retained", &mut queue).unwrap();
	}
	let original = pending.posts[0].1.text.as_ptr();
	let mut malformed = receipt(0, 1);
	malformed.previews = "not JSON";
	assert!(matches!(
		pending.complete(malformed, &mut queue),
		Err(receipt::Error::Malformed)
	));
	assert_eq!(pending.posts.len(), MAX_MESSAGES);
	assert_eq!(pending.posts[0].1.text.as_ptr(), original);
	let extra = pending.next().unwrap();
	assert!(
		pending.insert(extra, "extra", &mut queue).is_err(),
		"invalid receipt cannot release its retained charge"
	);
	let message = pending.complete(receipt(0, 1), &mut queue).unwrap();
	assert_eq!(message.text.as_ptr(), original);
	queue.push_owned(message).unwrap();
	assert_eq!(queue.pop().unwrap().unwrap().text, "retained");
	pending.insert(extra, "extra", &mut queue).unwrap();
	assert!(matches!(
		pending.complete(receipt(0, 1), &mut queue),
		Err(receipt::Error::Unknown)
	));
}
