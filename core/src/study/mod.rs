//! Word lookup for the manga reader's study mode: JMdict and KANJIDIC2 in a
//! SQLite file of their own, a sentence splitter and the deinflection rules.
//!
//! The dictionary is the user's download (jmdict-simplified's JSON, unpacked
//! by the app), not something the engine ships, so it lives in its own file
//! under Caches: disposable, rebuilt from the download, never in the registry.

pub mod deinflect;
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::ffi::AnicatError;
use deinflect::{class_of, deinflect, DICTIONARY_CLASSES};

/// Bumped whenever the tables change shape; an older file reads as not ready
/// and is rebuilt.
const SCHEMA: i64 = 1;
/// The longest run of characters tried as one word. JMdict expressions run
/// longer, but none a reader needs split out of a speech bubble.
const MAX_WORD_CHARS: usize = 12;
/// Entries shown per word: the first is nearly always the right one, and the
/// rest are there for homographs (`方` is ほう and かた).
const MAX_ENTRIES: usize = 3;

#[derive(Debug, Clone, uniffi::Record)]
pub struct StudyToken {
    /// The text as it appears in the bubble.
    pub surface: String,
    /// False for punctuation, Latin letters and digits, which are never
    /// looked up.
    pub is_word: bool,
    /// Empty for a word the dictionary does not have.
    pub entries: Vec<StudyEntry>,
    /// How the surface form came from the dictionary form, dictionary end
    /// first: `["te-form", "-te iru, casual (-teru)"]` for 待ってる.
    pub steps: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record, Serialize, Deserialize)]
pub struct StudyEntry {
    pub word: String,
    pub reading: String,
    /// Other spellings, so a word written in kana still shows its kanji.
    pub other_forms: Vec<String>,
    pub common: bool,
    pub senses: Vec<StudySense>,
}

#[derive(Debug, Clone, uniffi::Record, Serialize, Deserialize)]
pub struct StudySense {
    pub parts_of_speech: Vec<String>,
    pub glosses: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record, Serialize, Deserialize)]
pub struct StudyKanji {
    pub literal: String,
    pub meanings: Vec<String>,
    pub onyomi: Vec<String>,
    pub kunyomi: Vec<String>,
    pub jlpt: Option<u32>,
}

#[derive(uniffi::Object)]
pub struct StudyDictionary {
    path: PathBuf,
    conn: Mutex<Option<Connection>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl StudyDictionary {
    #[uniffi::constructor]
    pub fn new(path: String) -> Arc<Self> {
        Arc::new(Self { path: PathBuf::from(path), conn: Mutex::new(None) })
    }

    pub fn is_ready(&self) -> bool {
        self.with_conn(|_| Ok(())).is_ok()
    }

    /// Builds the dictionary from jmdict-simplified's `jmdict-eng` and
    /// `kanjidic2-en` JSON files, replacing any older one.
    pub async fn build(&self, words_json: String, kanji_json: String) -> Result<(), AnicatError> {
        let target = self.path.clone();
        tokio::task::spawn_blocking(move || build_file(&target, Path::new(&words_json), Path::new(&kanji_json)))
            .await
            .map_err(|e| AnicatError::Internal { msg: e.to_string() })??;
        *self.conn.lock().unwrap() = None;
        Ok(())
    }

    /// Splits a sentence into words, longest dictionary match first, and
    /// looks each one up.
    pub fn lookup(&self, text: String) -> Result<Vec<StudyToken>, AnicatError> {
        self.with_conn(|conn| split(conn, &text))
    }

    /// The kanji in `word`, in order, skipping any KANJIDIC2 lacks.
    pub fn kanji(&self, word: String) -> Result<Vec<StudyKanji>, AnicatError> {
        self.with_conn(|conn| {
            let mut stmt = conn.prepare_cached("SELECT data FROM kanji WHERE literal = ?1")?;
            let mut out = Vec::new();
            for c in word.chars().filter(|c| is_kanji(*c)) {
                let data: Option<String> = stmt.query_row([c.to_string()], |row| row.get(0)).optional()?;
                if let Some(kanji) = data.and_then(|d| serde_json::from_str(&d).ok()) {
                    out.push(kanji);
                }
            }
            Ok(out)
        })
    }
}

impl StudyDictionary {
    fn with_conn<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, AnicatError> {
        let mut guard = self.conn.lock().unwrap();
        if guard.is_none() {
            let conn = Connection::open_with_flags(&self.path, OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(|e| AnicatError::NotFound { msg: format!("study dictionary: {e}") })?;
            let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap_or(0);
            if version != SCHEMA {
                return Err(AnicatError::NotFound { msg: format!("study dictionary is version {version}") });
            }
            *guard = Some(conn);
        }
        f(guard.as_ref().unwrap()).map_err(|e| AnicatError::Storage { msg: e.to_string() })
    }
}

fn is_kanji(c: char) -> bool {
    matches!(c, '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}' | '々' | '〆' | 'ヶ')
}

fn is_hiragana(c: char) -> bool {
    matches!(c, '\u{3041}'..='\u{309F}')
}

/// カワイイ and トニカク: manga writes ordinary words in katakana for
/// emphasis, and JMdict lists most of them only in hiragana.
fn to_hiragana(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '\u{30A1}'..='\u{30F6}' => char::from_u32(c as u32 - 0x60).unwrap_or(c),
            _ => c,
        })
        .collect()
}

