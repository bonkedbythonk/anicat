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
    // The caller's whole reason for wanting this field: distinguishing "this
    // IS the manga, AniList said so" from "this just matched the search
    // text" so it knows an empty chapter list on the linked one is the real
    // answer, not a cue to keep trying other results.
    assert!(ranked[0].matches_anilist);
    assert!(!ranked[1].matches_anilist);
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

// --- sparse feeds and the MangaKatana fill ---------------------------------

fn row(number: &str, id: &str) -> ChapterRow {
    ChapterRow { number: number.into(), title: format!("Chapter {number}"), id: id.into(), pages: 1 }
}

fn run(from: u32, to: u32, id_prefix: &str) -> Vec<ChapterRow> {
    (from..=to).map(|n| row(&n.to_string(), &format!("{id_prefix}{n}"))).collect()
}

#[test]
fn a_feed_holding_only_the_newest_chapter_is_sparse() {
    // The One Piece shape as captured 2026-09-07: `total: 1`, chapter 1191,
    // `lastChapter: ""` because the title is ongoing. Nothing declares how
    // long the run is, so the only evidence is that it starts at 1191.
    let why = sparse_feed(&[row("1191", "md-1191")], None).expect("sparse");
    assert_eq!(why, SparseFeed { count: 1, lowest: 1191.0, expected: 1191.0 });
}

#[test]
fn a_feed_missing_chapter_one_is_sparse() {
    assert!(sparse_feed(&run(2, 40, "md-"), None).is_some());
    // Chapter 0 prologues and chapter 1 openers both count as a start.
    assert!(sparse_feed(&run(0, 40, "md-"), None).is_none());
    assert!(sparse_feed(&run(1, 40, "md-"), None).is_none());
}

#[test]
fn a_complete_run_is_not_sparse_even_with_half_chapters() {
    let mut rows = run(1, 20, "md-");
    rows.push(row("10.5", "md-10.5"));
    assert!(sparse_feed(&rows, None).is_none());
    assert!(sparse_feed(&rows, Some(20.0)).is_none());
}

#[test]
fn fewer_than_half_the_declared_run_is_sparse() {
    // MangaDex says the finished series has 30 chapters and holds 12.
    assert!(sparse_feed(&run(1, 12, "md-"), Some(30.0)).is_some());
    // Exactly half is the bar, not under it.
    assert!(sparse_feed(&run(1, 15, "md-"), Some(30.0)).is_none());
    // Without a declaration the highest chapter present stands in: 1-50 plus
    // 900-1000 is 151 rows of a run known to reach 1000.
    let mut rows = run(1, 50, "md-");
    rows.extend(run(900, 1000, "md-"));
    let why = sparse_feed(&rows, None).expect("sparse");
    assert_eq!((why.count, why.lowest, why.expected), (151, 1.0, 1000.0));
}

#[test]
fn an_empty_feed_is_not_sparse() {
    // The takedown case has its own path (the caller falls through to a
    // MangaKatana search); reporting it as sparse would run the fill on a
    // list with nothing to fill.
    assert!(sparse_feed(&[], None).is_none());
    assert!(sparse_feed(&[], Some(100.0)).is_none());
}

#[test]
fn merge_keeps_the_mangadex_row_on_a_collision_and_sorts_by_value() {
    let primary = vec![row("1191", "0d1c-uuid"), row("10", "md-10")];
    let fill = vec![
        row("1192", "https://mangakatana.com/manga/one-piece.49/c1192"),
        row("1191", "https://mangakatana.com/manga/one-piece.49/c1191"),
        // "10.0" is the chapter MangaDex wrote as "10"; a string key would
        // list it twice.
        row("10.0", "https://mangakatana.com/manga/one-piece.49/c10"),
        row("1", "https://mangakatana.com/manga/one-piece.49/c1"),
        row("2", "https://mangakatana.com/manga/one-piece.49/c2"),
    ];
    let merged = merge_chapter_lists(primary, fill);
    let ids: Vec<&str> = merged.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(
        ids,
        [
            "https://mangakatana.com/manga/one-piece.49/c1",
            "https://mangakatana.com/manga/one-piece.49/c2",
            "md-10",
            "0d1c-uuid",
            "https://mangakatana.com/manga/one-piece.49/c1192",
        ]
    );
}

#[test]
fn merge_with_nothing_to_add_is_the_original_order() {
    let primary = run(1, 5, "md-");
    let merged = merge_chapter_lists(primary.clone(), run(1, 5, "https://mangakatana.com/c"));
    assert_eq!(merged, primary);
}

