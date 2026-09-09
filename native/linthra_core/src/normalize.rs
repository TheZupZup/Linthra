//! Turning raw metadata and raw queries into the tokens the index stores.
//!
//! One module, used by both sides, because the index and the query have to
//! agree exactly: a fold applied when building and not when searching is worse
//! than no fold at all.
//!
//! Two jobs beyond splitting and lower-casing:
//!
//! * **Accent folding.** `Björk` and `bjork` must find each other (#336).
//!   A byte-prefix search already happened to work when the accent came last
//!   (`beyonce` → `beyoncé`), which made the gap easy to miss — but an accent in
//!   the middle of a word had no chance.
//! * **Combining marks.** The same text can arrive precomposed (`ö`, one char)
//!   or decomposed (`o` + U+0308, two chars). Splitting on "not alphanumeric"
//!   treated the mark as a separator, so `Mötley` written the second way became
//!   the two tokens `mo` and `tley` — the word was not merely unaccented, it was
//!   shredded. Marks now stay attached and fold away with the letter.
//!
//! ## What the fold covers, and what it does not
//!
//! The table below is Latin-1 Supplement and Latin Extended-A, plus the
//! Combining Diacritical Marks block (U+0300–U+036F). That is the range Western,
//! Central and Northern European music metadata actually lives in, and it is
//! small enough to read in one screen.
//!
//! It deliberately stops there. Greek, Cyrillic, Hebrew, Arabic, CJK and Hangul
//! are indexed and searched unchanged: they are not scripts where a listener
//! types the "unaccented" spelling of a name, so folding them would be
//! inventing a behaviour nobody asked for. Vietnamese, which stacks marks
//! beyond Latin Extended-A, folds only as far as its precomposed characters
//! reach — the decomposed form folds fully through the combining-mark rule.
//!
//! This is why the crate still has no dependencies. A full Unicode
//! normalization crate would buy correctness for scripts the fold intentionally
//! leaves alone, at the cost of the one property that makes this core easy to
//! vendor and audit.

/// Unicode's Combining Diacritical Marks block.
///
/// Kept as a named range rather than a general "is this a mark?" test, which
/// would need Unicode tables. Everything NFD produces for the Latin script
/// lands in here.
fn is_combining_mark(character: char) -> bool {
    matches!(character, '\u{0300}'..='\u{036F}')
}

/// Whether [character] belongs inside a token rather than between two of them.
fn is_token_character(character: char) -> bool {
    character.is_alphanumeric() || is_combining_mark(character)
}

/// The accent-free spelling of an already-lower-case [character], or `None`
/// when it has none and should be kept as it is.
///
/// A few characters fold to more than one letter, because that is how their
/// languages spell them without the ligature or the sharp s: `ß` → `ss`,
/// `æ` → `ae`, `œ` → `oe`.
fn fold_lowercase(character: char) -> Option<&'static str> {
    Some(match character {
        _ if is_combining_mark(character) => "",
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => "a",
        'æ' => "ae",
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => "c",
        'ð' | 'ď' | 'đ' => "d",
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => "e",
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => "g",
        'ĥ' | 'ħ' => "h",
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ı' => "i",
        'ĳ' => "ij",
        'ĵ' => "j",
        'ķ' | 'ĸ' => "k",
        'ĺ' | 'ļ' | 'ľ' | 'ŀ' | 'ł' => "l",
        'ñ' | 'ń' | 'ņ' | 'ň' | 'ŉ' | 'ŋ' => "n",
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ŏ' | 'ő' => "o",
        'œ' => "oe",
        'ŕ' | 'ŗ' | 'ř' => "r",
        'ś' | 'ŝ' | 'ş' | 'š' | 'ſ' => "s",
        'ß' => "ss",
        'ţ' | 'ť' | 'ŧ' => "t",
        'þ' => "th",
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' => "u",
        'ŵ' => "w",
        'ý' | 'ÿ' | 'ŷ' => "y",
        'ź' | 'ż' | 'ž' => "z",
        _ => return None,
    })
}

/// Folds one already-split word to its indexable form.
///
/// Lower-casing runs over the whole word rather than character by character, so
/// the cases where one letter lower-cases to several (Turkish `İ`, `ẞ`) come
/// out right before anything is folded.
fn fold_token(word: &str) -> String {
    // The overwhelmingly common case in a real catalog, and the one the 200k
    // benchmark measures: an ASCII word has nothing to fold and needs only a
    // byte-wise case map, not the full Unicode one.
    if word.is_ascii() {
        return word.to_ascii_lowercase();
    }
    let lowered = word.to_lowercase();
    let mut folded = String::with_capacity(lowered.len());
    for character in lowered.chars() {
        match fold_lowercase(character) {
            Some(replacement) => folded.push_str(replacement),
            None => folded.push(character),
        }
    }
    folded
}

