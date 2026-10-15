//! Startup policy shared by every embedding. Overrides are parsed once.
//! Running registries keep fixed rates so changing policy cannot mint credit.
use super::{CLASSES, Class, Profile, Rate};
use alloc::{
	format,
	string::{String, ToString},
};

/// Default accounting rows each embedding retains.
pub const DIRECTORY_ROWS: usize = 8192;
pub const SESSION_ROWS: usize = 4096;
pub const HTTP_ROWS: usize = 2048;
/// The managed session and HTTP pools scale one subject's profile by this.
pub const POOLED_AGGREGATE_SCALE: u32 = 8;
/// The most rows `admission-rows` accepts.
pub const MAX_ROWS: usize = 65_536;
/// The most `admission-scale` and `admission-aggregate-scale` accept.
pub const MAX_SCALE: u32 = 100;

/// Why an admission setting is refused. `Display` is the exact line the
/// operator reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Invalid {
	/// The embedding's default row count is out of range.
	DefaultRows,
	/// The embedding's default aggregate scale is out of range.
	DefaultAggregateScale,
	/// An integer option is missing, not a number, or out of range.
	IntegerRange { key: &'static str, maximum: u32 },
	/// The admission scale overflows a rate.
	ScaleOverflow { scale: u32 },
	/// A rate item has no `class=` part.
	RateClass { item: String },
	/// A rate names a class that does not exist.
	UnknownClass { name: String },
	/// A rate names one class twice.
	RepeatedClass { name: String },
	/// A rate item has no `burst/per-minute` pair.
	RatePair { item: String },
	/// A rate item holds a zero or non-numeric value.
	RateValues { item: String },
	/// A rate's burst takes more than a minute to refill.
	RateRefill { item: String },
	/// The aggregate rates overflow.
	AggregateOverflow,
}

impl core::fmt::Display for Invalid {
	fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
		match self {
			Self::DefaultRows => write!(f, "default admission rows must be from 1 through {MAX_ROWS}"),
			Self::DefaultAggregateScale => {
				write!(
					f,
					"default aggregate admission scale must be from 1 through {MAX_SCALE}"
				)
			}
			Self::IntegerRange { key, maximum } => {
				write!(f, "--{key} must be an integer from 1 through {maximum}")
			}
			Self::ScaleOverflow { scale } => write!(f, "--admission-scale {scale} overflows an admission rate"),
			Self::RateClass { item } => write!(f, "admission rate {item:?} needs class=burst/per-minute"),
			Self::UnknownClass { name } => write!(f, "unknown admission class {name:?}"),
			Self::RepeatedClass { name } => write!(f, "repeated admission class {name:?}"),
			Self::RatePair { item } => write!(f, "admission rate {item:?} needs burst/per-minute"),
			Self::RateValues { item } => write!(f, "admission rate {item:?} needs positive u32 values"),
			Self::RateRefill { item } => {
				write!(f, "admission rate {item:?} must refill its burst within one minute")
			}
			Self::AggregateOverflow => f.write_str("aggregate admission rates overflow u32"),
		}
	}
}

impl core::error::Error for Invalid {}

impl From<Invalid> for String {
	fn from(invalid: Invalid) -> Self {
		invalid.to_string()
	}
}

