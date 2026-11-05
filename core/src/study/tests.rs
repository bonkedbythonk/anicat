use super::deinflect::{deinflect, ADJ_I, V1, V5, VK, VS};
use super::*;

/// The chain that turns `surface` into `term` with `class`, if one exists.
fn chain(surface: &str, term: &str, class: u16) -> Option<Vec<&'static str>> {
    deinflect(surface)
        .into_iter()
        .find(|c| c.term == term && c.conditions & class != 0)
        .map(|c| c.reasons.into_iter().rev().collect())
}

#[test]
fn godan_te_iru_casual_goes_back_to_the_dictionary_form() {
    assert_eq!(chain("待ってる", "待つ", V5), Some(vec!["te-form", "-te iru, casual (-teru)"]));
}

#[test]
fn te_iku_and_its_past_go_back_to_the_verb() {
    assert_eq!(chain("吸っていく", "吸う", V5), Some(vec!["te-form", "-te iku (going on)"]));
    assert!(chain("消えていった", "消える", V1).is_some());
}

#[test]
fn chau_is_te_shimau_on_the_te_form() {
    assert_eq!(
        chain("なくしちゃった", "なくす", V5),
        Some(vec!["te-form", "-te shimau, casual (-chau)", "past"])
    );
}

#[test]
fn ichidan_negative_past_runs_through_the_adjective_rules() {
    assert_eq!(chain("食べなかった", "食べる", V1), Some(vec!["negative", "past"]));
}

#[test]
fn polite_forms_reach_godan_ichidan_suru_and_kuru() {
    assert!(chain("帰りました", "帰る", V5).is_some());
    assert!(chain("食べません", "食べる", V1).is_some());
    assert!(chain("勉強します", "勉強する", VS).is_some());
    assert!(chain("来ます", "来る", VK).is_some());
}

#[test]
fn iku_keeps_its_irregular_te_form() {
    assert_eq!(chain("行って", "行く", V5), Some(vec!["te-form"]));
    // The regular row would have made it 行いて.
    assert!(chain("行いて", "行く", V5).is_some());
}

#[test]
fn adjective_adverb_and_te_forms() {
    assert_eq!(chain("早く", "早い", ADJ_I), Some(vec!["adverb"]));
    assert_eq!(chain("早くて", "早い", ADJ_I), Some(vec!["te-form"]));
}

#[test]
fn chains_stop_instead_of_running_forever() {
    // Potential and te-iru feed each other; without the step cap this list
    // never ends.
    assert!(deinflect("ていられてていられてている").len() < 5000);
}

