//! Selection tests driven by real torrent metadata.
//!
//! Every fixture in `fixtures.rs` is the actual file list of a real Nyaa
//! release for "The Testament of Sister New Devil", pulled from its .torrent
//! and pasted verbatim (paths and byte lengths both — the lengths matter,
//! since picking the largest file among ties is what the old selection did and
//! what several of these prove is wrong). That franchise was chosen because it
//! is the shape the whole module exists for: two TV seasons where the second
//! is named rather than numbered, two separate specials collections, two OVAs
//! and a standalone one, packaged by seven different groups in five mutually
//! incompatible layouts.
//!
//! The AniList entries below are the real ones, with their real episode
//! counts. Each test states the exact file that must come back.

use super::*;

include!("fixtures.rs");

/// The AniList entries a viewer can actually pick for this franchise, with
/// their real ids, titles and episode counts. There are eight in total; these
/// are the six a release actually exists for.
mod entry {
    use super::*;

    /// AniList 20678 — "Shinmai Maou no Testament" (TV, 12 episodes). No TV
    /// prequel, so its season is known outright.
    pub fn season_one() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament".into(),
                "The Testament of Sister New Devil".into(),
            ],
            EntryHint { kind: EntryKind::Tv, season: Some(1), season_at_least: None },
            Some(12),
        )
    }

    /// AniList 21110 — "Shinmai Maou no Testament Burst" (TV, 10 episodes).
    /// Season 2, and neither of its main titles says so; only a way-down
    /// synonym ("Shinmai Maou no Testament Season 2") ever spells it out.
    /// Modelled here as if that synonym were absent, which is the case the
    /// rest of the evidence has to carry on its own.
    pub fn burst() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament Burst".into(),
                "The Testament of Sister New Devil BURST".into(),
            ],
            EntryHint { kind: EntryKind::Tv, season: None, season_at_least: Some(2) },
            Some(10),
        )
    }

    /// AniList 21209 — "Shinmai Maou no Testament Specials" (SPECIAL, 6).
    pub fn specials() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament Specials".into(),
                "The Testament of Sister New Devil Specials".into(),
                "Shinmai Maou no Testament: Loli Ero Succubus Maria no Characommentary Tsuki Hizou Eizou".into(),
            ],
            EntryHint { kind: EntryKind::Extra, season: None, season_at_least: None },
            Some(6),
        )
    }

    /// AniList 102508 — "Shinmai Maou no Testament Burst Specials"
    /// (SPECIAL, 5).
    pub fn burst_specials() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament Burst Specials".into(),
                "The Testament of Sister New Devil BURST Specials".into(),
            ],
            EntryHint { kind: EntryKind::Extra, season: None, season_at_least: None },
            Some(5),
        )
    }

    /// AniList 100451 — "Shinmai Maou no Testament Departures" (OVA, 1).
    pub fn departures() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament Departures".into(),
                "The Testament of Sister New Devil DEPARTURES".into(),
            ],
            EntryHint { kind: EntryKind::Extra, season: None, season_at_least: None },
            Some(1),
        )
    }

    /// AniList 21247 — "Shinmai Maou no Testament: Toujou Basara no Hard
    /// Sweet na Nichijou" (OVA, 1): the season 1 OVA, which most packs ship
    /// as an extra episode of season 1 rather than as anything separate.
    pub fn season_one_ova() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou".into(),
                "Shinmai Maou no Testament OVA".into(),
            ],
            EntryHint { kind: EntryKind::Extra, season: None, season_at_least: None },
            Some(1),
        )
    }

    /// AniList 21489 — "Shinmai Maou no Testament Burst: Toujou Basara no
    /// Shigoku Heiwa na Nichijou" (OVA, 1): the season 2 OVA.
    pub fn burst_ova() -> (Vec<String>, EntryHint, Option<i64>) {
        (
            vec![
                "Shinmai Maou no Testament Burst: Toujou Basara no Shigoku Heiwa na Nichijou".into(),
                "Shinmai Maou no Testament Burst OVA".into(),
            ],
            EntryHint { kind: EntryKind::Extra, season: None, season_at_least: None },
            Some(1),
        )
    }
}

