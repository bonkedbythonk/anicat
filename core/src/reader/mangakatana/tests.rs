use super::*;

#[test]
fn single_result_redirect_is_parsed_as_one_manga() {
    // A strong-enough query redirects straight to the manga page instead of
    // a results list — this is the shape `search()` gets for those.
    let html = r#"
        <div class="cover">
            <picture><source srcset="c.webp"><img src="https://mangakatana.com/imgs/cover/c.jpg" alt="[Cover]"></picture>
        </div>
        <h1 class="heading">Tomodachi Game</h1>
    "#;
    let out = parse_single_result(html, "https://mangakatana.com/manga/tomodachi-game.3175");
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].title, "Tomodachi Game");
    assert_eq!(out[0].cover_image, "https://mangakatana.com/imgs/cover/c.jpg");
    assert!(!out[0].matches_anilist);
}

#[test]
fn search_results_pair_each_title_with_its_own_cover() {
    // Two items back to back: the cover-recovery window must not bleed the
    // first item's cover into the second, or every result but the first
    // shows the wrong thumbnail.
    let html = r#"
        <div class="item"><div class="media"><div class="wrap_img">
            <a href="https://mangakatana.com/manga/a.1"><img src="https://mangakatana.com/imgs/a.jpg"></a>
        </div></div><div class="text"><h3 class="title">
            <a href="https://mangakatana.com/manga/a.1" target="_blank">Manga A</a><span> - 2 chapter(s)</span>
        </h3></div></div>
        <div class="item"><div class="media"><div class="wrap_img">
            <a href="https://mangakatana.com/manga/b.2"><img src="https://mangakatana.com/imgs/b.jpg"></a>
        </div></div><div class="text"><h3 class="title">
            <a href="https://mangakatana.com/manga/b.2" target="_blank">Manga B</a><span> - 5 chapter(s)</span>
        </h3></div></div>
    "#;
    let out = parse_search_results(html);
    assert_eq!(out.len(), 2);
    assert_eq!((out[0].title.as_str(), out[0].cover_image.as_str()), ("Manga A", "https://mangakatana.com/imgs/a.jpg"));
    assert_eq!((out[1].title.as_str(), out[1].cover_image.as_str()), ("Manga B", "https://mangakatana.com/imgs/b.jpg"));
    assert!(out.iter().all(|m| !m.matches_anilist));
}

#[test]
fn chapter_list_is_reordered_ascending_and_entities_decoded() {
    // The site lists newest first and leaves title text HTML-escaped —
    // readers expect oldest-to-newest and plain text.
    let html = r#"
        <div class="chapters"><table><tbody>
        <tr><td><div class="chapter"><a href="https://mangakatana.com/manga/x.1/c2">Chapter 2: The &quot;Trial&quot;</a></div></td></tr>
        <tr><td><div class="chapter"><a href="/manga/x.1/c1">Chapter 1: Start</a></div></td></tr>
        </tbody></table></div>
    "#;
    let rows = parse_chapter_list(html);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].number, "1");
    assert_eq!(rows[1].number, "2");
    assert_eq!(rows[1].title, "Chapter 2: The \"Trial\"");
    assert_eq!(rows[1].id, "https://mangakatana.com/manga/x.1/c2");
    // A relative href (no scheme) must still resolve to a fetchable URL.
    assert_eq!(rows[0].id, "https://mangakatana.com/manga/x.1/c1");
}

#[test]
fn chapters_missing_a_parseable_number_are_dropped_not_guessed() {
    let html = r#"
        <div class="chapters"><table><tbody>
        <tr><td><div class="chapter"><a href="https://mangakatana.com/manga/x.1/extra">Extra Special</a></div></td></tr>
        </tbody></table></div>
    "#;
    assert!(parse_chapter_list(html).is_empty());
}

