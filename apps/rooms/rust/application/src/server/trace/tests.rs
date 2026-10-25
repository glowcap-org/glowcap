use super::{records::*, *};

fn opened(session: &str) -> Map<String, Value> {
	parse_record(&format!(
		r#"{{"v":1,"sim_t_ns":5,"kind":"ocapn.session-opened","session":"{session}","a":"me","b":"you","transport":"tcp","captp_version":"1.0","seq":99,"replay":true}}"#
	))
	.unwrap()
}

#[test]
fn two_producers_identical_ids_stay_apart_and_replay_is_the_live_topology() {
	let mut endpoint = Endpoint::new(7);
	let p0 = endpoint.admit_producer(false).unwrap();
	let p1 = endpoint.admit_producer(true).unwrap();
	let first = endpoint.ingest(&p0, opened("live-h1-s1"), 10);
	let second = endpoint.ingest(&p1, opened("live-h1-s1"), 11);
	assert_eq!(first.len(), 1);
	assert!(first[0].line.contains("\"session\":\"p0/live-h1-s1\""));
	assert!(second[0].line.contains("\"session\":\"p1/live-h1-s1\""));
	assert!(first[0].line.contains("\"seq\":1") && second[0].line.contains("\"seq\":2"));
	assert!(first[0].line.contains("\"epoch\":7") && first[0].line.contains("\"sim_t_ns\":10"));
	// A message for an unknown row is dropped; one for a known row forwards.
	let message = parse_record(
		r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.message-decoded","session":"live-h1-s9","outbound":true,"digest":"00112233445566778899aabbccddeeff"}"#,
	)
	.unwrap();
	assert!(endpoint.ingest(&p0, message.clone(), 12).is_empty());
	let mut known = message;
	known.insert("session".into(), Value::from("live-h1-s1"));
	assert_eq!(endpoint.ingest(&p0, known, 12).len(), 1);
	let meta = parse_record(
		r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-meta","session":"live-h1-s1","meta":{"label":"rooms"}}"#,
	)
	.unwrap();
	endpoint.ingest(&p1, meta, 13);
	let replay = endpoint.replay(20);
	assert_eq!(replay.len(), 4, "two opens, one meta, the end mark");
	assert!(replay[..3].iter().all(|line| line.starts_with("{\"replay\":true,")));
	assert!(replay[3].contains("trace.replay-end") && !replay[3].contains("seq"));
	// A producer leaving takes its rows without announcing a close.
	let left = endpoint.drop_producer(&p1, true, 30);
	assert_eq!(left.len(), 1);
	assert!(left[0].line.contains("trace.producer-left") && left[0].line.contains("\"scope\":\"p1\""));
	assert_eq!(endpoint.replay(31).len(), 2);
	let closed = parse_record(r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-closed","session":"live-h1-s1"}"#).unwrap();
	assert_eq!(endpoint.ingest(&p0, closed, 32).len(), 1);
	assert_eq!(endpoint.replay(33).len(), 1);
}

#[test]
fn a_line_that_is_not_a_timeline_record_is_refused() {
	assert!(parse_record("nope").is_none());
	assert!(parse_record("[1]").is_none());
	assert!(parse_record(r#"{"v":2,"sim_t_ns":1,"kind":"ocapn.session-closed","session":"s"}"#).is_none());
	assert!(parse_record(r#"{"v":1,"sim_t_ns":1,"kind":"trace.replay-end","session":"s"}"#).is_none());
	assert!(parse_record(r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-closed","session":"s","extra":1}"#).is_none());
	assert!(parse_record(r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-closed","session":""}"#).is_none());
	assert!(
		parse_record(
			r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-opened","session":"s","a":"","b":"y","transport":"tcp"}"#
		)
		.is_none()
	);
	assert!(
		parse_record(
			r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-opened","session":"s","a":"x","b":"y","transport":"tcp"}"#
		)
		.is_none()
	);
	let good = r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.message-decoded","session":"s","outbound":false,"digest":"00112233445566778899aabbccddeeff","len":1,"bytes_b64":"YQ=="}"#;
	assert!(parse_record(good).is_some());
	let mismatched = good.replace("\"len\":1", "\"len\":2");
	assert!(parse_record(&mismatched).is_none());
	let noncanonical = good.replace("YQ==", "YR==");
	assert!(parse_record(&noncanonical).is_none());
	assert!(parse_record(r#"{"v":1,"sim_t_ns":1,"kind":"ocapn.session-meta","session":"s"}"#).is_none());
	assert_eq!(base64_decoded_length(""), Some(0));
	assert_eq!(base64_decoded_length("YWJj"), Some(3));
	assert!(constant_time_equals("abc", "abc"));
	assert!(!constant_time_equals("abc", "abd"));
	assert!(!constant_time_equals("abc", "ab"));
	assert!(!constant_time_equals("", "a"));
}

#[test]
fn a_subscriber_queue_is_bounded() {
	let mut queue = SubscriberQueue::default();
	for _ in 0..MAX_SUBSCRIBER_QUEUE {
		assert!(queue.admit(10));
	}
	assert!(!queue.admit(10));
	queue.drained(10);
	assert!(queue.admit(10));
	assert!(!queue.admit(MAX_LINE_BYTES + 1));
}

#[test]
fn replay_skips_a_stored_line_that_is_not_an_object_instead_of_splitting_a_character() {
	let lines = replay_lines([(1, "é{\"a\":1}"), (2, "{\"b\":2}")].into_iter(), core::iter::empty());
	assert_eq!(lines, ["{\"replay\":true,\"b\":2}"]);
}