/// Run a selection against a fixture and return the chosen path.
fn choose(
    files: &[(&str, u64)],
    release_name: &str,
    entry: (Vec<String>, EntryHint, Option<i64>),
    episode: i64,
) -> Result<String, SelectError> {
    let (titles, hint, episode_count) = entry;
    let alts: Vec<String> = titles.iter().map(|t| normalize(t)).collect();
    let indexed: Vec<(usize, String, u64)> = files
        .iter()
        .enumerate()
        .map(|(i, (p, l))| (i, (*p).to_string(), *l))
        .collect();
    let req = SelectRequest {
        titles: &titles,
        alts: &alts,
        hint,
        episode,
        episode_count,
        release_name,
        allow_episodeless: episode_count == Some(1),
    };
    select(&indexed, &req).map(|i| files[i].0.to_string())
}


// ---------------------------------------------------------------------------
// Flat pack, seasons told apart only by the title inside each filename.
// ---------------------------------------------------------------------------

#[test]
fn a_flat_two_season_pack_is_split_by_the_title_in_each_filename() {
    // "Shinmai Maou no Testament - 01" and "Shinmai Maou no Testament Burst -
    // 01" sit in the same directory with no season marker anywhere. Both
    // answer to "episode 1"; the Burst file is the larger of the two, so the
    // old largest-file tiebreak handed season 2's premiere to a season 1
    // request. Nothing but the title text distinguishes them.
    assert_eq!(
        choose(SMOODFLAMEZ, SMOODFLAMEZ_NAME, entry::season_one(), 1).unwrap(),
        "Shinmai Maou no Testament - 01_BD720p_10bit.mkv"
    );
    assert_eq!(
        choose(SMOODFLAMEZ, SMOODFLAMEZ_NAME, entry::burst(), 1).unwrap(),
        "Shinmai Maou no Testament Burst - 01_BD720p_10bit.mkv"
    );
    // ...and the last episode of each, where the two seasons have different
    // lengths (12 against 10).
    assert_eq!(
        choose(SMOODFLAMEZ, SMOODFLAMEZ_NAME, entry::season_one(), 12).unwrap(),
        "Shinmai Maou no Testament - 12_BD720p_10bit.mkv"
    );
    assert_eq!(
        choose(SMOODFLAMEZ, SMOODFLAMEZ_NAME, entry::burst(), 10).unwrap(),
        "Shinmai Maou no Testament Burst - 10_BD720p_10bit.mkv"
    );
}

// ---------------------------------------------------------------------------
// Folder-per-season packs.
// ---------------------------------------------------------------------------

#[test]
fn a_season_foldered_pack_answers_a_named_sequel_by_episode_count() {
    // "Season 1/" (12 files) and "Season 2/" (10) and "Special/" (14). The
    // Burst entry's title says nothing about being season 2, and no folder
    // says "Burst" — the only thing tying the entry to `Season 2/` is that
    // the entry has exactly 10 episodes and only one folder holds 10 files.
    assert_eq!(
        choose(TENRAI, TENRAI_NAME, entry::burst(), 1).unwrap(),
        "Season 2/The Testament Of Sister New Devil - S02E01 - What I Can Do For You.mkv"
    );
    assert_eq!(
        choose(TENRAI, TENRAI_NAME, entry::season_one(), 1).unwrap(),
        "Season 1/The Testament Of Sister New Devil - S01E01 - The Day I Got A Little Sister.mkv"
    );
    // The same shape from two other groups, one of which abbreviates the
    // folders to "S1"/"S2" and files its OVAs under "OVA 1/".
    assert_eq!(
        choose(RAZE, RAZE_NAME, entry::season_one(), 11).unwrap(),
        "Season 1/[Raze] Shinmai Maou No Testament S01E11 x265 10bit BD (DualAudio) 1080p 120fps.mkv"
    );
    assert_eq!(
        choose(RAZE, RAZE_NAME, entry::burst(), 1).unwrap(),
        "Season 2/[Raze] Shinmai Maou No Testament S02E01 x265 10bit BD (DualAudio) 1080p 120fps.mkv"
    );
    assert_eq!(
        choose(BLUURY, BLUURY_NAME, entry::season_one(), 3).unwrap(),
        "S1/Shinmai Maou no Testament S01E03 Reunion and a Gap in Trust.mkv"
    );
    assert_eq!(
        choose(BLUURY, BLUURY_NAME, entry::burst(), 10).unwrap(),
        "S2/Shinmai Maou no Testament S02E10 The Consequences of What Must Be Done.mkv"
    );
}

