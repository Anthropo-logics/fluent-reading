use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum SpokenPart {
    Text(String),
    Punctuation(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SpokenPlan {
    pub language: String,
    pub frontend_voice: String,
    pub normalized_text: String,
    pub parts: Vec<SpokenPart>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpokenTextError;

impl SpokenTextError {
    pub const fn code(self) -> &'static str {
        "LF_TTS_LANGUAGE_UNSUPPORTED"
    }
}

pub fn spoken_plan(text: &str, language: &str) -> Result<SpokenPlan, SpokenTextError> {
    let voice = match language {
        "es" => "es",
        "en" => "en-us",
        "pt" => "pt-br",
        _ => return Err(SpokenTextError),
    };
    let normalized_text = normalize(text, language);
    let parts = split_parts(&normalized_text);
    Ok(SpokenPlan {
        language: language.into(),
        frontend_voice: voice.into(),
        normalized_text,
        parts,
    })
}

pub fn espeak_stdin(span: &str) -> String {
    format!("{span}\n")
}

fn normalize(text: &str, language: &str) -> String {
    let collapsed = text.nfc().collect::<String>();
    let collapsed = collapsed.split_whitespace().collect::<Vec<_>>().join(" ");
    if language == "en" {
        replace_exact_bounded(&collapsed, "CHAPTER I", "Chapter one")
    } else {
        collapsed
    }
}

fn replace_exact_bounded(text: &str, needle: &str, replacement: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut cursor = 0;
    while let Some(relative) = text[cursor..].find(needle) {
        let start = cursor + relative;
        let end = start + needle.len();
        let bounded = text[..start]
            .chars()
            .next_back()
            .is_none_or(|character| !character.is_alphanumeric())
            && text[end..]
                .chars()
                .next()
                .is_none_or(|character| !character.is_alphanumeric());
        if !bounded {
            result.push_str(&text[cursor..end]);
            cursor = end;
            continue;
        }
        result.push_str(&text[cursor..start]);
        result.push_str(replacement);
        cursor = end;
    }
    result.push_str(&text[cursor..]);
    result
}

fn split_parts(text: &str) -> Vec<SpokenPart> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut punctuation = None;
    for (index, character) in text.char_indices() {
        let is_punctuation = is_prosodic_punctuation(text, index, character);
        match (punctuation, is_punctuation) {
            (None, true) => {
                push_text(&mut parts, &text[start..index]);
                punctuation = Some(index);
            }
            (Some(punctuation_start), false) => {
                parts.push(SpokenPart::Punctuation(
                    text[punctuation_start..index].into(),
                ));
                punctuation = None;
                start = index;
            }
            _ => {}
        }
    }
    if let Some(punctuation_start) = punctuation {
        parts.push(SpokenPart::Punctuation(text[punctuation_start..].into()));
    } else {
        push_text(&mut parts, &text[start..]);
    }
    parts
}

pub(crate) fn is_prosodic_punctuation(text: &str, index: usize, character: char) -> bool {
    if !matches!(character, ',' | '.' | ';' | ':' | '!' | '?' | '—') {
        return false;
    }
    let before = text[..index].chars().next_back();
    let after = text[index + character.len_utf8()..].chars().next();
    if matches!(character, ',' | '.' | ':')
        && before.is_some_and(char::is_numeric)
        && after.is_some_and(char::is_numeric)
    {
        return false;
    }
    if character != '.' {
        return true;
    }
    if before.is_some_and(char::is_alphabetic) && after.is_some_and(char::is_alphabetic) {
        return false;
    }
    let token = text[..index]
        .split_whitespace()
        .next_back()
        .unwrap_or_default()
        .trim_matches(|value: char| !value.is_alphanumeric() && value != '.');
    let abbreviation = (token.contains('.') && token.chars().any(char::is_alphabetic))
        || matches!(
            token.to_lowercase().as_str(),
            "mr" | "mrs"
                | "ms"
                | "dr"
                | "dra"
                | "prof"
                | "sr"
                | "sra"
                | "srta"
                | "art"
                | "arts"
                | "no"
                | "núm"
                | "vol"
                | "fig"
                | "p"
                | "pp"
                | "cf"
                | "vs"
        );
    !abbreviation
}

fn push_text(parts: &mut Vec<SpokenPart>, text: &str) {
    let text = text.trim();
    if !text.is_empty() {
        parts.push(SpokenPart::Text(text.into()));
    }
}
