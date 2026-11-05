//! Turns a conjugated word back into the forms a dictionary lists, the way
//! Yomitan does: a table of ending rewrites applied in chains, each step
//! remembering what kind of word the result has to be.
//!
//! A chain is only a guess until the dictionary agrees: `待って` rewrites to
//! `待つ` (godan) and to `待っる` (ichidan), and only the first is a word whose
//! part of speech matches. `lookup` does that check; this module only
//! proposes.

use std::collections::HashSet;

/// What a form has to be for a rule to apply to it, or what a rule's result
/// is. Dictionary classes first, then the in-between forms a chain passes
/// through (`待って` is a te-form before it is anything a dictionary lists).
pub const V1: u16 = 1;
pub const V5: u16 = 1 << 1;
pub const VS: u16 = 1 << 2;
pub const VK: u16 = 1 << 3;
pub const ADJ_I: u16 = 1 << 4;
const MASU: u16 = 1 << 5;
const TE: u16 = 1 << 6;
const TA: u16 = 1 << 7;

/// The classes a dictionary entry can have; the others never end a chain.
pub const DICTIONARY_CLASSES: u16 = V1 | V5 | VS | VK | ADJ_I;

/// Maps a JMdict part-of-speech tag onto the classes above.
pub fn class_of(tag: &str) -> u16 {
    match tag {
        t if t.starts_with("v1") => V1,
        t if t.starts_with("v5") => V5,
        t if t.starts_with("vs") => VS,
        "vk" => VK,
        "adj-i" | "adj-ix" => ADJ_I,
        _ => 0,
    }
}

struct Rule {
    from: String,
    to: String,
    /// What the inflected form must be for this rewrite to apply to it.
    /// Zero means the form is final (an imperative is not conjugated any
    /// further), so the rule only applies to the word as written.
    rules_in: u16,
    rules_out: u16,
    reason: &'static str,
}

/// One proposed dictionary form and the steps that led to it, surface first.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub term: String,
    /// Zero for the word as written, which any entry may match.
    pub conditions: u16,
    pub reasons: Vec<&'static str>,
}

/// Chains longer than this were never real words in testing, and without a
/// cap the te-form and potential rules feed each other indefinitely.
const MAX_STEPS: usize = 6;

pub fn deinflect(word: &str) -> Vec<Candidate> {
    let rules = rules();
    let mut out = vec![Candidate { term: word.to_string(), conditions: 0, reasons: Vec::new() }];
    let mut seen: HashSet<(String, u16)> = HashSet::from([(word.to_string(), 0)]);
    let mut index = 0;
    while index < out.len() {
        let current = out[index].clone();
        index += 1;
        if current.reasons.len() >= MAX_STEPS {
            continue;
        }
        for rule in rules {
            let applies = if current.conditions == 0 {
                true
            } else {
                current.conditions & rule.rules_in != 0
            };
            if !applies || !current.term.ends_with(rule.from.as_str()) {
                continue;
            }
            let stem = &current.term[..current.term.len() - rule.from.len()];
            let term = format!("{stem}{}", rule.to);
            if !seen.insert((term.clone(), rule.rules_out)) {
                continue;
            }
            let mut reasons = current.reasons.clone();
            reasons.push(rule.reason);
            out.push(Candidate { term, conditions: rule.rules_out, reasons });
        }
    }
    out
}

fn rules() -> &'static [Rule] {
    static RULES: std::sync::OnceLock<Vec<Rule>> = std::sync::OnceLock::new();
    RULES.get_or_init(build_rules)
}