#[test]
fn a_combined_pack_never_serves_the_other_seasons_episode_one() {
    // The EMBER pack is the release that reported this bug: 24 files across
    // two season folders, `S01E01` (368MB) and `S02E01` (386MB) both matching
    // "episode 1", the season 2 file larger. Season 1 is known outright here
    // (the entry has no TV prequel), so the wrong-season file is excluded
    // rather than outranked.
    assert_eq!(
        choose(EMBER, EMBER_NAME, entry::season_one(), 1).unwrap(),
        "Shinmai Maou no Testament S01+OVA 1080p Dual Audio BDRip 10 bits DD x265-EMBER/S01E01-The Day I Got a Little Sister [977B4FC2].mkv"
    );
    assert_eq!(
        choose(EMBER, EMBER_NAME, entry::season_one(), 12).unwrap(),
        "Shinmai Maou no Testament S01+OVA 1080p Dual Audio BDRip 10 bits DD x265-EMBER/S01E12-For This Night, This Moment [E75A9CD9].mkv"
    );
    // Neither folder holds exactly 10 files (each carries its season's OVA as
    // one more episode), so the count pass can't answer for Burst. The
    // prequel lower bound can: whatever season Burst is, it is not season 1,
    // and only one other season exists in the pack.
    assert_eq!(
        choose(EMBER, EMBER_NAME, entry::burst(), 1).unwrap(),
        "Shinmai Maou no Testament S02+OVA 1080p Dual Audio BDRip 10 bits DD x265-EMBER/S02E01-What I Can Do For You [F9D09859].mkv"
    );
}

#[test]
fn a_folder_named_after_its_season_beats_every_numeric_signal() {
    // The DB pack names each folder after the season's own title rather than
    // numbering it, and hides 36 creditless openings/endings plus both
    // specials runs under `Extras/`. A TV request must land on the numbered
    // episode in the right title's folder and never in `Extras/`.
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::season_one(), 1).unwrap(),
        "Shinmai Maou no Testament/[DB]Shinmai Maou no Testament_-_01_(Dual Audio_10bit_BD1080p_x265).mkv"
    );
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::burst(), 1).unwrap(),
        "Shinmai Maou no Testament Burst/[DB]Shinmai Maou no Testament Burst_-_01_(Dual Audio_10bit_BD1080p_x265).mkv"
    );
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::burst(), 10).unwrap(),
        "Shinmai Maou no Testament Burst/[DB]Shinmai Maou no Testament Burst_-_10_(Dual Audio_10bit_BD1080p_x265).mkv"
    );
}

// ---------------------------------------------------------------------------
// OVAs and specials.
// ---------------------------------------------------------------------------

#[test]
fn two_specials_collections_in_one_pack_go_to_their_own_seasons_folder() {
    // Both specials runs are named `SP01`.. inside their season's `Extras/`,
    // so the numbers collide outright: SP01 exists twice. The season's title
    // on the parent folder is what separates them — after the entry's own
    // "Specials" suffix is dropped, which is a word no release group puts in
    // a folder name.
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::specials(), 1).unwrap(),
        "Shinmai Maou no Testament/Extras/[DB]Shinmai Maou no Testament_-_SP01_(10bit_BD1080p_x265).mkv"
    );
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::specials(), 6).unwrap(),
        "Shinmai Maou no Testament/Extras/[DB]Shinmai Maou no Testament_-_SP06_(10bit_BD1080p_x265).mkv"
    );
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::burst_specials(), 1).unwrap(),
        "Shinmai Maou no Testament Burst/Extras/[DB]Shinmai Maou no Testament Burst_-_SP01_(10bit_BD1080p_x265).mkv"
    );
    // The OVA lives in the same folder as the six specials and is the larger
    // file, so it wins a naive tie for "episode 1". The run lengths say which
    // request is which: six specials answer the six-episode entry, the lone
    // OVA answers the one-episode one.
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::departures(), 1).unwrap(),
        "Shinmai Maou no Testament Departures/[DB]Shinmai Maou no Testament Departures_-_OVA_(Dual Audio_10bit_BD1080p_x265).mkv"
    );
}

