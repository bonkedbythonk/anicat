use super::*;

fn manga_list(json: &str) -> Vec<MangaEntity> {
    serde_json::from_str::<MangaListResponse>(json).unwrap().data
}

#[test]
fn an_anilist_linked_result_outranks_a_better_title_match() {
    // The real failure this guards: MangaDex's relevance order puts a
    // same-named spin-off first, and the reader opens the wrong series.
    let items = manga_list(
        r#"{"data":[
            {"id":"wrong","attributes":{"title":{"en":"Berserk"},"links":{"al":"999"}},
             "relationships":[]},
            {"id":"right","attributes":{"title":{"en":"Berserk (Colored)"},"links":{"al":"30002"}},
             "relationships":[{"type":"cover_art","attributes":{"fileName":"c.jpg"}}]}
        ]}"#,
    );
    let ranked = rank_search_results(&items, Some(30002));
    assert_eq!(ranked[0].id, "right");
    assert_eq!(ranked[0].cover_image, "https://uploads.mangadex.org/covers/right/c.jpg.512.jpg");
    assert_eq!(ranked.len(), 2);
}

#[test]
fn no_anilist_id_leaves_relevance_order_untouched() {
    let items = manga_list(
        r#"{"data":[{"id":"a","attributes":{"title":{"en":"A"}},"relationships":[]},
                    {"id":"b","attributes":{"title":{"en":"B"}},"relationships":[]}]}"#,
    );
    let ids: Vec<_> = rank_search_results(&items, None).into_iter().map(|m| m.id).collect();
    assert_eq!(ids, ["a", "b"]);
}

#[test]
fn title_falls_back_through_romaji_to_any_language() {
    let mut t = HashMap::new();
    t.insert("ja".to_string(), "beruseruku".to_string());
    assert_eq!(pick_title(&t), "beruseruku");
    t.insert("ja-ro".to_string(), "Berserk".to_string());
    assert_eq!(pick_title(&t), "Berserk");
    t.insert("en".to_string(), "Berserk EN".to_string());
    assert_eq!(pick_title(&t), "Berserk EN");
    assert_eq!(pick_title(&HashMap::new()), "Unknown");
}

fn feed(json: &str) -> Vec<ChapterEntity> {
    serde_json::from_str::<ChapterListResponse>(json).unwrap().data
}

#[test]
fn duplicate_uploads_collapse_to_the_longest_and_sort_numerically() {
    // "10" must not sort before "9", and the 3-page credits-only upload of
    // chapter 9 must not win over the real 40-page one.
    let items = feed(
        r#"{"data":[
            {"id":"c10","attributes":{"chapter":"10","pages":20}},
            {"id":"c9-short","attributes":{"chapter":"9","pages":3}},
            {"id":"c9-full","attributes":{"chapter":"9","pages":40,"title":"Guardians"}},
            {"id":"c9-5","attributes":{"chapter":"9.5","pages":12}}
        ]}"#,
    );
    let rows = collapse_feed(&items);
    let ids: Vec<_> = rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, ["c9-full", "c9-5", "c10"]);
    assert_eq!(rows[0].title, "Chapter 9: Guardians");
    assert_eq!(rows[2].title, "Chapter 10");
    assert_eq!(rows[1].number, "9.5");
}

#[test]
fn unfetchable_chapters_are_dropped() {
    let items = feed(
        r#"{"data":[
            {"id":"ext","attributes":{"chapter":"1","pages":5,"externalUrl":"https://elsewhere"}},
            {"id":"empty","attributes":{"chapter":"2","pages":0}},
            {"id":"ok","attributes":{"chapter":"3","pages":18}}
        ]}"#,
    );
    let rows = collapse_feed(&items);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, "ok");
}

#[test]
fn a_oneshot_with_no_chapter_number_is_still_readable() {
    let items = feed(r#"{"data":[{"id":"os","attributes":{"pages":45,"title":"The Fall"}}]}"#);
    let rows = collapse_feed(&items);
    assert_eq!(rows.len(), 1);
    assert_eq!((rows[0].number.as_str(), rows[0].title.as_str()), ("1", "Chapter 1: The Fall"));
}

#[test]
fn query_encoding_survives_punctuation_and_unicode() {
    assert_eq!(urlencode("Fate/stay night"), "Fate%2Fstay+night");
    assert_eq!(urlencode("Re:Zero"), "Re%3AZero");
    assert_eq!(urlencode("\u{30d9}\u{30eb}"), "%E3%83%99%E3%83%AB");
}
