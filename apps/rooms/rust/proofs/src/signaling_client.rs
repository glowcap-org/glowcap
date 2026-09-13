use super::arguments::from_fixture;
use rooms_application::signaling::{self as signal, Candidate, Description, Error, Exchange, Id, Reply};
use serde_json::{Value, json};
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/signaling-client.json")).unwrap();
	assert_eq!(
		fixture["limits"],
		json!({"description":signal::MAX_DESCRIPTION,"id":signal::MAX_ID,"candidate":signal::MAX_CANDIDATE})
	);
	for row in fixture["replies"].as_array().unwrap() {
		let value = match row["kind"].as_str().unwrap() {
			"capability" => json!({"capability":true}),
			"repeat" => json!(row["text"].as_str().unwrap().repeat(65)),
			_ => row["text"].clone(),
		};
		let mut values = vec![value];
		if row["extra"] == true {
			values.push(json!("extra"));
		}
		let args: Vec<_> = values.iter().map(from_fixture).collect();
		assert_eq!(
			signal::reply(row["verb"].as_str().unwrap(), args.len(), |i| args.get(i)).is_ok(),
			row["accepted"] == true
		);
	}
	for row in fixture["bounds"].as_array().unwrap() {
		let payload = row["payload"]
			.as_str()
			.unwrap()
			.repeat(row["count"].as_u64().unwrap() as usize);
		let values = [row["id"].clone(), json!(payload)];
		let args: Vec<_> = values.iter().map(from_fixture).collect();
		let verb = if row["kind"] == "description" {
			"offer"
		} else {
			"candidate"
		};
		assert_eq!(
			signal::incoming(verb, 2, |i| args.get(i)).is_ok(),
			row["accepted"] == true
		);
	}
	let id = || Id::parse("exchange").unwrap();
	let answer = || Description::parse("answer").unwrap();
	let mut exchange = Exchange::<Error>::default();
	assert_eq!(exchange.answer(), Err(Error::NotStarted));
	exchange.start().unwrap();
	assert_eq!(exchange.start(), Err(Error::Duplicate));
	exchange.receive(Reply::Answer(answer())).unwrap();
	assert!(exchange.settled().is_none());
	exchange.receive(Reply::Accepted(id())).unwrap();
	assert_eq!(exchange.answer().unwrap().unwrap(), answer());
	exchange
		.receive(Reply::Accepted(Id::parse("changed").unwrap()))
		.unwrap();
	exchange
		.receive(Reply::Rejected(Description::parse("late").unwrap()))
		.unwrap();
	assert_eq!(exchange.accepted().unwrap().unwrap(), id());
	assert_eq!(exchange.answer().unwrap().unwrap(), answer());
	assert_eq!(exchange.retire(), Some(id()));
	assert_eq!(exchange.retire(), None);
	assert_eq!(exchange.receive(Reply::Answer(answer())), Err(Error::Ended));
	assert!(exchange.candidate().unwrap().is_none());
	// An early answer cannot disable the acceptance deadline.
	let mut early = Exchange::<Error>::default();
	early.start().unwrap();
	early.receive(Reply::Answer(answer())).unwrap();
	early.fail(Error::Ended);
	assert_eq!(early.answer(), Err(Error::Ended));
	early.receive(Reply::Accepted(id())).unwrap();
	assert_eq!(early.accepted(), Err(Error::Ended));
	let mut refused = Exchange::<Error>::default();
	refused.start().unwrap();
	refused.receive(Reply::Accepted(id())).unwrap();
	refused.fail(Error::Rejected(Description::parse("no").unwrap()));
	assert_eq!(refused.accepted().unwrap(), Some(id()));
	assert!(refused.answer().is_err());
	assert!(refused.candidate().is_err());
	assert_eq!(refused.retire(), Some(id()));
	let mut queue = signal::Queue::default();
	for _ in 0..signal::MAX_EVENTS {
		queue.push(Candidate::parse("ice").unwrap()).unwrap();
	}
	assert_eq!(queue.push(Candidate::parse("overflow").unwrap()), Err(Error::Overflow));
	assert_eq!(queue.pop(), Err(Error::Overflow));
}