fn is_japanese(c: char) -> bool {
    is_kanji(c) || matches!(c, '\u{3041}'..='\u{309F}' | '\u{30A1}'..='\u{30FA}' | 'ー' | 'ヽ' | 'ヾ')
}

fn split(conn: &Connection, text: &str) -> rusqlite::Result<Vec<StudyToken>> {
    // The entry spelled exactly so comes first: の is the particle, not the
    // reading of 乃, which sorted ahead of it on commonness alone.
    let mut forms = conn.prepare_cached(
        "SELECT e.classes, e.data, f.exact, e.kana_ok FROM forms f JOIN entries e ON e.id = f.entry \
         WHERE f.form = ?1 ORDER BY f.exact DESC, f.common DESC, e.id",
    )?;
    let chars: Vec<char> = text.chars().collect();
    let mut tokens: Vec<StudyToken> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !is_japanese(chars[i]) {
            let start = i;
            while i < chars.len() && !is_japanese(chars[i]) {
                i += 1;
            }
            tokens.push(StudyToken {
                surface: chars[start..i].iter().collect(),
                is_word: false,
                entries: Vec::new(),
                steps: Vec::new(),
            });
            continue;
        }
        let longest = chars[i..].iter().take(MAX_WORD_CHARS).take_while(|c| is_japanese(**c)).count();
        let mut found: Option<(usize, Vec<StudyEntry>, Vec<&'static str>)> = None;
        'lengths: for len in (1..=longest).rev() {
            let surface: String = chars[i..i + len].iter().collect();
            let mut variants = vec![surface.clone()];
            let hiragana = to_hiragana(&surface);
            // Only a word written all in katakana: converting half of のメ
            // read it as the command form of 飲む.
            if surface.chars().all(|c| matches!(c, '\u{30A1}'..='\u{30FA}' | 'ー')) {
                variants.push(hiragana);
            }
            // Breadth-first, so the first candidate with a match took the
            // fewest steps; 待ってる must not read as some longer chain.
            for candidate in variants.iter().flat_map(|v| deinflect(v)) {
                let all_hiragana = candidate.term.chars().all(is_hiragana);
                let mut entries = Vec::new();
                let rows = forms.query_map([&candidate.term], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, bool>(2)?, row.get::<_, bool>(3)?))
                })?;
                for row in rows {
                    let (classes, data, exact, kana_ok) = row?;
                    let wanted = candidate.conditions & DICTIONARY_CLASSES;
                    if candidate.conditions != 0 && (classes as u16) & wanted == 0 {
                        continue;
                    }
                    // Greedy matching on hiragana swallows particles into
                    // the reading of some kanji noun: 人はこの read as 箱,
                    // がいい as 外衣. A kanji word is only taken from its
                    // reading when people actually write it in kana.
                    if all_hiragana && !exact && !kana_ok {
                        continue;
                    }
                    if let Ok(entry) = serde_json::from_str::<StudyEntry>(&data) {
                        entries.push(entry);
                    }
                    if entries.len() == MAX_ENTRIES {
                        break;
                    }
                }
                if !entries.is_empty() {
                    found = Some((len, entries, candidate.reasons));
                    break 'lengths;
                }
            }
        }
        let (len, entries, reasons) = found.unwrap_or((1, Vec::new(), Vec::new()));
        tokens.push(StudyToken {
            surface: chars[i..i + len].iter().collect(),
            is_word: true,
            entries,
            steps: reasons.into_iter().rev().map(String::from).collect(),
        });
        i += len;
    }
    Ok(tokens)
}