/// A fresh folder per test; removed when the guard drops.
struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("anicat-study-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture_dictionary(name: &str) -> (TempDir, StudyDictionary) {
    let dir = TempDir::new(name);
    let words = dir.path().join("words.json");
    let kanji = dir.path().join("kanji.json");
    let word = |kanji: &str, kana: &str, pos: &str, gloss: &str| {
        let kanji = if kanji.is_empty() { String::new() } else { format!(r#"{{"common":true,"text":"{kanji}"}}"#) };
        format!(
            r#"{{"kanji":[{kanji}],"kana":[{{"common":true,"text":"{kana}"}}],"sense":[{{"partOfSpeech":["{pos}"],"gloss":[{{"text":"{gloss}"}}]}}]}}"#
        )
    };
    let all = [
        word("今日", "きょう", "n", "today"),
        word("", "は", "prt", "topic marker"),
        word("早い", "はやい", "adj-i", "early"),
        word("帰る", "かえる", "v5r", "to go home"),
        word("", "くる", "vk", "to come"),
        word("", "ね", "prt", "right?"),
        word("待つ", "まつ", "v5t", "to wait"),
        // A noun spelled like a conjugated form must not win over the verb.
        word("待っる", "まっる", "n", "not a real word"),
    ]
    .join(",");
    std::fs::write(&words, format!(r#"{{"words":[{all}]}}"#)).unwrap();
    std::fs::write(
        &kanji,
        r#"{"characters":[{"literal":"待","readingMeaning":{"groups":[{"readings":[{"type":"ja_on","value":"タイ"},{"type":"ja_kun","value":"ま.つ"}],"meanings":[{"value":"wait"}]}]},"misc":{"jlptLevel":3}}]}"#,
    )
    .unwrap();
    let dict = StudyDictionary { path: dir.path().join("dictionary.sqlite"), conn: Mutex::new(None) };
    build_file(&dict.path, &words, &kanji).unwrap();
    (dir, dict)
}

#[test]
fn a_sentence_splits_into_dictionary_words() {
    let (_dir, dict) = fixture_dictionary("sentence");
    assert!(dict.is_ready());
    let tokens = dict.lookup("今日は早く帰ってくるね。".into()).unwrap();
    let surfaces: Vec<&str> = tokens.iter().map(|t| t.surface.as_str()).collect();
    // 帰ってくる is one word with its helper verb, as Yomitan reads it.
    assert_eq!(surfaces, ["今日", "は", "早く", "帰ってくる", "ね", "。"]);
    assert_eq!(tokens[2].entries[0].word, "早い");
    assert_eq!(tokens[3].entries[0].word, "帰る");
    assert_eq!(tokens[3].steps, ["te-form", "-te kuru"]);
    assert!(!tokens[5].is_word);
}

#[test]
fn a_rule_result_only_matches_an_entry_of_its_class() {
    let (_dir, dict) = fixture_dictionary("class");
    let tokens = dict.lookup("待って".into()).unwrap();
    assert_eq!(tokens.len(), 1);
    assert_eq!(tokens[0].entries[0].word, "待つ");
}

#[test]
fn kanji_come_back_in_order_with_readings() {
    let (_dir, dict) = fixture_dictionary("kanji");
    let kanji = dict.kanji("待つ".into()).unwrap();
    assert_eq!(kanji.len(), 1);
    assert_eq!(kanji[0].onyomi, ["タイ"]);
    assert_eq!(kanji[0].kunyomi, ["ま.つ"]);
    assert_eq!(kanji[0].jlpt, Some(3));
}

#[test]
fn a_missing_file_is_not_ready() {
    let dict = StudyDictionary::new("/nonexistent/dictionary.sqlite".into());
    assert!(!dict.is_ready());
}

/// Local only: splits every bubble of a real chapter with the real
/// dictionary and prints the result, to read the splits by eye. Needs
/// `STUDY_JMDICT`, `STUDY_KANJIDIC` and `STUDY_MOKURO` pointing at the
/// downloaded files. Its output is copyrighted text; never commit it.
#[test]
#[ignore]
fn live_split_a_real_chapter() {
    let env = |k: &str| std::env::var(k).unwrap_or_else(|_| panic!("set {k}"));
    let dir = TempDir::new("live");
    let path = dir.path().join("dictionary.sqlite");
    let started = std::time::Instant::now();
    build_file(&path, Path::new(&env("STUDY_JMDICT")), Path::new(&env("STUDY_KANJIDIC"))).unwrap();
    println!("build {:?}, {} bytes", started.elapsed(), std::fs::metadata(&path).unwrap().len());
    let dict = StudyDictionary { path, conn: Mutex::new(None) };
    let volume: serde_json::Value = serde_json::from_slice(&std::fs::read(env("STUDY_MOKURO")).unwrap()).unwrap();
    let (mut known, mut unknown) = (0, 0);
    let started = std::time::Instant::now();
    for page in volume["pages"].as_array().unwrap() {
        for block in page["blocks"].as_array().unwrap() {
            let text: String = block["lines"].as_array().unwrap().iter().filter_map(|l| l.as_str()).collect();
            let tokens = dict.lookup(text).unwrap();
            let shown: Vec<String> = tokens
                .iter()
                .filter(|t| t.is_word)
                .map(|t| match t.entries.first() {
                    Some(e) if e.word != t.surface => format!("{}={}", t.surface, e.word),
                    Some(_) => t.surface.clone(),
                    None => format!("?{}", t.surface),
                })
                .collect();
            known += tokens.iter().filter(|t| t.is_word && !t.entries.is_empty()).count();
            unknown += tokens.iter().filter(|t| t.is_word && t.entries.is_empty()).count();
            println!("{}", shown.join(" | "));
        }
    }
    println!("known {known}, unknown {unknown}, lookups took {:?}", started.elapsed());
}