#[test]
fn the_related_manga_sidebar_does_not_contribute_chapters() {
    // The regression this file exists for. MangaKatana's related-manga
    // sidebar reuses `class="chapter"` for anchors pointing at other
    // titles, and they sit *after* the real table — so once the list was
    // flipped to ascending they landed at the front, and the first row the
    // reader offered was chapter 9.5 of a manga nobody had opened.
    let html = r#"
        <div class="chapters"><table><tbody>
        <tr><td><div class="chapter"><a href="https://mangakatana.com/manga/tomodachi-game.3175/c2">Chapter 2</a></div></td></tr>
        <tr><td><div class="chapter"><a href="https://mangakatana.com/manga/tomodachi-game.3175/c1">Chapter 1</a></div></td></tr>
        </tbody></table></div>
        <div class="uk-panel">
        <div class="chapter"><a href="https://mangakatana.com/manga/bloody-junkie.7490/c9.5">Chapter 9.5</a></div>
        <div class="chapter"><a href="https://mangakatana.com/manga/kakegurui-twin.16848/c80">Chapter 80</a></div>
        </div>
    "#;
    let rows = parse_chapter_list(html);
    assert_eq!(rows.len(), 2);
    assert!(
        rows.iter().all(|r| r.id.contains("/tomodachi-game.3175/")),
        "a foreign manga's chapter got in: {:?}",
        rows.iter().map(|r| &r.id).collect::<Vec<_>>()
    );
    assert_eq!(rows[0].number, "1");
    assert_eq!(rows[1].number, "2");
}

#[test]
fn a_page_without_the_chapter_table_yields_nothing_rather_than_the_whole_document() {
    let html = r#"
        <h1 class="heading">Some Manga</h1>
        <div class="chapter"><a href="https://mangakatana.com/manga/other.1/c5">Chapter 5</a></div>
    "#;
    assert!(parse_chapter_list(html).is_empty());
}

#[test]
fn ordering_is_numeric_not_lexicographic() {
    // The parsed number is a String on `ChapterRow` because it crosses the
    // FFI exactly as the site wrote it; comparing those strings puts "10"
    // ahead of "9" and hands the reader a second kind of mixed-up list.
    let html = r#"
        <div class="chapters"><table><tbody>
        <tr><td><div class="chapter"><a href="/manga/x.1/c9">Chapter 9</a></div></td></tr>
        <tr><td><div class="chapter"><a href="/manga/x.1/c10">Chapter 10</a></div></td></tr>
        <tr><td><div class="chapter"><a href="/manga/x.1/c100">Chapter 100</a></div></td></tr>
        </tbody></table></div>
    "#;
    let rows = parse_chapter_list(html);
    assert_eq!(rows.iter().map(|r| r.number.as_str()).collect::<Vec<_>>(), vec!["9", "10", "100"]);
}

#[test]
fn ordering_holds_whichever_way_the_site_sorted_the_table() {
    // The page carries a sort toggle (`id="reverse_order"`), so oldest-first
    // markup is a shape that reaches this parser too — the old blind
    // `reverse()` turned exactly that case upside down.
    let ascending = r#"
        <div class="chapters"><table><tbody>
        <tr><td><div class="chapter"><a href="/manga/x.1/c1">Chapter 1</a></div></td></tr>
        <tr><td><div class="chapter"><a href="/manga/x.1/c2">Chapter 2</a></div></td></tr>
        </tbody></table></div>
    "#;
    let rows = parse_chapter_list(ascending);
    assert_eq!(rows.iter().map(|r| r.number.as_str()).collect::<Vec<_>>(), vec!["1", "2"]);
}

#[test]
fn real_chapter_name_shapes_parse_to_the_chapter_and_not_a_number_in_the_title() {
    // Every one of these is a name captured from the live Tomodachi Game
    // page. The debt one is the trap: "10.8" appears inside the title, so a
    // parse that takes the last number rather than the first `Chapter N`
    // token files chapter 13 between 10 and 11.
    let cases = [
        ("Chapter 127.5: Epilogue: The Paths They Each Followed...", "127.5"),
        ("Chapter 127 [END]", "127"),
        ("Chapter 7.1: Special 1: Ken-chan, Are You Okay?", "7.1"),
        ("Chapter 13: You Guys' Group C's Current Debt Total is \"10.8\" Million Yen...", "13"),
        ("Vol.02 Chapter 1", "1"),
    ];
    for (title, want) in cases {
        let got = parse_chapter_number(title).unwrap_or_else(|| panic!("no number in {title:?}"));
        assert_eq!(got.0, want, "for {title:?}");
    }
    assert_eq!(parse_chapter_number("Extra Special"), None);
}

