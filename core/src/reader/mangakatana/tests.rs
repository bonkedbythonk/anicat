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
        <div class="chapter"><a href="https://mangakatana.com/manga/x.1/extra">Extra Special</a></div>
    "#;
    assert!(parse_chapter_list(html).is_empty());
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
    assert!(detail.chapters.len() > 100, "expected the full run, got {}", detail.chapters.len());
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
