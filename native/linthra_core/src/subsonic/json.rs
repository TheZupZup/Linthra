//! A JSON reader for server answers, read the way Dart's `jsonDecode` reads
//! them, so the Subsonic client's answers didn't change when it moved here.
//!
//! Strict JSON (RFC 8259): no trailing commas, no comments, no leading zeros,
//! no `NaN`, whitespace only space, tab, CR and LF, and nothing after the
//! value. A number without a fraction or an exponent that fits an `i64` is an
//! [Value::Int], every other number a [Value::Float] (an integer too large for
//! an `i64` included, as Dart reads one). A key that appears twice keeps its
//! last value, as Dart's map does.
//!
//! One deliberate difference: a `\u` escape that leaves half a surrogate pair
//! reads as U+FFFD, since a Rust string can't hold half a pair. Dart keeps the
//! half; no server sends one in a name or an id.
//!
//! Nesting is capped at [MAX_DEPTH]: deeper input is refused instead of
//! running the stack out. A server answer is a few levels deep.

/// How deep arrays and objects may nest.
pub const MAX_DEPTH: usize = 256;

/// A parsed JSON value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<Value>),
    /// Keys in document order, repeats included; [Value::get] reads the last.
    Object(Vec<(String, Value)>),
}

impl Value {
    /// The value of `key` in an object (the last one when it repeats), or
    /// None for a missing key or a value that isn't an object.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(entries) => entries.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn is_object(&self) -> bool {
        matches!(self, Value::Object(_))
    }
}

/// `bytes` decoded as UTF-8 (a malformed sequence becomes U+FFFD, one leading
/// byte order mark is dropped, as `utf8.decode(allowMalformed: true)` does),
/// then parsed. None when it isn't a single JSON value.
pub fn parse_bytes(bytes: &[u8]) -> Option<Value> {
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    parse(&String::from_utf8_lossy(bytes))
}

/// `text` parsed as one JSON value, or None.
pub fn parse(text: &str) -> Option<Value> {
    let mut reader = Reader {
        text: text.as_bytes(),
        at: 0,
    };
    reader.skip_space();
    let value = reader.value(0)?;
    reader.skip_space();
    (reader.at == reader.text.len()).then_some(value)
}