#[test]
fn each_of_the_three_ovas_lands_on_its_own_season_bonus_episode() {
    // Three separate one-episode AniList entries — the season 1 OVA, the
    // season 2 OVA and the standalone Departures — and every pack ships all
    // three, unnumbered, under whatever convention that group uses. The DB
    // pack files two of them as `Extras/..._-_OVA_...` inside their season's
    // folder, where six numbered specials sit alongside and the OVA is the
    // bigger file; the run lengths keep the one-episode entry off the
    // six-episode run and vice versa.
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::season_one_ova(), 1).unwrap(),
        "Shinmai Maou no Testament/Extras/[DB]Shinmai Maou no Testament_-_OVA_(Dual Audio_10bit_BD1080p_x265).mkv"
    );
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::burst_ova(), 1).unwrap(),
        "Shinmai Maou no Testament Burst/Extras/[DB]Shinmai Maou no Testament Burst_-_OVA_(Dual Audio_10bit_BD1080p_x265).mkv"
    );
    // The flat pack spells the same three as "- OAD", "Burst - OVA" and a
    // bare "Departures", told apart only by the title text.
    assert_eq!(
        choose(SMOODFLAMEZ, SMOODFLAMEZ_NAME, entry::season_one_ova(), 1).unwrap(),
        "Shinmai Maou no Testament - OAD_BD720p_10bit.mkv"
    );
    assert_eq!(
        choose(SMOODFLAMEZ, SMOODFLAMEZ_NAME, entry::burst_ova(), 1).unwrap(),
        "Shinmai Maou no Testament Burst - OVA_BD720p_10bit.mkv"
    );
    // EMBER numbers each season's OVA as one more episode of that season
    // (`S01E13 [OVA]`, `S02E11 [OVA]`) rather than filing it as an extra.
    assert_eq!(
        choose(EMBER, EMBER_NAME, entry::season_one_ova(), 1).unwrap(),
        "Shinmai Maou no Testament S01+OVA 1080p Dual Audio BDRip 10 bits DD x265-EMBER/S01E13 [OVA]-The Hard, Sweet Daily Life of Toujou Basara [F0C21AF4].mkv"
    );
}

#[test]
fn a_dedicated_specials_release_is_read_by_its_sp_numbering() {
    // "SP1".."SP6" carry no episode number any of the episode parsers can
    // see, which is why these releases could not be played at all: the
    // specials sequence is its own numbering and has to be read as one.
    assert_eq!(
        choose(SCY_SP, SCY_SP_NAME, entry::specials(), 1).unwrap(),
        "[SCY-Kuromii] Shinmai Maou no Testament - SP1 (BD 1080p Hi10 FLAC) [C67051CE].mkv"
    );
    assert_eq!(
        choose(SCY_SP, SCY_SP_NAME, entry::specials(), 6).unwrap(),
        "[SCY-Kuromii] Shinmai Maou no Testament - SP6 (BD 1080p Hi10 FLAC) [5D1F0045].mkv"
    );
    assert_eq!(
        choose(SCY_BURST_SP, SCY_BURST_SP_NAME, entry::burst_specials(), 3).unwrap(),
        "[SCY] Shinmai Maou no Testament BURST - SP3 [2DBF4F9D].mkv"
    );
}

#[test]
fn a_pack_whose_only_numbered_run_is_the_wrong_kind_declines() {
    // The Chihiro pack numbers the six specials ("Special 1".."Special 6")
    // and files the OVA as episode 13 of the season, marked as nothing at
    // all. For the six-episode specials entry that run is exactly right.
    assert_eq!(
        choose(CHIHIRO_S1, CHIHIRO_S1_NAME, entry::specials(), 1).unwrap(),
        "[Chihiro] Shinmai Maou no Testament Special 1 [Blu-ray 1080p Hi10P FLAC][1196F8B6].mkv"
    );
    assert_eq!(
        choose(CHIHIRO_S1, CHIHIRO_S1_NAME, entry::specials(), 6).unwrap(),
        "[Chihiro] Shinmai Maou no Testament Special 6 [Blu-ray 1080p Hi10P FLAC][E99CF71B].mkv"
    );
    // For the one-episode OVA entry it is not. The specials run is the only
    // numbered extras run in the pack, so "special 1" is the only thing this
    // could answer with — and the OVA entry says outright that it is an OVA,
    // which "Special 1" is not. Declining sends the caller to a pack that
    // does mark its OVA.
    assert_eq!(
        choose(CHIHIRO_S1, CHIHIRO_S1_NAME, entry::season_one_ova(), 1),
        Err(SelectError::NotFound)
    );
}

#[test]
fn an_unresolvable_multi_season_pack_is_refused_rather_than_guessed() {
    // The Tenrai pack's `Special/` folder holds both specials runs plus both
    // OVAs and Departures, numbered S00E01-E14 as one continuous sequence.
    // Nothing in it says where the Burst specials start, no folder names the
    // entry, and no season group is five files long. The honest answer is to
    // decline: the caller then tries the next release, where guessing would
    // have played the season 1 OVA and called it a Burst special.
    assert_eq!(
        choose(TENRAI, TENRAI_NAME, entry::burst_specials(), 1),
        Err(SelectError::Ambiguous)
    );
}