/// Splits [value] into the lower-case, accent-folded tokens the index is keyed
/// by. The same function normalizes a query, so both sides always agree.
///
/// A word made only of combining marks folds to nothing and is dropped, which
/// is why the empty filter runs after the fold as well as before it.
pub(crate) fn normalized_tokens(value: &str) -> Vec<String> {
    value
        .split(|character: char| !is_token_character(character))
        .filter(|word| !word.is_empty())
        .map(fold_token)
        .filter(|token| !token.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::normalized_tokens;

    fn tokens(value: &str) -> Vec<String> {
        normalized_tokens(value)
    }

    #[test]
    fn splits_on_punctuation_and_whitespace() {
        assert_eq!(tokens("Master of Puppets"), ["master", "of", "puppets"]);
        assert_eq!(tokens("rock-n-roll!"), ["rock", "n", "roll"]);
        assert_eq!(tokens("  spaced   out  "), ["spaced", "out"]);
    }

    #[test]
    fn a_query_with_nothing_in_it_produces_no_tokens() {
        assert!(tokens("").is_empty());
        assert!(tokens("   ").is_empty());
        assert!(tokens("!!! --- ???").is_empty());
        assert!(tokens("\u{0301}\u{0308}").is_empty());
    }

    #[test]
    fn accents_fold_to_the_plain_letter() {
        assert_eq!(tokens("Beyoncé"), ["beyonce"]);
        assert_eq!(tokens("Björk"), ["bjork"]);
        assert_eq!(tokens("Motörhead"), ["motorhead"]);
        assert_eq!(tokens("Sigur Rós"), ["sigur", "ros"]);
        assert_eq!(tokens("Mylène Farmer"), ["mylene", "farmer"]);
        assert_eq!(tokens("Antonín Dvořák"), ["antonin", "dvorak"]);
    }

    #[test]
    fn ligatures_and_the_sharp_s_fold_to_how_they_are_spelled_out() {
        assert_eq!(tokens("Straße"), ["strasse"]);
        assert_eq!(tokens("Encyclopædia"), ["encyclopaedia"]);
        assert_eq!(tokens("Cœur"), ["coeur"]);
        assert_eq!(tokens("Sigurðsson"), ["sigurdsson"]);
        assert_eq!(tokens("Sølvsvin"), ["solvsvin"]);
    }

    #[test]
    fn precomposed_and_decomposed_text_fold_the_same_way() {
        // The bug this rule fixes: a decomposed mark used to be read as a word
        // separator, so the word came apart instead of losing its accent.
        assert_eq!(tokens("Mötley"), tokens("Mo\u{0308}tley"));
        assert_eq!(tokens("Mo\u{0308}tley"), ["motley"]);
        assert_eq!(tokens("cafe\u{0301}"), ["cafe"]);
        assert_eq!(tokens("Dvor\u{030C}a\u{0301}k"), ["dvorak"]);
    }

    #[test]
    fn case_folds_in_both_directions() {
        assert_eq!(tokens("MASTER"), tokens("master"));
        assert_eq!(tokens("BJÖRK"), tokens("björk"));
        assert_eq!(tokens("ÉCOLE"), ["ecole"]);
    }

    #[test]
    fn unfolded_scripts_survive_unchanged() {
        // Not folded on purpose: nobody types the "unaccented" spelling of
        // these. What matters is that they tokenize and never come apart.
        assert_eq!(tokens("Кино"), ["кино"]);
        assert_eq!(tokens("久石 譲"), ["久石", "譲"]);
        assert_eq!(tokens("Ωδή"), ["ωδή"]);
        assert_eq!(tokens("한국"), ["한국"]);
    }

    #[test]
    fn mixed_and_awkward_text_never_panics() {
        assert_eq!(tokens("Sigur Rós 🎵 (  ) 久石"), ["sigur", "ros", "久石"]);
        assert_eq!(tokens("🎵🎶"), Vec::<String>::new());
        assert_eq!(tokens("track\u{0000}name"), ["track", "name"]);
        let long = "é".repeat(10_000);
        assert_eq!(tokens(&long).len(), 1);
        assert_eq!(tokens(&long)[0].len(), 10_000);
    }

    #[test]
    fn digits_are_tokens_too() {
        assert_eq!(tokens("Track 199421"), ["track", "199421"]);
        assert_eq!(tokens("2Pac"), ["2pac"]);
    }
}