fn build_rules() -> Vec<Rule> {
    let mut r: Vec<Rule> = Vec::new();
    let mut add = |from: &str, to: &str, rules_in: u16, rules_out: u16, reason: &'static str| {
        r.push(Rule { from: from.into(), to: to.into(), rules_in, rules_out, reason });
    };

    // Godan rows: dictionary ending, then its a / i / e / o sounds and its
    // te and ta forms.
    const GODAN: [(&str, &str, &str, &str, &str, &str, &str); 9] = [
        ("う", "わ", "い", "え", "お", "って", "った"),
        ("く", "か", "き", "け", "こ", "いて", "いた"),
        ("ぐ", "が", "ぎ", "げ", "ご", "いで", "いだ"),
        ("す", "さ", "し", "せ", "そ", "して", "した"),
        ("つ", "た", "ち", "て", "と", "って", "った"),
        ("ぬ", "な", "に", "ね", "の", "んで", "んだ"),
        ("ぶ", "ば", "び", "べ", "ぼ", "んで", "んだ"),
        ("む", "ま", "み", "め", "も", "んで", "んだ"),
        ("る", "ら", "り", "れ", "ろ", "って", "った"),
    ];
    for (u, a, i, e, o, te, ta) in GODAN {
        add(te, u, TE, V5, "te-form");
        add(ta, u, TA, V5, "past");
        add(&format!("{a}ない"), u, ADJ_I, V5, "negative");
        add(&format!("{a}ず"), u, 0, V5, "negative (written)");
        add(&format!("{i}ます"), u, MASU, V5, "polite");
        add(&format!("{i}たい"), u, ADJ_I, V5, "want to");
        add(&format!("{a}れる"), u, V1, V5, "passive");
        add(&format!("{a}せる"), u, V1, V5, "causative");
        add(&format!("{e}る"), u, V1, V5, "potential");
        add(e, u, 0, V5, "command");
        add(&format!("{o}う"), u, 0, V5, "let's / volitional");
        add(&format!("{e}ば"), u, 0, V5, "if (-ba)");
    }
    // 行く is the one godan verb whose te and ta forms break its row.
    for (stem, dict) in [("行", "行く"), ("い", "いく")] {
        add(&format!("{stem}って"), dict, TE, V5, "te-form");
        add(&format!("{stem}った"), dict, TA, V5, "past");
    }

    // Ichidan: the stem is the word minus る.
    add("て", "る", TE, V1, "te-form");
    add("た", "る", TA, V1, "past");
    add("ない", "る", ADJ_I, V1, "negative");
    add("ず", "る", 0, V1, "negative (written)");
    add("ます", "る", MASU, V1, "polite");
    add("たい", "る", ADJ_I, V1, "want to");
    add("られる", "る", V1, V1, "passive / can");
    add("れる", "る", V1, V1, "can (casual)");
    add("させる", "る", V1, V1, "causative");
    add("ろ", "る", 0, V1, "command");
    add("よう", "る", 0, V1, "let's / volitional");
    add("れば", "る", 0, V1, "if (-ba)");

    // する and くる, kana and kanji.
    add("して", "する", TE, VS, "te-form");
    add("した", "する", TA, VS, "past");
    add("しない", "する", ADJ_I, VS, "negative");
    add("せず", "する", 0, VS, "negative (written)");
    add("します", "する", MASU, VS, "polite");
    add("したい", "する", ADJ_I, VS, "want to");
    add("される", "する", V1, VS, "passive");
    add("させる", "する", V1, VS, "causative");
    add("しろ", "する", 0, VS, "command");
    add("しよう", "する", 0, VS, "let's / volitional");
    add("すれば", "する", 0, VS, "if (-ba)");
    for (ki, ko, ku) in [("き", "こ", "くる"), ("来", "来", "来る")] {
        add(&format!("{ki}て"), ku, TE, VK, "te-form");
        add(&format!("{ki}た"), ku, TA, VK, "past");
        add(&format!("{ko}ない"), ku, ADJ_I, VK, "negative");
        add(&format!("{ki}ます"), ku, MASU, VK, "polite");
        add(&format!("{ki}たい"), ku, ADJ_I, VK, "want to");
        add(&format!("{ko}られる"), ku, V1, VK, "passive / can");
        add(&format!("{ko}い"), ku, 0, VK, "command");
        add(&format!("{ko}よう"), ku, 0, VK, "let's / volitional");
    }
    add("くれば", "くる", 0, VK, "if (-ba)");
    add("来れば", "来る", 0, VK, "if (-ba)");

    // い-adjectives (and ない, たい, which conjugate like one).
    add("くて", "い", TE, ADJ_I, "te-form");
    add("かった", "い", TA, ADJ_I, "past");
    add("くない", "い", ADJ_I, ADJ_I, "negative");
    add("ければ", "い", 0, ADJ_I, "if (-ba)");
    add("く", "い", 0, ADJ_I, "adverb");
    add("そう", "い", 0, ADJ_I, "looks");
    add("さ", "い", 0, ADJ_I, "-ness");

    // ます conjugated.
    add("ました", "ます", TA, MASU, "past");
    add("ません", "ます", 0, MASU, "negative");
    add("ませんでした", "ます", 0, MASU, "negative past");
    add("ましょう", "ます", 0, MASU, "let's / volitional");
    add("まして", "ます", TE, MASU, "te-form");

    // Helpers after the te-form; each conjugates as the verb it is.
    for te in ["て", "で"] {
        add(&format!("{te}いる"), te, V1, TE, "-te iru (ongoing / state)");
        add(&format!("{te}る"), te, V1, TE, "-te iru, casual (-teru)");
        add(&format!("{te}しまう"), te, V5, TE, "-te shimau (completely / regret)");
        add(&format!("{te}おく"), te, V5, TE, "-te oku (in advance)");
        add(&format!("{te}くる"), te, VK, TE, "-te kuru");
        add(&format!("{te}いく"), te, V5, TE, "-te iku (going on)");
        add(&format!("{te}く"), te, V5, TE, "-te iku, casual (-teku)");
        add(&format!("{te}くれる"), te, V1, TE, "-te kureru (for me)");
        add(&format!("{te}もらう"), te, V5, TE, "-te morau (have done)");
        add(&format!("{te}ある"), te, V5, TE, "-te aru (has been done)");
        add(&format!("{te}みる"), te, V1, TE, "-te miru (try)");
    }
    add("ちゃう", "て", V5, TE, "-te shimau, casual (-chau)");
    add("じゃう", "で", V5, TE, "-te shimau, casual (-jau)");
    add("とく", "て", V5, TE, "-te oku, casual (-toku)");
    add("どく", "で", V5, TE, "-te oku, casual (-doku)");

    // たら and たり sit on the past form.
    add("たら", "た", 0, TA, "if / when (-tara)");
    add("だら", "だ", 0, TA, "if / when (-tara)");
    add("たり", "た", 0, TA, "things like (-tari)");
    add("だり", "だ", 0, TA, "things like (-tari)");

    r
}
