use rooms_application::{
	failure::{Failure, FailureCode},
	files::{FileCallError, FileError},
};

pub fn run() {
	let fixture: serde_json::Value = serde_json::from_str(include_str!("../fixtures/failures.json")).unwrap();
	for code in fixture["codes"].as_array().unwrap() {
		let wire = code.as_str().unwrap();
		assert_eq!(FailureCode::parse(wire).unwrap().wire(), wire);
	}
	for case in fixture["reasons"].as_array().unwrap() {
		let reason = case["reason"].as_str().unwrap();
		let parsed = Failure::parse(reason);
		if case["parsed"].is_null() {
			assert!(parsed.is_none(), "{reason}");
		} else {
			let failure = parsed.unwrap();
			assert_eq!(
				failure.code.wire(),
				case["parsed"]["code"].as_str().unwrap(),
				"{reason}"
			);
			assert_eq!(failure.detail, case["parsed"]["detail"].as_str().unwrap(), "{reason}");
			assert_eq!(Failure::parse(&failure.to_string()), Some(failure));
		}
	}
	for (error, code) in [
		(FileError::Expired, FailureCode::BlobExpired),
		(FileError::ReadersFull, FailureCode::AttachmentRefused),
		(FileError::Spent, FailureCode::UploadIncomplete),
		(FileError::NotPublished, FailureCode::UploadIncomplete),
		(FileError::Description, FailureCode::BadAttachment),
	] {
		assert_eq!(
			Failure::parse(&FileCallError::File(error).to_string()).unwrap().code,
			code
		);
	}
	assert!(Failure::parse(&FileCallError::Offset.to_string()).is_none());
}
