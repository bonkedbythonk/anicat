use super::*;

/// Both fixtures below are the real `/v4/anime/{id}` payloads for MAL 40748
/// and 51009, trimmed to the fields this module reads and wrapped in the
/// `data[]` the search endpoint returns them in — the two endpoints hand
/// back the same entity object.
fn jujutsu_kaisen_seasons() -> Vec<AnimeEntity> {
    results(
        r#"{"data":[
            {
              "mal_id": 51009,
              "title": "Jujutsu Kaisen 2nd Season",
              "title_english": "Jujutsu Kaisen Season 2",
              "title_japanese": "呪術廻戦 懐玉・玉折／渋谷事変",
              "titles": [
                {"type":"Default","title":"Jujutsu Kaisen 2nd Season"},
                {"type":"Synonym","title":"Jujutsu Kaisen: Shibuya Jihen"},
                {"type":"Synonym","title":"Sorcery Fight"},
                {"type":"Synonym","title":"JJK"},
                {"type":"English","title":"Jujutsu Kaisen Season 2"}
              ],
              "type": "TV",
              "year": 2023
            },
            {
              "mal_id": 40748,
              "title": "Jujutsu Kaisen",
              "title_english": "Jujutsu Kaisen",
              "title_japanese": "呪術廻戦",
              "titles": [
                {"type":"Default","title":"Jujutsu Kaisen"},
                {"type":"Synonym","title":"Sorcery Fight"},
                {"type":"Synonym","title":"JJK"},
                {"type":"English","title":"Jujutsu Kaisen"}
              ],
              "type": "TV",
              "year": 2020
            }
        ]}"#,
    )
}

fn results(json: &str) -> Vec<AnimeEntity> {
    serde_json::from_str::<SearchResponse>(json).unwrap().data
}

fn titles(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

#[test]
fn an_exact_romaji_title_resolves_to_its_mal_id() {
    let want = titles(&["Sousou no Frieren", "Frieren: Beyond Journey's End"]);
    let found = results(
        r#"{"data":[{
            "mal_id": 52991,
            "title": "Sousou no Frieren",
            "title_english": "Frieren: Beyond Journey's End",
            "title_japanese": "葬送のフリーレン",
            "titles": [
              {"type":"Default","title":"Sousou no Frieren"},
              {"type":"Synonym","title":"Frieren at the Funeral"},
              {"type":"English","title":"Frieren: Beyond Journey's End"}
            ],
            "type": "TV",
            "year": 2023
        }]}"#,
    );
    assert_eq!(pick_match(&found, &want, Some(2023), Some("TV")), Some(52991));
}

#[test]
fn punctuation_and_case_differences_still_match() {
    // AniList shouts its english titles ("JUJUTSU KAISEN Season 2") and the
    // two catalogs disagree about colons and apostrophes constantly. None of
    // that is a reason to miss.
    let want = titles(&["JUJUTSU KAISEN Season 2"]);
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &want, Some(2023), Some("TV")), Some(51009));
}

#[test]
fn a_season_marker_is_never_collapsed_onto_another_season() {
    // The trap this module is written around. Both seasons share the
    // synonyms "Sorcery Fight" and "JJK", and season 1 is the more popular
    // entry, so a match that ignored season markers would hand season 2's
    // detail page season 1's MAL id and AniSkip would cut at the wrong
    // moment for 23 episodes.
    let s1 = titles(&["Jujutsu Kaisen"]);
    let s2 = titles(&["Jujutsu Kaisen 2nd Season"]);
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &s1, Some(2020), Some("TV")), Some(40748));
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &s2, Some(2023), Some("TV")), Some(51009));
}

#[test]
fn a_shared_synonym_alone_does_not_pick_the_wrong_season() {
    // "Sorcery Fight" is listed on both entries. With no year to separate
    // them the first result wins, which is what relevance order is for —
    // the point of this test is that adding the year makes it exact.
    let want = titles(&["Sorcery Fight"]);
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &want, Some(2020), Some("TV")), Some(40748));
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &want, Some(2023), Some("TV")), Some(51009));
}

#[test]
fn a_title_match_in_a_different_year_is_rejected_rather_than_returned() {
    // A remake or a recap film carries the parent's exact title. Answering
    // with it would give AniSkip a real id for the wrong show, which reads
    // to the viewer as the skip button being broken.
    let want = titles(&["Jujutsu Kaisen"]);
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &want, Some(2016), Some("TV")), None);
}

