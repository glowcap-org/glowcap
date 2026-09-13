//! Room history under its bounds, and the file transfer state a conversation
//! carries, replayed from `fixtures/conversation.json`.
use rooms_application::{
	files::{
		CHUNK_BYTES, MAX_FILE_BYTES,
		transfer::{self, Error, UploadProgress},
	},
	room::history::{Error as HistoryError, History, MAX_BYTES, MAX_LINES},
};
use serde_json::Value;
pub fn run() {
	let fixture: Value = serde_json::from_str(include_str!("../fixtures/conversation.json")).unwrap();
	for case in fixture["history"].as_array().unwrap() {
		let mut history = History::default();
		if let Some(rows) = case["input"].as_array() {
			for row in rows {
				if let Some(fields) = row.as_array() {
					let at = fields.get(2).and_then(|value| {
						value
							.as_f64()
							.or_else(|| value.get("integer")?.as_str()?.parse::<f64>().ok())
					});
					history
						.push(
							fields.first().and_then(Value::as_str),
							fields.get(1).and_then(Value::as_str),
							at,
						)
						.unwrap();
				}
			}
		}
		let lines = history.into_lines();
		let expected = case["result"].as_array().unwrap();
		assert_eq!(lines.len(), expected.len());
		for (line, expected) in lines.iter().zip(expected) {
			assert_eq!(line.from, expected["from"].as_str().unwrap());
			assert_eq!(line.text, expected["text"].as_str().unwrap());
			assert_eq!(line.at, expected["at"].as_f64().unwrap());
		}
	}
	let mut history = History::default();
	for _ in 0..MAX_LINES {
		history.push(Some("alice"), Some("line"), Some(1.0)).unwrap();
	}
	assert_eq!(history.push(Some("bob"), None, None), Err(HistoryError::TooManyLines));
	assert_eq!(history.into_lines().len(), MAX_LINES);
	let mut history = History::default();
	assert_eq!(
		history.push(Some("alice"), Some(&"x".repeat(MAX_BYTES)), None),
		Err(HistoryError::TooManyBytes)
	);
	assert!(history.into_lines().is_empty());
	let mut upload = UploadProgress::new(CHUNK_BYTES + 1).unwrap();
	assert_eq!(upload.begin(CHUNK_BYTES + 1), Err(Error::Chunk));
	upload.begin(CHUNK_BYTES).unwrap();
	assert_eq!(upload.written(), 0);
	assert_eq!(upload.begin(1), Err(Error::UnobservedWrite));
	upload.acknowledge().unwrap();
	assert_eq!(upload.written(), CHUNK_BYTES);
	upload.begin(1).unwrap();
	upload.acknowledge().unwrap();
	assert!(upload.complete());
	assert_eq!(upload.begin(1), Err(Error::Complete));
	assert!(UploadProgress::new(0).unwrap().complete());
	assert!(matches!(UploadProgress::new(MAX_FILE_BYTES + 1), Err(Error::Size)));
	assert_eq!(transfer::read_length(7, 0, usize::MAX), Ok(7));
	assert_eq!(transfer::read_length(MAX_FILE_BYTES, 1, usize::MAX), Ok(CHUNK_BYTES));
	assert_eq!(transfer::read_length(7, u64::MAX, 1), Ok(0));
	assert_eq!(transfer::read_length(7, 0, 0), Err(Error::ReadLength));
	for received in [None, Some(0), Some(8)] {
		assert_eq!(transfer::accept_chunk(7, received), Err(Error::ReadReply));
	}
	assert_eq!(transfer::accept_chunk(7, Some(3)), Ok(()));
}