#[test]
fn volume_breaks_a_tie_between_chapters_that_share_a_number() {
    // "Secret Chaser" numbers per volume: both rows parse to chapter 1, and
    // a stable sort with no tiebreak leaves them in document order, which is
    // newest-first — volume 2 offered ahead of volume 1.
    let html = r#"
        <div class="chapters"><table><tbody>
        <tr><td><div class="chapter"><a href="/manga/secret-chaser.14238/v2c1">Vol.02 Chapter 1</a></div></td></tr>
        <tr><td><div class="chapter"><a href="/manga/secret-chaser.14238/v1c1">Vol.01 Chapter 1 : The Red Penguin</a></div></td></tr>
        </tbody></table></div>
    "#;
    let rows = parse_chapter_list(html);
    assert_eq!(rows.len(), 2);
    assert!(rows[0].id.ends_with("/v1c1"), "volume 1 must come first, got {}", rows[0].id);
    assert!(rows[1].id.ends_with("/v2c1"));
}

#[test]
fn manga_page_falls_back_to_bare_h1_when_no_heading_class() {
    let html = r#"<h1>Some Title</h1><div class="cover"><img src="https://mangakatana.com/imgs/c.jpg"></div>"#;
    let (title, cover, _) = parse_manga_page(html);
    assert_eq!(title, "Some Title");
    assert_eq!(cover, "https://mangakatana.com/imgs/c.jpg");
}

#[test]
fn chapter_pages_prefers_the_js_array_over_stray_page_images() {
    let html = r#"
        <img src="https://mangakatana.com/site-logo.png">
        <script>var pages=['https://cdn/1.jpg','https://cdn/2.jpg','https://cdn/3.jpg'];</script>
    "#;
    let pages = parse_chapter_pages(html);
    assert_eq!(pages, vec!["https://cdn/1.jpg", "https://cdn/2.jpg", "https://cdn/3.jpg"]);
}

#[test]
fn chapter_pages_falls_back_to_the_imgs_container_when_no_array_is_found() {
    let html = r#"<div id="imgs"><img src="https://cdn/1.jpg"><img src="https://cdn/2.jpg"></div>"#;
    let pages = parse_chapter_pages(html);
    assert_eq!(pages, vec!["https://cdn/1.jpg", "https://cdn/2.jpg"]);
}

#[tokio::test]
#[ignore]
async fn live_tomodachi_game_has_full_chapters_on_mangakatana() {
    let client = MangaKatanaClient::new(reqwest::Client::new());
    let hits = client.search("Tomodachi Game").await.unwrap();
    assert!(!hits.is_empty(), "no search hits");
    let detail = client.detail(&hits[0].id).await.unwrap();
    println!("title={} chapters={}", detail.title, detail.chapters.len());
    println!(
        "first={:?} last={:?}",
        detail.chapters.first().map(|c| &c.title),
        detail.chapters.last().map(|c| &c.title)
    );
    assert!(detail.chapters.len() > 100, "expected the full run, got {}", detail.chapters.len());

    // A count alone passed straight through the sidebar bug: 151 anchors for
    // a 131-chapter manga still cleared "> 100". These are the two properties
    // that actually broke.
    for c in &detail.chapters {
        assert!(c.id.starts_with(&hits[0].id), "chapter from another manga: {} ({})", c.title, c.id);
    }
    let nums: Vec<f64> = detail.chapters.iter().map(|c| c.number.parse::<f64>().unwrap()).collect();
    assert!(
        nums.windows(2).all(|w| w[0] <= w[1]),
        "chapter numbers are not ascending: {nums:?}"
    );
}

#[tokio::test]
#[ignore]
async fn live_chapter_pages_resolve_to_image_urls() {
    let client = MangaKatanaClient::new(reqwest::Client::new());
    let hits = client.search("Tomodachi Game").await.unwrap();
    let detail = client.detail(&hits[0].id).await.unwrap();
    let first = detail.chapters.first().expect("no chapters");
    let pages = client.chapter_pages(&first.id).await.unwrap();
    println!("chapter {} pages={} first={:?}", first.number, pages.len(), pages.first());
    assert!(!pages.is_empty());
}
