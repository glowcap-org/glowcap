use super::arguments::{Arg, from_fixture, text};
use rooms_application::direct::{self, Notice};
use serde_json::{Value, json};
use std::{cell::Cell, rc::Rc};

pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/direct-client.json")).unwrap();
	for row in fixture.as_array().unwrap() {
		let args: Vec<_> = row["args"]
			.as_array()
			.unwrap()
			.iter()
			.map(|v| {
				if let Some(s) = v["text"].as_str() {
					Arg::Text(s.repeat(v["count"].as_u64().unwrap() as usize))
				} else {
					from_fixture(v)
				}
			})
			.collect();
		let result = direct::read(row["verb"].as_str().unwrap(), &args);
		assert_eq!(result.is_ok(), row["accepted"].as_bool().unwrap(), "{}", row["name"]);
		let Ok(notice) = result else { continue };
		let got = match notice {
			Notice::Message {
				text,
				reply,
				attachments,
				previews: _,
			} => json!({"kind":"message","bytes":text.len(),"reply":reply.is_some(),"files":attachments.len()}),
			Notice::Ready(_) => json!({"kind":"ready"}),
			Notice::Typing(on) => json!({"kind":"typing","on":on}),
			Notice::HandRoom { label, .. } => json!({"kind":"handRoom","label":label}),
			Notice::OfferRoom { label, link } => json!({"kind":"offerRoom","label":label,"link":link}),
			Notice::HandArchive {
				directory,
				kind,
				conversation,
				..
			} => json!({"kind":"handArchive","directory":directory,"share":kind.wire(),"conversation":conversation}),
			Notice::OfferArchive {
				directory,
				kind,
				conversation,
				link,
			} => {
				json!({"kind":"offerArchive","directory":directory,"share":kind.wire(),"conversation":conversation,"link":link})
			}
		};
		assert_eq!(got, row["result"], "{}", row["name"]);
	}
	// The parser borrows text and retains only admitted top-level occurrences.
	// The binding's original argument tree keeps custody of everything else.
	let reply = Rc::new(Cell::new(0));
	let blob = Rc::new(Cell::new(0));
	let discarded = Rc::new(Cell::new(0));
	let args = vec![
		text("kept"),
		Arg::Capability(reply.clone()),
		text("file"),
		text("a"),
		text("text/plain"),
		Arg::Integer(1),
		Arg::Capability(blob.clone()),
		Arg::Integer(0),
		Arg::Integer(0),
		Arg::List(vec![Arg::Capability(discarded.clone())]),
	];
	let notice = direct::read("dm", &args).unwrap();
	assert_eq!(Rc::strong_count(&reply), 3);
	assert_eq!(Rc::strong_count(&blob), 3);
	assert_eq!(Rc::strong_count(&discarded), 2);
	let Notice::Message { text: borrowed, .. } = &notice else {
		panic!("message")
	};
	let Arg::Text(original) = &args[0] else { panic!("text") };
	assert_eq!(borrowed.as_ptr(), original.as_ptr());
	drop(notice);
	assert_eq!(Rc::strong_count(&reply), 2);
	drop(args);
	for occurrence in [reply, blob, discarded] {
		assert_eq!(occurrence.get(), 1);
		assert_eq!(Rc::strong_count(&occurrence), 1);
	}
}