#[test]
fn a_year_off_by_one_still_matches() {
    // A show that starts in October is filed under that season's year by
    // AniList and can be dated to either side of the new year by MAL's
    // fuzzy aired range; one year of slack costs nothing because the title
    // still has to be exactly equal.
    let want = titles(&["Jujutsu Kaisen"]);
    assert_eq!(pick_match(&jujutsu_kaisen_seasons(), &want, Some(2021), Some("TV")), Some(40748));
}

#[test]
fn the_start_year_is_read_from_the_aired_range_when_year_is_null() {
    // Jikan leaves `year` null on a lot of entries, currently-airing ones
    // included — exactly the shows this fallback exists for. Reading only
    // `year` would drop them into the no-year bucket and lose the
    // separation between a title and its sequel.
    let found = results(
        r#"{"data":[{
            "mal_id": 60022,
            "title": "One Piece Fan Letter",
            "titles": [{"type":"Default","title":"One Piece Fan Letter"}],
            "type": "TV Special",
            "year": null,
            "aired": {"prop": {"from": {"day": 20, "month": 10, "year": 2024}}}
        }]}"#,
    );
    assert_eq!(entity_year(&found[0]), Some(2024));
    let want = titles(&["One Piece Fan Letter"]);
    assert_eq!(pick_match(&found, &want, Some(2024), None), Some(60022));
    assert_eq!(pick_match(&found, &want, Some(2019), None), None);
}

#[test]
fn format_is_a_tiebreak_and_never_a_filter() {
    // A film and a TV entry can share a title and a year. The format hint
    // picks between them, but a lone candidate whose type disagrees is
    // still returned — the repo's dub-preference rule applied here: a
    // preference is not a filter.
    let found = results(
        r#"{"data":[
            {"mal_id": 100, "title": "Example Show", "type": "Movie", "year": 2024},
            {"mal_id": 200, "title": "Example Show", "type": "TV", "year": 2024}
        ]}"#,
    );
    let want = titles(&["Example Show"]);
    assert_eq!(pick_match(&found, &want, Some(2024), Some("TV")), Some(200));
    assert_eq!(pick_match(&found, &want, Some(2024), Some("MOVIE")), Some(100));
    // Nothing to tiebreak against: the only candidate wins anyway.
    let only_movie = results(r#"{"data":[{"mal_id": 100, "title": "Example Show", "type": "Movie", "year": 2024}]}"#);
    assert_eq!(pick_match(&only_movie, &want, Some(2024), Some("TV")), Some(100));
}

#[test]
fn a_merely_similar_title_is_not_a_match() {
    // The failure mode a fuzzy matcher would have: the search endpoint
    // answers on substrings, so a query for a short title comes back full
    // of longer ones that merely contain it.
    let found = results(
        r#"{"data":[
            {"mal_id": 1, "title": "Example Show: The Movie", "type": "Movie", "year": 2024},
            {"mal_id": 2, "title": "Example Show Gaiden", "type": "TV", "year": 2024}
        ]}"#,
    );
    assert_eq!(pick_match(&found, &titles(&["Example Show"]), Some(2024), Some("TV")), None);
}

#[test]
fn an_empty_or_blank_title_set_asks_nothing() {
    let found = jujutsu_kaisen_seasons();
    assert_eq!(pick_match(&found, &[], Some(2023), Some("TV")), None);
    assert_eq!(pick_match(&found, &titles(&["", "   "]), Some(2023), Some("TV")), None);
}