// MARK: - Building

#[derive(Deserialize)]
struct JmFile {
    words: Vec<JmWord>,
}

#[derive(Deserialize)]
struct JmWord {
    kanji: Vec<JmForm>,
    kana: Vec<JmForm>,
    sense: Vec<JmSense>,
}

#[derive(Deserialize)]
struct JmForm {
    common: bool,
    text: String,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Deserialize)]
struct JmSense {
    #[serde(rename = "partOfSpeech")]
    part_of_speech: Vec<String>,
    gloss: Vec<JmGloss>,
    #[serde(default)]
    misc: Vec<String>,
}

#[derive(Deserialize)]
struct JmGloss {
    text: String,
}

#[derive(Deserialize)]
struct KdFile {
    characters: Vec<KdCharacter>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KdCharacter {
    literal: String,
    reading_meaning: Option<KdReadingMeaning>,
    misc: KdMisc,
}

#[derive(Deserialize)]
struct KdReadingMeaning {
    groups: Vec<KdGroup>,
}

#[derive(Deserialize)]
struct KdGroup {
    readings: Vec<KdValue>,
    meanings: Vec<KdValue>,
}

#[derive(Deserialize)]
struct KdValue {
    #[serde(rename = "type", default)]
    kind: Option<String>,
    value: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KdMisc {
    jlpt_level: Option<u32>,
}

/// Writes next to the target and renames into place, so a build cut short
/// (the reader closed, the app quit) never leaves a half-filled file that
/// `is_ready` would accept.
fn build_file(target: &Path, words: &Path, kanji: &Path) -> Result<(), AnicatError> {
    let storage = |e: rusqlite::Error| AnicatError::Storage { msg: e.to_string() };
    let read = |p: &Path| std::fs::read(p).map_err(|e| AnicatError::NotFound { msg: format!("{}: {e}", p.display()) });
    let jm: JmFile = serde_json::from_slice(&read(words)?).map_err(|e| AnicatError::Internal { msg: format!("jmdict: {e}") })?;
    let kd: KdFile = serde_json::from_slice(&read(kanji)?).map_err(|e| AnicatError::Internal { msg: format!("kanjidic: {e}") })?;

    let partial = target.with_extension("building");
    let _ = std::fs::remove_file(&partial);
    let mut conn = Connection::open(&partial).map_err(storage)?;
    conn.execute_batch(
        "PRAGMA journal_mode = OFF;
         PRAGMA synchronous = OFF;
         CREATE TABLE entries (id INTEGER PRIMARY KEY, classes INTEGER NOT NULL, kana_ok INTEGER NOT NULL, data TEXT NOT NULL);
         CREATE TABLE forms (form TEXT NOT NULL, entry INTEGER NOT NULL, exact INTEGER NOT NULL, common INTEGER NOT NULL);
         CREATE TABLE kanji (literal TEXT PRIMARY KEY, data TEXT NOT NULL);",
    )
    .map_err(storage)?;

    // One transaction: row-by-row autocommit for ~200k entries is minutes.
    let tx = conn.transaction().map_err(storage)?;
    {
        let mut insert_entry = tx.prepare("INSERT INTO entries (id, classes, kana_ok, data) VALUES (?1, ?2, ?3, ?4)").map_err(storage)?;
        let mut insert_form = tx.prepare("INSERT INTO forms (form, entry, exact, common) VALUES (?1, ?2, ?3, ?4)").map_err(storage)?;
        for (id, word) in jm.words.iter().enumerate() {
            let Some(reading) = word.kana.first() else { continue };
            // A rare or irregular kanji spelling is not how the word is
            // written: the particle の lists 之 and 乃, and with those as
            // its headword the particle lost to every noun read の.
            let headword = word
                .kanji
                .iter()
                .find(|k| !k.tags.iter().any(|t| matches!(t.as_str(), "rK" | "sK" | "iK" | "oK")))
                .unwrap_or(reading);
            let common = word.kanji.iter().chain(&word.kana).any(|f| f.common);
            let classes = word.sense.iter().flat_map(|s| &s.part_of_speech).fold(0u16, |acc, tag| acc | class_of(tag));
            // Verbs and adjectives are written in kana all the time (わかる);
            // nouns only when JMdict says so ("uk") or they have no kanji.
            let kana_ok = std::ptr::eq(headword, reading) || classes != 0 || word.sense.iter().any(|s| s.misc.iter().any(|m| m == "uk"));
            let entry = StudyEntry {
                word: headword.text.clone(),
                reading: reading.text.clone(),
                other_forms: word.kanji.iter().filter(|f| !std::ptr::eq(*f, headword)).map(|f| f.text.clone()).collect(),
                common,
                senses: word
                    .sense
                    .iter()
                    .map(|s| StudySense {
                        parts_of_speech: s.part_of_speech.clone(),
                        glosses: s.gloss.iter().map(|g| g.text.clone()).collect(),
                    })
                    .collect(),
            };
            let data = serde_json::to_string(&entry).map_err(|e| AnicatError::Internal { msg: e.to_string() })?;
            insert_entry.execute(params![id as i64, classes, kana_ok, data]).map_err(storage)?;
            for form in word.kanji.iter().chain(&word.kana) {
                let exact = std::ptr::eq(form, headword);
                insert_form.execute(params![form.text, id as i64, exact, form.common]).map_err(storage)?;
            }
        }
        let mut insert_kanji = tx.prepare("INSERT OR REPLACE INTO kanji (literal, data) VALUES (?1, ?2)").map_err(storage)?;
        for c in &kd.characters {
            let groups = c.reading_meaning.as_ref().map(|rm| rm.groups.as_slice()).unwrap_or_default();
            let readings = |kind: &str| -> Vec<String> {
                groups.iter().flat_map(|g| &g.readings).filter(|r| r.kind.as_deref() == Some(kind)).map(|r| r.value.clone()).collect()
            };
            let kanji = StudyKanji {
                literal: c.literal.clone(),
                meanings: groups.iter().flat_map(|g| &g.meanings).map(|m| m.value.clone()).collect(),
                onyomi: readings("ja_on"),
                kunyomi: readings("ja_kun"),
                jlpt: c.misc.jlpt_level,
            };
            let data = serde_json::to_string(&kanji).map_err(|e| AnicatError::Internal { msg: e.to_string() })?;
            insert_kanji.execute(params![c.literal, data]).map_err(storage)?;
        }
    }
    tx.commit().map_err(storage)?;
    conn.execute_batch(&format!("CREATE INDEX forms_form ON forms (form); PRAGMA user_version = {SCHEMA};"))
        .map_err(storage)?;
    drop(conn);
    std::fs::rename(&partial, target).map_err(|e| AnicatError::Storage { msg: e.to_string() })
}