#[derive(Clone, Copy, Debug)]
pub enum Source {
	Default,
	Argument,
	Environment,
	Embedding,
}
impl Source {
	fn name(self) -> &'static str {
		match self {
			Self::Default => "default",
			Self::Argument => "argument",
			Self::Environment => "environment",
			Self::Embedding => "embedding",
		}
	}
}
#[derive(Clone, Copy, Debug)]
pub struct Settings {
	profile: Profile,
	/// `profile` scaled by `aggregate_scale`, validated when the settings were parsed.
	aggregate: Profile,
	rows: usize,
	aggregate_scale: u32,
	sources: [Source; 4],
}
impl Settings {
	pub const OPTIONS: &'static [&'static str] = &[
		"admission-scale",
		"admission-rates",
		"admission-rows",
		"admission-aggregate-scale",
	];
	pub fn defaults(rows: usize, aggregate_scale: u32) -> Self {
		assert!((1..=MAX_ROWS).contains(&rows));
		assert!((1..=MAX_SCALE).contains(&aggregate_scale));
		#[expect(
			clippy::expect_used,
			reason = "the default profile scaled by at most 100, which the assert above bounds, fits every u32 rate"
		)]
		let aggregate = Profile::default()
			.multiplied(aggregate_scale)
			.expect("the default profile scales within u32");
		Self {
			profile: Profile::default(),
			aggregate,
			rows,
			aggregate_scale,
			sources: [Source::Default; 4],
		}
	}
	/// Scale defaults first. Explicit class rates are absolute burst/per-minute
	/// pairs. Reject duplicate, unknown, zero and overflowing settings. A burst
	/// must refill within one minute, the retry metadata's public upper bound.
	pub fn parse(value: impl Fn(&str) -> Option<String>, rows: usize, aggregate_scale: u32) -> Result<Self, Invalid> {
		Self::parse_from(|key| value(key).map(|v| (v, Source::Embedding)), rows, aggregate_scale)
	}
	pub fn parse_from(
		value: impl Fn(&str) -> Option<(String, Source)>,
		rows: usize,
		aggregate_scale: u32,
	) -> Result<Self, Invalid> {
		if !(1..=MAX_ROWS).contains(&rows) {
			return Err(Invalid::DefaultRows);
		}
		if !(1..=MAX_SCALE).contains(&aggregate_scale) {
			return Err(Invalid::DefaultAggregateScale);
		}
		let values: [Option<(String, Source)>; 4] = core::array::from_fn(|i| value(Self::OPTIONS[i]));
		let sources = values
			.each_ref()
			.map(|v| v.as_ref().map_or(Source::Default, |(_, source)| *source));
		let value = |key: &str| {
			Self::OPTIONS
				.iter()
				.position(|k| *k == key)
				.and_then(|i| values[i].as_ref().map(|(v, _)| v.clone()))
		};
		let integer = |key, default, maximum| -> Result<u32, Invalid> {
			match value(key) {
				None => Ok(default),
				Some(raw) => raw
					.parse::<u32>()
					.ok()
					.filter(|n| (1..=maximum).contains(n))
					.ok_or(Invalid::IntegerRange { key, maximum }),
			}
		};
		let scale = integer("admission-scale", 1, MAX_SCALE)?;
		let rows = integer("admission-rows", rows as u32, MAX_ROWS as u32)? as usize;
		let aggregate_scale = integer("admission-aggregate-scale", aggregate_scale, MAX_SCALE)?;
		let mut profile = Profile::scaled(scale).ok_or(Invalid::ScaleOverflow { scale })?;
		if let Some(raw) = value("admission-rates") {
			let mut seen = [false; super::CLASS_COUNT];
			for item in raw.split(',') {
				let (name, pair) = item
					.split_once('=')
					.ok_or_else(|| Invalid::RateClass { item: item.into() })?;
				let class = Class::parse(name).ok_or_else(|| Invalid::UnknownClass { name: name.into() })?;
				if core::mem::replace(&mut seen[class as usize], true) {
					return Err(Invalid::RepeatedClass { name: name.into() });
				}
				let (burst, sustained) = pair
					.split_once('/')
					.ok_or_else(|| Invalid::RatePair { item: item.into() })?;
				let parse = |number: &str| number.parse::<u32>().ok().filter(|&n| n != 0);
				let (Some(burst), Some(sustained)) = (parse(burst), parse(sustained)) else {
					return Err(Invalid::RateValues { item: item.into() });
				};
				if burst > sustained {
					return Err(Invalid::RateRefill { item: item.into() });
				}
				profile = profile.with_rate(class, Rate::new(burst, sustained));
			}
		}
		let aggregate = profile.multiplied(aggregate_scale).ok_or(Invalid::AggregateOverflow)?;
		Ok(Self {
			profile,
			aggregate,
			rows,
			aggregate_scale,
			sources,
		})
	}
	pub const fn profile(self) -> Profile {
		self.profile
	}
	pub const fn rows(self) -> usize {
		self.rows
	}
	pub const fn aggregate_scale(self) -> u32 {
		self.aggregate_scale
	}
	pub fn aggregate(self) -> Profile {
		self.aggregate
	}
	/// Bounded diagnostic without subject labels or capability links.
	pub fn summary(self) -> String {
		let mut result = format!(
			"process-local; rows={}; aggregate-scale={}; rates=",
			self.rows, self.aggregate_scale
		);
		for (index, class) in CLASSES.into_iter().enumerate() {
			if index != 0 {
				result.push(',');
			}
			let rate = self.profile.rate(class);
			result.push_str(&format!("{}={}/{}", class.name(), rate.burst(), rate.per_minute()));
		}
		result.push_str("; sources=");
		for (index, (option, source)) in Self::OPTIONS.iter().zip(self.sources).enumerate() {
			if index != 0 {
				result.push(',');
			}
			result.push_str(option);
			result.push('=');
			result.push_str(source.name());
		}
		result
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn every_invalid_line_is_the_line_it_replaced() {
		let lines = [
			(
				Invalid::DefaultRows,
				"default admission rows must be from 1 through 65536",
			),
			(
				Invalid::DefaultAggregateScale,
				"default aggregate admission scale must be from 1 through 100",
			),
			(
				Invalid::IntegerRange {
					key: "admission-scale",
					maximum: 100,
				},
				"--admission-scale must be an integer from 1 through 100",
			),
			(
				Invalid::ScaleOverflow { scale: 7 },
				"--admission-scale 7 overflows an admission rate",
			),
			(
				Invalid::RateClass { item: "x".into() },
				"admission rate \"x\" needs class=burst/per-minute",
			),
			(
				Invalid::UnknownClass { name: "x".into() },
				"unknown admission class \"x\"",
			),
			(
				Invalid::RepeatedClass { name: "x".into() },
				"repeated admission class \"x\"",
			),
			(
				Invalid::RatePair { item: "x".into() },
				"admission rate \"x\" needs burst/per-minute",
			),
			(
				Invalid::RateValues { item: "x".into() },
				"admission rate \"x\" needs positive u32 values",
			),
			(
				Invalid::RateRefill { item: "x".into() },
				"admission rate \"x\" must refill its burst within one minute",
			),
			(Invalid::AggregateOverflow, "aggregate admission rates overflow u32"),
		];
		for (invalid, line) in lines {
			assert_eq!(invalid.to_string(), line);
		}
	}
	#[test]
	fn overrides_are_absolute_and_aggregate_is_validated() {
		let settings = Settings::parse(
			|key| match key {
				"admission-scale" => Some("2".into()),
				"admission-rates" => Some("message=20/80,room-join=5/10".into()),
				"admission-rows" => Some("123".into()),
				_ => None,
			},
			8192,
			8,
		)
		.unwrap();
		assert_eq!(settings.profile().rate(Class::Connection).burst(), 12);
		assert_eq!(settings.profile().rate(Class::Message).burst(), 20);
		assert_eq!(settings.aggregate().rate(Class::Message).burst(), 160);
		assert_eq!(settings.rows(), 123);
	}
	#[test]
	fn invalid_library_defaults_cannot_create_unbounded_settings() {
		for rows in [0, 65_537, usize::MAX] {
			assert!(Settings::parse(|_| None, rows, 8).is_err(), "rows={rows}");
		}
		for scale in [0, 101] {
			assert!(
				Settings::parse(|_| None, 4096, scale).is_err(),
				"aggregate-scale={scale}"
			);
		}
	}
	#[test]
	fn malformed_or_unbounded_policy_refuses_startup() {
		for raw in [
			"message=0/10",
			"message=12/1",
			"unknown=1/1",
			"message=1/1,message=2/2",
			"message=4294967295/4294967295",
			"message=1/1,",
		] {
			assert!(
				Settings::parse(|key| (key == "admission-rates").then(|| raw.into()), 8192, 8).is_err(),
				"{raw}"
			);
		}
		for raw in ["0", "65537", "-1", "garbage"] {
			assert!(Settings::parse(|key| (key == "admission-rows").then(|| raw.into()), 8192, 8).is_err());
		}
	}
}