#[test]
fn an_empty_result_set_is_a_miss_not_a_panic() {
    assert_eq!(pick_match(&[], &titles(&["Anything"]), Some(2024), Some("TV")), None);
    assert_eq!(pick_match(&results(r#"{}"#), &titles(&["Anything"]), None, None), None);
}

#[test]
fn normalization_keeps_the_parts_that_distinguish_entries() {
    assert_eq!(normalize("Re:ZERO -Starting Life in Another World-"), "re zero starting life in another world");
    assert_eq!(normalize("Fate/Zero"), "fate zero");
    assert_eq!(normalize("  Spy x Family  "), "spy x family");
    // Season, part and cour markers are load-bearing and stay.
    assert_eq!(normalize("Jujutsu Kaisen 2nd Season"), "jujutsu kaisen 2nd season");
    assert_ne!(normalize("Mushoku Tensei II"), normalize("Mushoku Tensei"));
}

#[test]
fn query_encoding_survives_punctuation_and_unicode() {
    assert_eq!(urlencode("Re:ZERO"), "Re%3AZERO");
    assert_eq!(urlencode("Sousou no Frieren"), "Sousou+no+Frieren");
    assert_eq!(urlencode("葬送"), "%E8%91%AC%E9%80%81");
}

#[tokio::test]
async fn a_lookup_that_never_reached_jikan_is_unavailable_not_a_miss() {
    // The distinction the negative cache turns on. Forced offline through a
    // proxy pointed at a closed loopback port, so it needs no network and
    // cannot flake: every attempt errors before an answer, and the result
    // must not be the `NoMatch` that would get cached for hours and outlive
    // the outage that caused it.
    let http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all("http://127.0.0.1:1").unwrap())
        .build()
        .unwrap();
    let got = search_mal_id(&http, &titles(&["Sousou no Frieren"]), Some(2023), Some("TV")).await;
    assert_eq!(got, MalLookup::Unavailable);
}

/// Jikan proxies MyAnimeList and answers `504 BadResponseException` for as
/// long as MAL refuses it — observed for hours at a stretch, with
/// `/v4/anime/{id}` still serving from its own cache the whole time. Both
/// an outage and a bad match come out of `search_mal_id` as None, and only
/// one of the two is this module's fault, so the live tests say which
/// before they assert anything.
async fn require_live_search(http: &reqwest::Client, query: &str) {
    match fetch(http, query).await {
        Ok(r) => println!("jikan returned {} results for {query:?}", r.len()),
        Err(e) => panic!("jikan search is unavailable, so this proves nothing either way: {e}"),
    }
}

#[tokio::test]
#[ignore]
async fn live_entity_shape_still_deserializes_and_matches() {
    // `/v4/anime/{id}` serves the same entity object that fills the search
    // endpoint's `data[]`, out of Jikan's own store rather than through
    // MyAnimeList — so it keeps answering during the 504 outages that take
    // search down, and it is the only way to check the wire types against
    // real bytes while that is happening. The fixtures above are trimmed
    // copies of this payload; this is what catches them going stale.
    let http = reqwest::Client::new();
    let raw: serde_json::Value = http
        .get("https://api.jikan.moe/v4/anime/52991")
        .timeout(REQUEST_TIMEOUT)
        .send()
        .await
        .expect("jikan unreachable")
        .json()
        .await
        .expect("jikan sent something that is not json");
    let as_search = serde_json::json!({ "data": [raw.get("data").expect("no data")] });
    let found: Vec<AnimeEntity> = serde_json::from_value::<SearchResponse>(as_search).unwrap().data;

    println!("names: {:?}", names_of(&found[0]));
    println!("year: {:?} type: {:?}", entity_year(&found[0]), found[0].kind);
    assert_eq!(entity_year(&found[0]), Some(2023));
    let want = titles(&["Sousou no Frieren", "Frieren: Beyond Journey's End"]);
    assert_eq!(pick_match(&found, &want, Some(2023), Some("TV")), Some(52991));
}

#[tokio::test]
#[ignore]
async fn live_resolves_a_well_known_title_to_its_mal_id() {
    let http = reqwest::Client::new();
    require_live_search(&http, "Sousou no Frieren").await;
    let want = titles(&["Sousou no Frieren", "Frieren: Beyond Journey's End"]);
    let got = search_mal_id(&http, &want, Some(2023), Some("TV")).await;
    println!("Sousou no Frieren -> {got:?}");
    assert_eq!(got, MalLookup::Found(52991));
}

#[tokio::test]
#[ignore]
async fn live_does_not_answer_for_a_title_that_does_not_exist() {
    let http = reqwest::Client::new();
    require_live_search(&http, "Sousou no Frieren").await;
    let want = titles(&["Zzzz Not A Real Anime Title 12345"]);
    let got = search_mal_id(&http, &want, Some(2024), Some("TV")).await;
    println!("nonexistent title -> {got:?}");
    assert_eq!(got, MalLookup::NoMatch);
}

#[tokio::test]
#[ignore]
async fn live_separates_two_seasons_that_share_their_synonyms() {
    // The case the fixture tests model, run against whatever MAL actually
    // returns today: a search for season 2 must not come back with season
    // 1's id just because it is the more popular entry.
    let http = reqwest::Client::new();
    require_live_search(&http, "Jujutsu Kaisen 2nd Season").await;
    let s2 = titles(&["Jujutsu Kaisen 2nd Season", "JUJUTSU KAISEN Season 2"]);
    let got = search_mal_id(&http, &s2, Some(2023), Some("TV")).await;
    println!("Jujutsu Kaisen season 2 -> {got:?}");
    assert_eq!(got, MalLookup::Found(51009));
}
