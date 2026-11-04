//! Independently authored scalar behaviors check actual generated wire calls.
use crate::pair::Pair;
use crate::scalar_generated as generated;
use glowcap::{Argument, Host, HostOptions, HostProfile};
use std::{cell::RefCell, rc::Rc};

#[derive(Default)]
struct State {
	calls: Vec<(String, usize)>,
	outcome: u8,
	float: f64,
	bounded: Vec<u8>,
}
fn expected(kind: &str, state: &State) -> Argument {
	match kind {
		"bool" => Argument::Boolean(true),
		"bytes" => Argument::Bytes(vec![]),
		"bounded" => Argument::Bytes(state.bounded.clone()),
		"symbol" => Argument::Symbol("scalar-λ".into()),
		"float" => Argument::Float(state.float),
		"error" => Argument::Error("fulfilled error data".into()),
		_ => panic!("unknown scalar"),
	}
}
fn equal(actual: &Argument, expected: &Argument) {
	match (actual, expected) {
		(Argument::Float(actual), Argument::Float(expected)) => assert_eq!(actual.to_bits(), expected.to_bits()),
		_ => assert_eq!(actual, expected),
	}
}
pub async fn run() {
	for profile in [HostProfile::Interop, HostProfile::Glowcap] {
		let options = HostOptions::with_profile(profile);
		let host = Host::with_options(options).unwrap();
		let state = Rc::new(RefCell::new(State {
			float: -0.0,
			bounded: vec![0, 255],
			..Default::default()
		}));
		let observed = state.clone();
		let owner = host.clone();
		host.publish("scalars", move || {
			let observed = observed.clone();
			let owner = owner.clone();
			Box::new(move |verb, args| {
				let verb = verb.unwrap();
				let (kind, shape) = verb.split_once('_').unwrap();
				let optional = shape.contains("optional");
				assert!(args.len() <= 1 && (optional || args.len() == 1));
				let value = expected(kind, &observed.borrow());
				if let Some(argument) = args.first() {
					equal(argument, &value);
				}
				if shape.contains("tell") {
					assert!(owner.defer_turn_if_answer().unwrap().is_none());
				}
				let mut state = observed.borrow_mut();
				state.calls.push((verb.into(), args.len()));
				match state.outcome {
					1 if kind == "float" => Ok(Argument::Integer(1)),
					1 => Ok(Argument::String("wrong scalar category".into())),
					2 => Err("unlisted scalar break".into()),
					_ => Ok(value),
				}
			})
		})
		.unwrap();
		let pair = Pair::open(&host, options).await;
		let client = &pair.client;
		let target = client.fetch("scalars").await.unwrap();
		macro_rules! exercise {
			($required:expr, $optional:path, $tell:path, $optional_tell:path, $make:expr, $check:expr) => {{
				let check = $check;
				check(($required)(($make)()).await.unwrap());
				check($optional(client, &target, None).unwrap().await.unwrap());
				assert_eq!(state.borrow().calls.last().unwrap().1, 0);
				check(
					$optional(client, &target, Some(($make)()))
						.unwrap()
						.await
						.unwrap(),
				);
				assert_eq!(state.borrow().calls.last().unwrap().1, 1);
				$tell(client, &target, ($make)()).unwrap();
				$optional_tell(client, &target, None).unwrap();
				$optional_tell(client, &target, Some(($make)())).unwrap();
				generated::bool_call(client, &target, true).await.unwrap();
				{
					let state = state.borrow();
					let calls = &state.calls;
					assert_eq!(calls[calls.len() - 3].1, 0);
					assert_eq!(calls[calls.len() - 2].1, 1);
				}
				state.borrow_mut().outcome = 1;
				assert!(matches!(
					($required)(($make)()).await,
					Err(generated::Error::InvalidReply)
				));
				state.borrow_mut().outcome = 2;
				match ($required)(($make)()).await {
					Err(generated::Error::Runtime(error)) => assert_eq!(error.message(), Some("unlisted scalar break")),
					_ => panic!("scalar call changed break"),
				}
				state.borrow_mut().outcome = 0;
			}};
		}
		exercise!(
			|v| generated::bool_call(client, &target, v),
			generated::bool_optional,
			generated::bool_tell,
			generated::bool_optional_tell,
			|| true,
			|v: bool| assert!(v)
		);
		exercise!(
			|v| generated::bytes_call(client, &target, v),
			generated::bytes_optional,
			generated::bytes_tell,
			generated::bytes_optional_tell,
			Vec::<u8>::new,
			|v: Vec<u8>| assert!(v.is_empty())
		);
		exercise!(
			|v| generated::bounded_call(client, &target, v).unwrap(),
			generated::bounded_optional,
			generated::bounded_tell,
			generated::bounded_optional_tell,
			|| vec![0, 255],
			|v: Vec<u8>| assert_eq!(v, [0, 255])
		);
		exercise!(
			|v| generated::symbol_call(client, &target, v),
			generated::symbol_optional,
			generated::symbol_tell,
			generated::symbol_optional_tell,
			|| "scalar-λ".to_owned(),
			|v: String| assert_eq!(v, "scalar-λ")
		);
		exercise!(
			|v| generated::float_call(client, &target, v),
			generated::float_optional,
			generated::float_tell,
			generated::float_optional_tell,
			|| -0.0,
			|v: f64| assert_eq!(v.to_bits(), (-0.0f64).to_bits())
		);
		exercise!(
			|v| generated::error_call(client, &target, v),
			generated::error_optional,
			generated::error_tell,
			generated::error_optional_tell,
			|| "fulfilled error data".to_owned(),
			|v: String| assert_eq!(v, "fulfilled error data")
		);
		for value in [
			0.0,
			f64::from_bits(1),
			f64::MAX,
			f64::INFINITY,
			f64::NEG_INFINITY,
			f64::NAN,
		] {
			state.borrow_mut().float = value;
			let actual = generated::float_call(client, &target, value).await.unwrap();
			assert_eq!(actual.to_bits(), value.to_bits());
		}
		for bytes in [vec![1], vec![0, 1, 2, 255]] {
			state.borrow_mut().bounded = bytes.clone();
			assert_eq!(
				generated::bounded_call(client, &target, bytes.clone())
					.unwrap()
					.await
					.unwrap(),
				bytes
			);
		}
		let before = state.borrow().calls.len();
		for bytes in [vec![], vec![0; 5]] {
			assert!(matches!(
				generated::bounded_call(client, &target, bytes.clone()),
				Err(generated::Error::InvalidArgument)
			));
			assert!(matches!(
				generated::bounded_optional(client, &target, Some(bytes.clone())),
				Err(generated::Error::InvalidArgument)
			));
			assert!(matches!(
				generated::bounded_tell(client, &target, bytes.clone()),
				Err(generated::Error::InvalidArgument)
			));
			assert!(matches!(
				generated::bounded_optional_tell(client, &target, Some(bytes)),
				Err(generated::Error::InvalidArgument)
			));
		}
		generated::bool_call(client, &target, true).await.unwrap();
		assert_eq!(state.borrow().calls.len(), before + 1, "invalid byte argument sent");
		// Wrong byte lengths are also refused on fulfillment, not just input.
		for bytes in [vec![], vec![0; 5]] {
			state.borrow_mut().bounded = bytes;
			assert!(matches!(
				generated::bounded_optional(client, &target, None).unwrap().await,
				Err(generated::Error::InvalidReply)
			));
		}
		pair.close().await;
	}
}
