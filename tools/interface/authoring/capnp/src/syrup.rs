//! Canonical encoding only. The shared description reader/model validates output.
#[derive(Clone)]
pub enum Value {
	Symbol(String),
	Text(String),
	Integer(i64),
	Boolean(bool),
	List(Vec<Value>),
	Dictionary(Vec<(Value, Value)>),
	Record(&'static str, Vec<Value>),
}
impl Value {
	pub fn symbol(name: &str) -> Self {
		Self::Symbol(name.into())
	}
	pub fn record(name: &'static str, fields: Vec<Self>) -> Self {
		Self::Record(name, fields)
	}
	pub fn encode(&self) -> Vec<u8> {
		let mut out = Vec::new();
		self.write(&mut out);
		out
	}
	fn write(&self, out: &mut Vec<u8>) {
		match self {
			Self::Symbol(text) | Self::Text(text) => {
				out.extend(text.len().to_string().bytes());
				out.push(if matches!(self, Self::Symbol(_)) { b'\'' } else { b'"' });
				out.extend(text.bytes());
			}
			Self::Integer(value) => {
				out.extend(value.unsigned_abs().to_string().bytes());
				out.push(if *value < 0 { b'-' } else { b'+' });
			}
			Self::Boolean(value) => out.push(if *value { b't' } else { b'f' }),
			Self::List(items) => {
				out.push(b'[');
				for item in items {
					item.write(out);
				}
				out.push(b']');
			}
			Self::Dictionary(items) => {
				let mut entries: Vec<_> = items.iter().map(|(key, value)| (key.encode(), value)).collect();
				entries.sort_by(|a, b| a.0.cmp(&b.0));
				out.push(b'{');
				for (key, value) in entries {
					out.extend(key);
					value.write(out);
				}
				out.push(b'}');
			}
			Self::Record(name, fields) => {
				out.push(b'<');
				Self::symbol(name).write(out);
				for field in fields {
					field.write(out);
				}
				out.push(b'>');
			}
		}
	}
}