#[test]
fn an_episode_the_pack_does_not_have_is_not_found_rather_than_substituted() {
    // Burst has 10 episodes; asking a season 1 pack for episode 11 must fail
    // outright rather than return whatever is closest.
    assert_eq!(
        choose(SCY_SP, SCY_SP_NAME, entry::specials(), 9),
        Err(SelectError::NotFound)
    );
    assert_eq!(
        choose(DB_COMPLETE, DB_COMPLETE_NAME, entry::burst(), 11),
        Err(SelectError::NotFound)
    );
}

// ---------------------------------------------------------------------------
// The parsing primitives, on the strings that actually broke them.
// ---------------------------------------------------------------------------

#[test]
fn special_numbering_is_read_from_the_basename_only() {
    assert_eq!(special_of("[SCY] Shinmai Maou no Testament BURST - SP3 [2DBF4F9D].mkv"), Some((SpecialMark::Sp, 3)));
    assert_eq!(special_of("[DB]Show_-_SP01_(10bit_BD1080p_x265).mkv"), Some((SpecialMark::Sp, 1)));
    assert_eq!(special_of("Show - Special 2.mkv"), Some((SpecialMark::Sp, 2)));
    // A bare marker is the only one there is.
    assert_eq!(special_of("[DB]Show Departures_-_OVA_(Dual Audio).mkv"), Some((SpecialMark::Ova, 1)));
    assert_eq!(special_of("Show - OAD_BD720p_10bit.mkv"), Some((SpecialMark::Ova, 1)));
    assert_eq!(special_of("Show - OVA2 [1080p].mkv"), Some((SpecialMark::Ova, 2)));
    // Creditless material is never anyone's episode.
    assert_eq!(special_of("[DB]Show_-_NCED01_(10bit).mkv"), Some((SpecialMark::Creditless, 0)));
    assert_eq!(special_of("[DB]Show_-_NCOP04_(10bit).mkv"), Some((SpecialMark::Creditless, 0)));
    // A plain episode says nothing.
    assert_eq!(special_of("[SubsPlease] Show - 05 (1080p).mkv"), None);
}

#[test]
fn an_extras_folder_is_recognised_however_it_is_spelled() {
    assert!(is_extra_dir("Extras"));
    assert!(is_extra_dir("Specials"));
    assert!(is_extra_dir("Special"));
    assert!(is_extra_dir("OVA 1"));
    assert!(is_extra_dir("NCOP"));
    // A season folder, and a folder named after the show, are not extras.
    assert!(!is_extra_dir("Season 2"));
    assert!(!is_extra_dir("S1"));
    assert!(!is_extra_dir("Shinmai Maou no Testament Burst"));
}

#[test]
fn a_split_cour_still_remaps_inside_its_own_season() {
    // The absolute-numbering remap has to survive season-scoping: "86
    // EIGHTY-SIX Part 2" is an 11-episode AniList entry whose files continue
    // the series count at 12. One season, no folders, no ambiguity.
    let files: Vec<(&str, u64)> = (12..=22)
        .map(|n| match n {
            12 => ("[Group] 86 Eighty Six - 12 [1080p].mkv", 100u64),
            13 => ("[Group] 86 Eighty Six - 13 [1080p].mkv", 100),
            14 => ("[Group] 86 Eighty Six - 14 [1080p].mkv", 100),
            15 => ("[Group] 86 Eighty Six - 15 [1080p].mkv", 100),
            16 => ("[Group] 86 Eighty Six - 16 [1080p].mkv", 100),
            17 => ("[Group] 86 Eighty Six - 17 [1080p].mkv", 100),
            18 => ("[Group] 86 Eighty Six - 18 [1080p].mkv", 100),
            19 => ("[Group] 86 Eighty Six - 19 [1080p].mkv", 100),
            20 => ("[Group] 86 Eighty Six - 20 [1080p].mkv", 100),
            21 => ("[Group] 86 Eighty Six - 21 [1080p].mkv", 100),
            _ => ("[Group] 86 Eighty Six - 22 [1080p].mkv", 100),
        })
        .collect();
    let entry = (
        vec!["86 Eighty Six Part 2".into()],
        EntryHint { kind: EntryKind::Tv, season: None, season_at_least: Some(2) },
        Some(11),
    );
    assert_eq!(
        choose(&files, "[Group] 86 Eighty Six Part 2 (12-22) [1080p]", entry, 1).unwrap(),
        "[Group] 86 Eighty Six - 12 [1080p].mkv"
    );
}
