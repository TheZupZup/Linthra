//! The few places where Rust's standard library and Dart's answer differently,
//! done Dart's way so both readers give the same tags.

/// `String.trim()` in Dart: Unicode white space, plus the byte-order mark,
/// which Rust's `trim` keeps.
pub fn trim(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_whitespace() || c == '\u{FEFF}')
}

/// Whether `c` matches `\s` in a Dart regular expression, which follows
/// JavaScript: line terminators, the BOM and the Zs spaces, but not U+0085.
pub(crate) fn is_regex_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
                | '\u{FEFF}'
    )
}

/// The number `text` starts with, as `^\s*(\d+)` and `int.tryParse` read it:
/// `3` from `3/12`, none from `A1`, none when it doesn't fit 64 bits.
pub fn leading_number(text: &str) -> Option<i64> {
    let rest = text.trim_start_matches(is_regex_space);
    let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits == 0 {
        return None;
    }
    rest[..digits].parse().ok()
}

/// `String.toUpperCase()` in Dart, which maps each character to one: `ß` stays
/// `ß` where Rust would write `SS`.
pub fn to_upper_case(text: &str) -> String {
    text.chars()
        .map(|c| {
            let mut upper = c.to_uppercase();
            match (upper.next(), upper.next()) {
                (Some(single), None) => single,
                _ => c,
            }
        })
        .collect()
}

/// `base64.decode` in Dart: the standard and URL-safe alphabets, padding
/// required, no white space. `None` where Dart throws.
pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let padding = bytes.iter().rev().take_while(|b| **b == b'=').count();
    if padding > 2 {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let mut buffer: u32 = 0;
    let mut bits = 0;
    for &byte in &bytes[..bytes.len() - padding] {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_the_bom_and_nel_but_not_the_mongolian_vowel_separator() {
        assert_eq!(trim("\u{FEFF} x \u{85}"), "x");
        assert_eq!(trim("\u{180E}x"), "\u{180E}x");
    }

    #[test]
    fn reads_a_leading_number_like_the_dart_regex() {
        assert_eq!(leading_number("3/12"), Some(3));
        assert_eq!(leading_number("\u{FEFF} 07"), Some(7));
        assert_eq!(leading_number("A1"), None);
        // U+0085 is trimmed by trim() but is not \s.
        assert_eq!(leading_number("\u{85}7"), None);
        // Arabic-Indic digits are not \d.
        assert_eq!(leading_number("\u{663}"), None);
        assert_eq!(leading_number("99999999999999999999"), None);
        assert_eq!(leading_number(""), None);
    }

    #[test]
    fn upper_cases_one_character_at_a_time() {
        assert_eq!(to_upper_case("tItLe"), "TITLE");
        assert_eq!(to_upper_case("\u{DF}title"), "\u{DF}TITLE");
        assert_eq!(to_upper_case("\u{E9}"), "\u{C9}");
    }

    #[test]
    fn decodes_base64_as_dart_does() {
        assert_eq!(base64_decode("AQID"), Some(vec![1, 2, 3]));
        assert_eq!(base64_decode("AQI="), Some(vec![1, 2]));
        assert_eq!(base64_decode("AQ=="), Some(vec![1]));
        assert_eq!(base64_decode("-_-_"), Some(vec![251, 255, 191]));
        assert_eq!(base64_decode("+/+/"), Some(vec![251, 255, 191]));
        assert_eq!(base64_decode("AQI"), None);
        assert_eq!(base64_decode("AQ"), None);
        assert_eq!(base64_decode("A Q I D"), None);
        assert_eq!(base64_decode("A==="), None);
        assert_eq!(base64_decode(""), Some(vec![]));
    }
}
