use super::arguments::{self, Arg};
use rooms_application::room::{
	inbox::{self, Message, Notice, metadata::Presence, queue},
	membership::{self, Membership},
	policy::MembershipKind,
};
use serde_json::{Value, json};
use std::{cell::Cell, rc::Rc};
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/membership.json")).unwrap();
	for row in fixture["memberships"].as_array().unwrap() {
		let args = row["answer"]
			.as_array()
			.map(|a| a.iter().map(arguments::from_fixture).collect::<Vec<_>>());
		let result = args
			.as_ref()
			.and_then(|a| membership::read_answer(a).ok())
			.map(|s| json!({"kind":s.kind.as_str(),"topic":s.topic.is_some(),"files":s.files.is_some()}))
			.unwrap_or(Value::Null);
		assert_eq!(result, row["result"]);
	}
	for row in fixture["inbox"].as_array().unwrap() {
		let args: Vec<_> = row["args"]
			.as_array()
			.unwrap()
			.iter()
			.map(arguments::from_fixture)
			.collect();
		let result = inbox::read("notify", &args);
		assert_eq!(result.is_ok(), row["accepted"].as_bool().unwrap(), "case {}", row["at"]);
		let mut events = Vec::new();
		if let Ok(notice) = result {
			match notice {
   Notice::Ended(reason)=>events.push(json!(["ended",reason])),
   Notice::Typing{name,on}=>events.push(json!(["typing",name,on])),
   Notice::Policy(policy)=>events.push(json!(["policyChanged",policy])),
   Notice::Authority{kind,token,claimable}=>events.push(json!(["authorityChanged",{"kind":match kind {rooms_application::room::stewardship::Kind::Room=>"room",rooms_application::room::stewardship::Kind::Manager=>"manager",_=>"steward"},"token":token,"claimable":claimable}])),
   Notice::Occupancy{listed,claimable}=>{events.push(json!(["listed",listed]));if let Some(on)=claimable {events.push(json!(["authorityStatus",on]));}events.push(json!(["arrived"]));},
   Notice::Line(message)=>{
    if let Some(listed)=message.facts.as_ref().and_then(|f|f.listed){events.push(json!(["listed",listed]));if let Some(on)=row["args"][3].as_bool(){events.push(json!(["authorityStatus",on]));}}
    let mut line=json!({"from":message.from,"text":message.text,"system":message.from=="room","attachments":message.attachments.iter().map(|a|{
      let d=&a.description;let (width,height)=d.dimensions();json!({"name":d.name(),"mime":d.mime(),"size":d.size(),"blob":{"capability":true},"width":width,"height":height})}).collect::<Vec<_>>()});
    if let Some(p)=&message.presence {line["presence"]=serde_json::to_value(p).unwrap();}
    if let Some(f)=&message.facts {line["facts"]=serde_json::to_value(f).unwrap();}
    if let Some(marker)=message.marker {line["lineId"]=json!(marker.id.get());line["change"]=json!(match marker.kind.wire_tag(){"line"=>"said",tag=>tag});}
    events.push(json!(["line",line]));
    if message.arrived(){events.push(json!(["arrived"]));}
   }
  }
		}
		assert_eq!(json!(events), row["events"], "case {}", row["at"]);
	}
	state_and_queue();
}
fn state_and_queue() {
	let mut state = Membership::<()>::new();
	state.arrived();
	assert!(!state.ready());
	state
		.accept(membership::Seat {
			reference: (),
			kind: MembershipKind::Observer,
			topic: None,
			files: None,
		})
		.unwrap();
	assert!(state.ready());
	state.retire();
	state.arrived();
	assert!(!state.ready());
	assert!(
		state
			.accept(membership::Seat {
				reference: (),
				kind: MembershipKind::Participant,
				topic: None,
				files: None,
			})
			.is_err()
	);
	let cap = Rc::new(Cell::new(0));
	let args = [
		arguments::text("alice"),
		arguments::text("file"),
		arguments::text("file"),
		arguments::text("a"),
		arguments::text("text/plain"),
		Arg::Integer(1),
		Arg::Capability(cap.clone()),
		Arg::Integer(0),
		Arg::Integer(0),
	];
	let mut first = queue::Queue::default();
	let mut second = queue::Queue::default();
	for _ in 0..queue::MAX_MESSAGES {
		let Notice::Line(m) = inbox::read("notify", &args).unwrap() else {
			panic!()
		};
		first.push(m).unwrap();
	}
	let Notice::Line(m) = inbox::read("notify", &args).unwrap() else {
		panic!()
	};
	second.push(m).unwrap();
	let Notice::Line(m) = inbox::read("notify", &args).unwrap() else {
		panic!()
	};
	assert_eq!(first.push(m), Err(queue::Error::Overflow));
	assert_eq!(Rc::strong_count(&cap), 3); // original, delivered argument and sibling queue
	assert!(matches!(first.pop(), Err(queue::Error::Overflow)));
	let received = second.pop().unwrap().unwrap();
	second.close();
	assert_eq!(Rc::strong_count(&cap), 3);
	drop(received);
	assert_eq!(Rc::strong_count(&cap), 2);
	let mut bytes = queue::Queue::<()>::default();
	let large = "x".repeat(queue::MAX_MESSAGE_BYTES);
	let message = Message {
		from: "room",
		text: "away",
		presence: Some(Presence::Away {
			name: "a",
			reason: &large,
		}),
		facts: None,
		marker: None,
		attachments: vec![],
		previews: Default::default(),
	};
	assert_eq!(bytes.push(message), Err(queue::Error::Overflow));
	assert!(core::mem::size_of::<Message<String, ()>>() <= 224); // ordinary lines don't inline bridge-only details
}
