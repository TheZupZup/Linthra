//! Replays test/fixtures/cache_eviction_cases.json, the cases the Dart policy
//! (test/core/services/cache_eviction_cases_test.dart) replays too. Expected
//! evictions are indices into each case's `cached` list, in eviction order.

use std::collections::{BTreeMap, HashSet};

use crate::cache_eviction::{plan, CacheKey, CachedEntry, EvictionPlan, EvictionRequest};

const CASES: &str = include_str!("../../../test/fixtures/cache_eviction_cases.json");

/// Just enough JSON for the fixture: objects, arrays, strings (with `\"`,
/// `\\` and `\uXXXX` escapes), integers, booleans and null. The crate has no
/// dependencies, and a test is no reason to add one.
#[derive(Debug)]
enum Json {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

struct Parser<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Parser<'_> {
    fn skip_space(&mut self) {
        while self.bytes.get(self.at).is_some_and(u8::is_ascii_whitespace) {
            self.at += 1;
        }
    }

    fn expect(&mut self, byte: u8) {
        self.skip_space();
        assert_eq!(self.bytes[self.at], byte, "at byte {}", self.at);
        self.at += 1;
    }

    fn literal(&mut self, word: &str, value: Json) -> Json {
        assert!(self.bytes[self.at..].starts_with(word.as_bytes()));
        self.at += word.len();
        value
    }

    fn value(&mut self) -> Json {
        self.skip_space();
        match self.bytes[self.at] {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => Json::Str(self.string()),
            b't' => self.literal("true", Json::Bool(true)),
            b'f' => self.literal("false", Json::Bool(false)),
            b'n' => self.literal("null", Json::Null),
            _ => self.int(),
        }
    }

    fn int(&mut self) -> Json {
        let start = self.at;
        while self
            .bytes
            .get(self.at)
            .is_some_and(|b| b.is_ascii_digit() || *b == b'-')
        {
            self.at += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.at]).unwrap();
        Json::Int(text.parse().expect("an integer"))
    }

    fn string(&mut self) -> String {
        self.expect(b'"');
        let mut out = Vec::new();
        // \u escapes are UTF-16 code units: a character outside the BMP comes
        // as a surrogate pair, so they are gathered and decoded together.
        let mut units: Vec<u16> = Vec::new();
        loop {
            let byte = self.bytes[self.at];
            if byte == b'\\' && self.bytes[self.at + 1] == b'u' {
                let hex = std::str::from_utf8(&self.bytes[self.at + 2..self.at + 6]).unwrap();
                units.push(u16::from_str_radix(hex, 16).expect("hex"));
                self.at += 6;
                continue;
            }
            if !units.is_empty() {
                out.extend(String::from_utf16(&units).expect("UTF-16").bytes());
                units.clear();
            }
            match byte {
                b'"' => break,
                b'\\' => {
                    self.at += 1;
                    let escaped = self.bytes[self.at];
                    assert!(escaped == b'"' || escaped == b'\\', "unsupported escape");
                    out.push(escaped);
                }
                byte => out.push(byte),
            }
            self.at += 1;
        }
        self.at += 1;
        String::from_utf8(out).expect("UTF-8")
    }

    fn array(&mut self) -> Json {
        self.expect(b'[');
        let mut items = Vec::new();
        self.skip_space();
        if self.bytes[self.at] == b']' {
            self.at += 1;
            return Json::Array(items);
        }
        loop {
            items.push(self.value());
            self.skip_space();
            self.at += 1;
            if self.bytes[self.at - 1] == b']' {
                return Json::Array(items);
            }
        }
    }

    fn object(&mut self) -> Json {
        self.expect(b'{');
        let mut fields = BTreeMap::new();
        self.skip_space();
        if self.bytes[self.at] == b'}' {
            self.at += 1;
            return Json::Object(fields);
        }
        loop {
            self.skip_space();
            let key = self.string();
            self.expect(b':');
            fields.insert(key, self.value());
            self.skip_space();
            self.at += 1;
            if self.bytes[self.at - 1] == b'}' {
                return Json::Object(fields);
            }
        }
    }
}

impl Json {
    fn get(&self, key: &str) -> &Json {
        match self {
            Json::Object(fields) => fields.get(key).unwrap_or_else(|| panic!("no {key}")),
            _ => panic!("not an object"),
        }
    }

    fn items(&self) -> &[Json] {
        match self {
            Json::Array(items) => items,
            _ => panic!("not an array"),
        }
    }

    fn int(&self) -> i64 {
        match self {
            Json::Int(value) => *value,
            _ => panic!("not an integer"),
        }
    }

    fn optional_int(&self) -> Option<i64> {
        match self {
            Json::Null => None,
            _ => Some(self.int()),
        }
    }

    fn bool(&self) -> bool {
        match self {
            Json::Bool(value) => *value,
            _ => panic!("not a boolean"),
        }
    }

    fn optional_str(&self) -> Option<&str> {
        match self {
            Json::Null => None,
            Json::Str(value) => Some(value),
            _ => panic!("not a string"),
        }
    }

    fn key(&self) -> Option<CacheKey> {
        match self {
            Json::Null => None,
            _ => Some(CacheKey::new(
                self.get("source").optional_str(),
                self.get("id").optional_str().expect("an id"),
            )),
        }
    }
}

fn entry(json: &Json) -> CachedEntry {
    CachedEntry {
        key: json.key().unwrap(),
        managed: json.get("managed").bool(),
        size_bytes: json.get("size").int(),
        last_accessed: json.get("accessed").optional_int(),
        cached_at: json.get("cachedAt").optional_int(),
        pinned: json.get("pinned").bool(),
        preloaded: json.get("preloaded").bool(),
    }
}

#[test]
fn plans_match_the_shared_cases() {
    let doc = Parser {
        bytes: CASES.as_bytes(),
        at: 0,
    }
    .value();
    assert_eq!(doc.get("version").int(), 1);

    let cases = doc.get("cases").items();
    assert!(!cases.is_empty());
    let mut names = HashSet::new();
    for case in cases {
        let name = case.get("name").optional_str().unwrap();
        assert!(names.insert(name), "duplicate case name {name:?}");

        let cached: Vec<CachedEntry> = case.get("cached").items().iter().map(entry).collect();
        let mut protected: HashSet<CacheKey> = case
            .get("protectKeys")
            .items()
            .iter()
            .filter_map(Json::key)
            .collect();
        protected.extend(case.get("protectKey").key());
        let request = EvictionRequest {
            incoming_bytes: case.get("incomingBytes").int(),
            max_bytes: case.get("maxBytes").int(),
            protected,
            only_preloaded: case.get("onlyPreloaded").bool(),
            incoming: case.get("incomingKey").key(),
        };

        let expected = case.get("expect");
        let want = EvictionPlan {
            evict: expected
                .get("evict")
                .items()
                .iter()
                .map(|index| index.int() as usize)
                .collect(),
            fits: expected.get("fits").bool(),
        };
        assert_eq!(plan(&cached, &request), want, "case {name:?}");
    }
}