struct Reader<'a> {
    text: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.get(self.at).copied()
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn eat(&mut self, literal: &[u8]) -> bool {
        let end = self.at + literal.len();
        if self.text.get(self.at..end) == Some(literal) {
            self.at = end;
            true
        } else {
            false
        }
    }

    fn value(&mut self, depth: usize) -> Option<Value> {
        match self.peek()? {
            b'{' => self.object(depth + 1),
            b'[' => self.array(depth + 1),
            b'"' => self.string().map(Value::String),
            b't' => self.eat(b"true").then_some(Value::Bool(true)),
            b'f' => self.eat(b"false").then_some(Value::Bool(false)),
            b'n' => self.eat(b"null").then_some(Value::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn object(&mut self, depth: usize) -> Option<Value> {
        if depth > MAX_DEPTH {
            return None;
        }
        self.at += 1;
        let mut entries = Vec::new();
        self.skip_space();
        if self.eat(b"}") {
            return Some(Value::Object(entries));
        }
        loop {
            self.skip_space();
            if self.peek()? != b'"' {
                return None;
            }
            let key = self.string()?;
            self.skip_space();
            if !self.eat(b":") {
                return None;
            }
            self.skip_space();
            let value = self.value(depth)?;
            entries.push((key, value));
            self.skip_space();
            if self.eat(b",") {
                continue;
            }
            return self.eat(b"}").then_some(Value::Object(entries));
        }
    }

    fn array(&mut self, depth: usize) -> Option<Value> {
        if depth > MAX_DEPTH {
            return None;
        }
        self.at += 1;
        let mut items = Vec::new();
        self.skip_space();
        if self.eat(b"]") {
            return Some(Value::Array(items));
        }
        loop {
            self.skip_space();
            items.push(self.value(depth)?);
            self.skip_space();
            if self.eat(b",") {
                continue;
            }
            return self.eat(b"]").then_some(Value::Array(items));
        }
    }

    fn string(&mut self) -> Option<String> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let start = self.at;
            while let Some(b) = self.peek() {
                if b == b'"' || b == b'\\' || b < 0x20 {
                    break;
                }
                self.at += 1;
            }
            // Splits only at ASCII bytes, so the run is whole UTF-8.
            out.push_str(std::str::from_utf8(self.text.get(start..self.at)?).ok()?);
            match self.peek()? {
                b'"' => {
                    self.at += 1;
                    return Some(out);
                }
                b'\\' => {
                    self.at += 1;
                    let escape = self.peek()?;
                    self.at += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return None,
                    }
                }
                // A raw control character.
                _ => return None,
            }
        }
    }

    /// The character of a `\uXXXX` escape (its `\u` already read), joining a
    /// surrogate pair written as two escapes.
    fn unicode_escape(&mut self) -> Option<char> {
        let first = self.hex4()?;
        if (0xD800..0xDC00).contains(&first) && self.text.get(self.at..self.at + 2) == Some(b"\\u")
        {
            let save = self.at;
            self.at += 2;
            let second = self.hex4()?;
            if (0xDC00..0xE000).contains(&second) {
                let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
                return char::from_u32(code);
            }
            // Not a pair: the second escape stands on its own.
            self.at = save;
        }
        Some(char::from_u32(first).unwrap_or('\u{FFFD}'))
    }

    fn hex4(&mut self) -> Option<u32> {
        let digits = self.text.get(self.at..self.at + 4)?;
        let mut code = 0;
        for &d in digits {
            code = code * 16 + (d as char).to_digit(16)?;
        }
        self.at += 4;
        Some(code)
    }

    fn number(&mut self) -> Option<Value> {
        let start = self.at;
        self.eat(b"-");
        match self.peek()? {
            b'0' => self.at += 1,
            b'1'..=b'9' => self.digits(),
            _ => return None,
        }
        let mut integral = true;
        if self.eat(b".") {
            integral = false;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return None;
            }
            self.digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            integral = false;
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return None;
            }
            self.digits();
        }
        let text = std::str::from_utf8(self.text.get(start..self.at)?).ok()?;
        if integral {
            if let Ok(n) = text.parse::<i64>() {
                return Some(Value::Int(n));
            }
        }
        text.parse::<f64>().ok().map(Value::Float)
    }

    fn digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obj(entries: &[(&str, Value)]) -> Value {
        Value::Object(
            entries
                .iter()
                .map(|(k, v)| (k.to_string(), v.clone()))
                .collect(),
        )
    }

    #[test]
    fn reads_what_jsondecode_reads() {
        assert_eq!(parse(" {\"a\":1} "), Some(obj(&[("a", Value::Int(1))])));
        assert_eq!(parse("\t{}\n"), Some(obj(&[])));
        assert_eq!(parse("true"), Some(Value::Bool(true)));
        assert_eq!(parse("\"x\""), Some(Value::String("x".into())));
        assert_eq!(
            parse("{\"a\":\"\\/\"}"),
            Some(obj(&[("a", Value::String("/".into()))]))
        );
        assert_eq!(
            parse("\"\\ud83d\\ude00\""),
            Some(Value::String("😀".into()))
        );
    }

    #[test]
    fn refuses_what_jsondecode_refuses() {
        for text in [
            "{\"a\":1,}",
            "[1,]",
            "01",
            "{\"a\":01}",
            "{\"a\":1}x",
            "{\"a\":\"\u{1}\"}",
            "{\"a\":-}",
            "{\"a\":1.}",
            "{\"a\":.5}",
            "{\"a\":1e}",
            "{\"a\":NaN}",
            "",
            " ",
            "\u{feff}{}",
            "{a:1}",
            "[1 2]",
            "\"\\x\"",
            "\"\\u12\"",
            "{\"a\" 1}",
        ] {
            assert_eq!(parse(text), None, "{text:?}");
        }
    }

    #[test]
    fn numbers_are_ints_or_floats_as_in_dart() {
        assert_eq!(parse("-0"), Some(Value::Int(0)));
        assert_eq!(parse("1.0"), Some(Value::Float(1.0)));
        assert_eq!(parse("1e2"), Some(Value::Float(100.0)));
        assert_eq!(parse("1E+2"), Some(Value::Float(100.0)));
        assert_eq!(parse("-9223372036854775808"), Some(Value::Int(i64::MIN)));
        assert_eq!(
            parse("123456789012345678901"),
            Some(Value::Float(123456789012345678901.0))
        );
        assert_eq!(parse("1e400"), Some(Value::Float(f64::INFINITY)));
    }

    #[test]
    fn the_last_of_a_repeated_key_counts() {
        let v = parse("{\"a\":1,\"a\":2}").unwrap();
        assert_eq!(v.get("a"), Some(&Value::Int(2)));
    }

    #[test]
    fn bytes_decode_as_dart_decodes_them() {
        // One byte order mark is dropped; malformed UTF-8 becomes U+FFFD.
        assert_eq!(parse_bytes(b"\xEF\xBB\xBF{}"), Some(obj(&[])));
        assert_eq!(parse_bytes(b"\xEF\xBB\xBF\xEF\xBB\xBF{}"), None);
        assert_eq!(
            parse_bytes(b"\"a\xF0\x9F\x92b\xC0\x80\""),
            Some(Value::String("a\u{FFFD}b\u{FFFD}\u{FFFD}".into()))
        );
    }

    #[test]
    fn half_a_surrogate_pair_reads_as_a_replacement() {
        assert_eq!(
            parse("\"\\ud800x\""),
            Some(Value::String("\u{FFFD}x".into()))
        );
        assert_eq!(
            parse("\"\\ud800\\u0041\""),
            Some(Value::String("\u{FFFD}A".into()))
        );
    }

    #[test]
    fn deep_nesting_is_refused_not_overflowed() {
        let deep = "[".repeat(100_000);
        assert_eq!(parse(&deep), None);
        let ok = format!("{}{}", "[".repeat(MAX_DEPTH), "]".repeat(MAX_DEPTH));
        assert!(parse(&ok).is_some());
        let over = format!("{}{}", "[".repeat(MAX_DEPTH + 1), "]".repeat(MAX_DEPTH + 1));
        assert_eq!(parse(&over), None);
    }
}