#[test]
fn merge_keeps_a_row_without_a_number_at_the_end() {
    let primary = vec![row("2", "md-2")];
    let fill = vec![row("Oneshot", "https://mangakatana.com/manga/x/fc"), row("1", "https://mangakatana.com/manga/x/c1")];
    let ids: Vec<String> = merge_chapter_lists(primary, fill).into_iter().map(|r| r.id).collect();
    assert_eq!(ids, ["https://mangakatana.com/manga/x/c1", "md-2", "https://mangakatana.com/manga/x/fc"]);
}

fn summary(title: &str, id: &str) -> MangaSummary {
    MangaSummary { id: id.into(), title: title.into(), cover_image: String::new(), matches_anilist: false }
}

#[test]
fn the_fallback_is_picked_by_title_not_by_position() {
    // The three kinds of row the live search page for "One Piece" yields: a
    // sidebar title the scraper cannot tell from a hit, a spin-off, and the
    // manga itself. Placing the manga last proves position is ignored.
    let results = [
        summary("Grand Blue", "https://mangakatana.com/manga/grand-blue.17152"),
        summary("One Piece Episode Ace", "https://mangakatana.com/manga/one-piece-episode-ace.13306"),
        summary("ONE PIECE", "https://mangakatana.com/manga/one-piece.49"),
    ];
    let hit = pick_fallback(&results, &["One Piece".to_string()]).expect("hit");
    assert_eq!(hit.id, "https://mangakatana.com/manga/one-piece.49");
    assert!(pick_fallback(&results, &["One Piece Party".to_string()]).is_none());
    // Alternates count: the display title misses, the Japanese romaji hits.
    let romaji = ["Wan Pisu".to_string(), "One-Piece".to_string()];
    assert_eq!(pick_fallback(&results, &romaji).map(|h| h.id.as_str()), Some("https://mangakatana.com/manga/one-piece.49"));
    // An empty normalised title must not match an empty normalised title.
    assert!(pick_fallback(&[summary("...", "x")], &["!!!".to_string()]).is_none());
}

#[test]
fn every_known_title_is_offered_with_the_display_title_first() {
    let detail: MangaSingleResponse = serde_json::from_str(
        r#"{"data":{"id":"op","attributes":{
            "title":{"ja-ro":"One Piece"},
            "altTitles":[{"ja":"ONE PIECE"},{"en":"One Piece"},{"ru":"Van Pis"}],
            "lastChapter":""
        },"relationships":[]}}"#,
    )
    .unwrap();
    let attrs = &detail.data.attributes;
    let titles = all_titles(attrs, &pick_title(&attrs.title));
    assert_eq!(titles, ["One Piece", "ONE PIECE", "Van Pis"]);
    // An ongoing title declares nothing, and `detail` must not read "" as 0.
    assert_eq!(attrs.last_chapter.as_deref(), Some(""));
    assert_eq!(attrs.last_chapter.as_deref().and_then(chapter_value).filter(|n| *n > 0.0), None);
    assert_eq!(chapter_value("180"), Some(180.0));
    assert_eq!(chapter_value("0").filter(|n| *n > 0.0), None);
}

#[tokio::test]
#[ignore]
async fn live_one_piece_reads_from_chapter_one() {
    // AniList 30013. On 2026-09-07 MangaDex's English feed held one readable
    // chapter (1191) and MangaKatana's page 1198; the merged list must start
    // at chapter 1 and keep the MangaDex row where both have the chapter.
    let client = MangaDexClient::new(reqwest::Client::new());
    let hits = client.search("One Piece", Some(30013)).await.unwrap();
    let op = hits.iter().find(|h| h.matches_anilist).expect("no AniList-linked hit");
    let detail = client.detail(&op.id).await.unwrap();
    println!("title={} chapters={}", detail.title, detail.chapters.len());
    let from_mangadex = detail.chapters.iter().filter(|c| !c.id.starts_with("http")).count();
    println!("mangadex rows={from_mangadex} mangakatana rows={}", detail.chapters.len() - from_mangadex);
    assert!(detail.chapters.len() > 1000, "expected the full run, got {}", detail.chapters.len());
    assert_eq!(detail.chapters.first().map(|c| c.number.as_str()), Some("1"));
    let nums: Vec<f64> = detail.chapters.iter().map(|c| c.number.parse::<f64>().unwrap()).collect();
    assert!(nums.windows(2).all(|w| w[0] < w[1]), "chapter numbers repeat or are out of order");
    assert!(from_mangadex >= 1, "the MangaDex chapter was lost in the merge");
}
