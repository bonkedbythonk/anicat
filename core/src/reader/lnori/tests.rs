use super::*;

/// The sitemap's real shape, cut down to the entries the matching tests need.
/// Every slug and id here is copied from the live index.
const SITEMAP: &str = concat!(
    r#"<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">"#,
    "<url><loc>https://lnori.com/series/677/spice-and-wolf</loc></url>",
    "<url><loc>https://lnori.com/series/10041/ishura</loc></url>",
    "<url><loc>https://lnori.com/series/13305/mushoku-tensei-jobless-reincarnation-recollections</loc></url>",
    "<url><loc>https://lnori.com/series/14199/mushoku-tensei-jobless-reincarnation-special-book</loc></url>",
    "<url><loc>https://lnori.com/series/3336/mushoku-tensei-jobless-reincarnation</loc></url>",
    "<url><loc>https://lnori.com/series/10731/konosuba-gods-blessing-on-this-wonderful-world-memorial-fan-book</loc></url>",
    "<url><loc>https://lnori.com/series/3079/konosuba-gods-blessing-on-this-wonderful-world</loc></url>",
    "<url><loc>https://lnori.com/series/6581/ascendance-of-a-bookworm-fanbook</loc></url>",
    "<url><loc>https://lnori.com/series/8813/ascendance-of-a-bookworm-royal-academy-stories-first-year</loc></url>",
    "<url><loc>https://lnori.com/series/4239/ascendance-of-a-bookworm-ill-do-anything-to-become-a-librarian</loc></url>",
    "<url><loc>https://lnori.com/series/17062/another</loc></url>",
    "<url><loc>https://lnori.com/series/2993/the-rising-of-the-shield-hero</loc></url>",
    "</urlset>",
);

fn index() -> Vec<SeriesEntry> {
    parse_series_sitemap(SITEMAP)
}

fn matched(titles: &[&str]) -> Option<String> {
    let owned: Vec<String> = titles.iter().map(|s| s.to_string()).collect();
    best_series_match(&index(), &owned).map(|e| e.url.clone())
}

#[test]
fn sitemap_entries_carry_id_slug_and_a_fetchable_url() {
    let entries = index();
    assert_eq!(entries.len(), 12);
    let first = &entries[0];
    assert_eq!(first.id, 677);
    assert_eq!(first.slug, "spice-and-wolf");
    assert_eq!(first.url, "https://lnori.com/series/677/spice-and-wolf");
}

#[test]
fn titles_are_slugified_the_way_lnori_writes_them() {
    // The apostrophe vanishes rather than becoming a separator, and a colon,
    // an exclamation mark and a trailing space all collapse to nothing.
    assert_eq!(slugify("KonoSuba: God's Blessing on This Wonderful World! "), "konosuba-gods-blessing-on-this-wonderful-world");
    assert_eq!(slugify("Re:ZERO -Starting Life in Another World-"), "re-zero-starting-life-in-another-world");
    assert_eq!(slugify("86 -Eighty Six-"), "86-eighty-six");
    assert_eq!(slugify("   "), "");
}

#[test]
fn an_exact_match_beats_a_spinoff_that_merely_contains_the_title() {
    // The bug this ladder exists for: the two spinoffs sit *ahead* of the
    // parent in the file, so a first-hit-wins scan serves "Recollections" to
    // someone who opened the main series.
    assert_eq!(
        matched(&["Mushoku Tensei: Jobless Reincarnation", "Mushoku Tensei - Isekai Ittara Honki Dasu"]),
        Some("https://lnori.com/series/3336/mushoku-tensei-jobless-reincarnation".to_string())
    );
    assert_eq!(
        matched(&["KonoSuba: God's Blessing on This Wonderful World!"]),
        Some("https://lnori.com/series/3079/konosuba-gods-blessing-on-this-wonderful-world".to_string())
    );
}

#[test]
fn the_spinoffs_own_title_still_resolves_to_the_spinoff() {
    // Demoting companion material must not make it unreachable — an AniList
    // entry for the spinoff is a legitimate thing to open.
    assert_eq!(
        matched(&["Mushoku Tensei: Jobless Reincarnation - Recollections"]),
        Some("https://lnori.com/series/13305/mushoku-tensei-jobless-reincarnation-recollections".to_string())
    );
}

#[test]
fn a_prefix_match_picks_the_parent_series_not_the_shortest_slug() {
    // No bare `ascendance-of-a-bookworm` exists, so this can only be reached
    // by prefix. The shortest candidate is the fanbook and the right answer is
    // the longest of the three.
    assert_eq!(
        matched(&["Ascendance of a Bookworm"]),
        Some("https://lnori.com/series/4239/ascendance-of-a-bookworm-ill-do-anything-to-become-a-librarian".to_string())
    );
}

#[test]
fn an_english_title_outranks_a_romaji_one_at_the_same_tier() {
    let titles = vec!["Ishura".to_string(), "Spice and Wolf".to_string()];
    assert_eq!(best_series_match(&index(), &titles).map(|e| e.id), Some(10041));
}

#[test]
fn nothing_recognisable_returns_none_rather_than_a_near_miss() {
    assert!(matched(&["A Novel Lnori Has Never Carried"]).is_none());
    // "Another" is a one-token series in the index; a longer title that merely
    // contains the word must not resolve to it.
    assert!(matched(&["Reflections on Another Winter Morning"]).is_none());
    assert!(matched(&[""]).is_none());
}

#[test]
fn articles_are_only_dropped_on_both_sides_at_once() {
    // Lnori keeps articles in its slugs, so this tier is an equality, not a
    // licence to match a different series that happens to share the rest.
    assert_eq!(
        matched(&["Rising of the Shield Hero"]),
        Some("https://lnori.com/series/2993/the-rising-of-the-shield-hero".to_string())
    );
    assert_eq!(without_articles("the-rising-of-the-shield-hero"), "rising-of-shield-hero");
}

/// The three anchors a series page gives each volume: the read button, the
/// cover, and the title. Markup shape copied from the live page; the second
/// volume is listed before the first to prove document order is not used.
const SERIES_PAGE: &str = r#"
<h1>Spice and Wolf</h1>
<div class="card">
  <a href="/book/2983/spice-and-wolf-vol-2" class="btn-read"><svg viewBox="0 0 24 24"><path d="M2 3h6"></path></svg><span class="read-label">Start Reading</span></a>
  <figure><a href="/book/2983/spice-and-wolf-vol-2" class="stretched-link" aria-label="Volume 2"><img src="https://cdn.lnori.com/cover/2983.webp" alt="Volume 2"></a></figure>
  <header class="popup-header"><h3><a href="https://lnori.com/book/2983/spice-and-wolf-vol-2">Volume 2</a></h3></header>
</div>
<div class="card">
  <a href="/book/2787/spice-and-wolf-vol-1" class="btn-read"><svg viewBox="0 0 24 24"><path d="M2 3h6"></path></svg><span class="read-label">Start Reading</span></a>
  <figure><a href="/book/2787/spice-and-wolf-vol-1" class="stretched-link" aria-label="Volume 1"><img src="https://cdn.lnori.com/cover/2787.webp" alt="Volume 1"></a></figure>
  <header class="popup-header"><h3><a href="https://lnori.com/book/2787/spice-and-wolf-vol-1">Volume 1</a></h3></header>
</div>
"#;

#[test]
fn volumes_are_deduplicated_ordered_and_named_from_their_labels() {
    let volumes = parse_volume_links(SERIES_PAGE);
    assert_eq!(volumes.len(), 2, "six anchors describe two volumes");
    assert_eq!(volumes[0].index, 1);
    assert_eq!(volumes[0].title, "Volume 1");
    assert_eq!(volumes[0].url, "https://lnori.com/book/2787/spice-and-wolf-vol-1");
    assert_eq!(volumes[0].volume_name.as_deref(), Some("Volume 1"));
    assert_eq!(volumes[1].index, 2);
    assert_eq!(volumes[1].url, "https://lnori.com/book/2983/spice-and-wolf-vol-2");
}

#[test]
fn an_absolute_href_is_the_same_volume_as_a_relative_one() {
    // A third of the live page's `/book/` links are absolute. Treating the two
    // forms as different volumes would list every book twice.
    let html = r#"
        <a href="/book/2787/spice-and-wolf-vol-1" aria-label="Volume 1"><img src="c.webp"></a>
        <a href="https://lnori.com/book/2787/spice-and-wolf-vol-1">Volume 1</a>
    "#;
    assert_eq!(parse_volume_links(html).len(), 1);
}

#[test]
fn a_slug_that_states_no_volume_number_falls_back_to_the_book_id() {
    let html = r#"
        <a href="/book/10060/invaders-of-the-rokujouma-volume-12" aria-label="Volume 12">x</a>
        <a href="/book/10023/ninja-slayer-volume-03-chapter-01" aria-label="Book 3-1">x</a>
        <a href="/book/9000/some-series-side-story" aria-label="Side Story">x</a>
    "#;
    let volumes = parse_volume_links(html);
    assert_eq!(volumes.len(), 3);
    // `-volume-03-` parses to 3 and `-volume-12` to 12, so the numbered pair
    // sorts ahead of the one with no number at all.
    assert_eq!(volumes[0].title, "Book 3-1");
    assert_eq!(volumes[1].title, "Volume 12");
    assert_eq!(volumes[2].title, "Side Story");
}

#[test]
fn a_read_button_never_wins_the_volume_label() {
    let html = r#"
        <a href="/book/2787/spice-and-wolf-vol-1" class="btn-read"><span>Start Reading</span></a>
        <a href="/book/2787/spice-and-wolf-vol-1" aria-label="Volume 1"><img src="c.webp"></a>
    "#;
    assert_eq!(parse_volume_links(html)[0].title, "Volume 1");
}

/// A volume page in miniature. The section ids, the nesting and the class
/// names are the live shapes; the prose is written for this test.
const BOOK_PAGE: &str = r##"
<a href="#main-content" class="skip-link">Skip to content</a>
<header class="toc-sidebar-header"><div class="book-info"><h1 id="book-title">Example Novel, Vol. 1</h1><address id="book-author">A. Writer</address></div></header>
<nav class="toc-view" id="toc-list" aria-label="Table of contents"><ul>
<li><a href="#page01" title="Cover">Cover</a></li>
<li><a href="#page08" title="Prologue">Prologue</a></li>
<li><a href="#page10" title="Chapter One">Chapter One</a></li>
<li><a href="#page16" title="Chapter Two">Chapter Two</a></li>
</ul></nav>
<a href="#top" class="back-to-top">Top</a>
<main id="main-content"><article class="content-body text-base">
<section class="chapter" id="page01"><div class="cover_image"><picture><img src="https://img.lnori.com/1-01.jpg" alt="Cover - 01"></picture></div></section>
<hr class="chapter-separator">
<section class="chapter" id="page08"><section class="body-rw" id="chapter001"><h2 class="chapter-number"><span>P<span class="small-caps">ROLOGUE</span></span></h2></section></section>
<hr class="chapter-separator">
<section class="chapter" id="page09"><section class="body-rw" id="chapter002"><p class="noindent">The prologue&rsquo;s only paragraph.</p></section></section>
<hr class="chapter-separator">
<section class="chapter" id="page10"><section class="body-rw" id="chapter003"><h2 class="chapter-number"><span>C<span class="small-caps">HAPTER</span> O<span class="small-caps">NE</span></span></h2></section></section>
<hr class="chapter-separator">
<section class="chapter" id="page11"><section class="body-rw" id="chapter004"><p class="noindent">The first paragraph of chapter
one, wrapped across two source lines.</p><p>A second paragraph with an <em>emphasis</em> inside it.</p></section></section>
<hr class="chapter-separator">
<section class="chapter" id="page16"><section class="body-rw" id="chapter005"><h2>Chapter Two</h2><p>Chapter two begins.</p></section></section>
</article></main>
<footer id="bottombar-container"></footer>
<script type="module">const THUMB_CANVAS = document.createElement("canvas");</script>
"##;

#[test]
fn the_table_of_contents_is_read_from_the_nav_and_nothing_else() {
    // The page's skip link and back-to-top anchor are also `href="#..."`.
    // Scanning the document instead of the nav would file them as chapters.
    let toc = parse_toc(BOOK_PAGE, "https://lnori.com/book/1/example-novel-vol-1");
    assert_eq!(toc.len(), 4);
    assert_eq!(toc[0].title, "Cover");
    assert_eq!(toc[2].title, "Chapter One");
    assert_eq!(toc[2].index, 3);
    assert_eq!(toc[2].url, "https://lnori.com/book/1/example-novel-vol-1#page10");
    assert_eq!(toc[2].volume_name.as_deref(), Some("Example Novel, Vol. 1"));
}

#[test]
fn a_fragment_on_the_book_url_does_not_reach_the_chapter_urls() {
    let toc = parse_toc(BOOK_PAGE, "https://lnori.com/book/1/example-novel-vol-1#page10");
    assert_eq!(toc[0].url, "https://lnori.com/book/1/example-novel-vol-1#page01");
}

#[test]
fn a_chapter_spans_every_section_up_to_the_next_toc_entry() {
    // The correction to the Python scraper. `#page10` on its own is a heading
    // and nothing else — measured at 499 bytes on the live volume, against
    // 27KB in `page11` — so a single-section slice returns a chapter title
    // with no chapter under it.
    let slice = slice_section(BOOK_PAGE, "page10").expect("page10 is a section");
    assert!(slice.contains(r#"id="page11""#), "chapter one must swallow page11");
    assert!(!slice.contains(r#"id="page16""#), "and must stop at chapter two");

    let text = html_to_text(slice);
    assert!(text.contains("The first paragraph of chapter one, wrapped across two source lines."));
    assert!(text.contains("A second paragraph with an emphasis inside it."));
    assert!(!text.contains("Chapter two begins."));
}

#[test]
fn the_prologue_reaches_the_page_that_holds_its_prose() {
    let text = html_to_text(slice_section(BOOK_PAGE, "page08").expect("page08 is a section"));
    assert!(text.contains("The prologue\u{2019}s only paragraph."));
    assert!(!text.contains("CHAPTER"));
}

#[test]
fn the_last_chapter_stops_at_the_end_of_the_article() {
    // Without the `</article>` bound the afterword of every book ends with the
    // page's footer and its inline module script.
    let text = html_to_text(slice_section(BOOK_PAGE, "page16").expect("page16 is a section"));
    assert!(text.contains("Chapter two begins."));
    assert!(!text.contains("THUMB_CANVAS"));
}

#[test]
fn a_missing_anchor_is_an_error_not_an_empty_chapter() {
    assert!(slice_section(BOOK_PAGE, "page99").is_none());
}

#[test]
fn an_image_only_section_yields_a_title_and_no_text() {
    // Cover and Insert are the first two entries of every volume. They must
    // not read as a broken source.
    let slice = slice_section(BOOK_PAGE, "page01").expect("page01 is a section");
    assert_eq!(html_to_text(slice), "");
}

#[test]
fn paragraphs_survive_as_blank_line_separated_prose() {
    // A `<br>` is a break the book asked for and stays a single newline; a
    // paragraph break becomes a blank line.
    let html = r#"<p>One.</p><p>Two <em>emphasised</em> here.</p><p>Three.<br>Four.</p>"#;
    assert_eq!(html_to_text(html), "One.\n\nTwo emphasised here.\n\nThree.\nFour.");
}

#[test]
fn only_lnori_series_and_book_urls_are_claimed() {
    assert!(LnoriClient::can_handle("https://lnori.com/series/677/spice-and-wolf"));
    assert!(LnoriClient::can_handle("https://lnori.com/book/2787/spice-and-wolf-vol-1#page10"));
    assert!(!LnoriClient::can_handle("https://lnori.com/"));
    assert!(!LnoriClient::can_handle("https://ncode.syosetu.com/n2267be/"));
    assert!(!LnoriClient::can_handle("https://notlnori.example.org/series/1/x?lnori.com/book/"));
}

#[test]
fn the_async_surface_stays_send_for_uniffis_export() {
    // Compile-time only. Every method here takes a `std::sync::Mutex` around a
    // cache and then awaits a fetch; a guard left alive across the suspend
    // point makes the future `!Send`, and uniffi's async export refuses it —
    // as an error in `ffi.rs`, not here, which is the confusing part.
    fn assert_send<T: Send>(_: T) {}
    let client = LnoriClient::new(reqwest::Client::new());
    assert_send(client.find_series(&[]));
    assert_send(client.volumes(""));
    assert_send(client.volume_chapters(""));
    assert_send(client.chapter_content("", ""));
}

// --- live tests, ignored by default -----------------------------------------

#[tokio::test]
#[ignore = "hits lnori.com"]
async fn live_resolves_a_series_and_reads_its_first_chapter() {
    let client = LnoriClient::new(reqwest::Client::new());
    let series = client
        .find_series(&["Spice and Wolf".to_string(), "Ookami to Koushinryou".to_string()])
        .await
        .unwrap()
        .expect("spice and wolf is carried");
    assert_eq!(series, "https://lnori.com/series/677/spice-and-wolf");

    let volumes = client.volumes(&series).await.unwrap();
    assert!(volumes.len() >= 24, "24 volumes were listed when this was written");

    let chapters = client.volume_chapters(&volumes[0].url).await.unwrap();
    let prose = chapters
        .iter()
        .find(|c| c.title.starts_with("Chapter"))
        .expect("a volume has chapters");
    let anchor = prose.url.split('#').nth(1).unwrap().to_string();
    let content = client.chapter_content(&volumes[0].url, &anchor).await.unwrap();
    assert!(content.text.len() > 5_000, "a chapter is not a heading: {}", content.text.len());
}

#[tokio::test]
#[ignore = "hits lnori.com"]
async fn live_declines_a_title_lnori_does_not_carry() {
    let client = LnoriClient::new(reqwest::Client::new());
    let found = client
        .find_series(&["A Light Novel That Does Not Exist Anywhere".to_string()])
        .await
        .unwrap();
    assert!(found.is_none());
}

#[test]
fn repeated_title_paragraphs_are_dropped() {
    let body = "Chapter 1: Is This Another World?\n\nChapter 1:\nIs This Another World?\n\nWhen I opened my eyes, the first thing I saw was dazzling light.";
    assert_eq!(
        strip_repeated_title(body, "Chapter 1: Is This Another World?"),
        "When I opened my eyes, the first thing I saw was dazzling light."
    );
}

#[test]
fn a_title_only_section_keeps_its_one_paragraph() {
    assert_eq!(strip_repeated_title("Color Inserts", "Color Inserts"), "Color Inserts");
}

#[test]
fn prose_that_merely_starts_with_the_title_word_survives() {
    let body = "Chapter 1 was the part he remembered.\n\nThe rest he did not.";
    assert_eq!(strip_repeated_title(body, "Chapter 1: Is This Another World?"), body);
}

#[test]
fn a_drop_cap_that_is_a_word_on_its_own_keeps_its_space() {
    // The source leaves no space at all here: the gap on the page is the 3em
    // glyph's side bearing, and the only mark of the word boundary is the
    // empty span between the two runs.
    let html = r#"<p><span style="font-size: 3.00em;">I</span><span style="font-size: 1.00em;"></span><span>was a shut-in.</span></p>"#;
    assert_eq!(html_to_text(html), "I was a shut-in.");
}

#[test]
fn a_drop_cap_that_continues_its_word_is_left_joined() {
    let html = r#"<p><span style="font-size: 3.00em;">W</span><span>hen I opened my eyes.</span></p>"#;
    assert_eq!(html_to_text(html), "When I opened my eyes.");
}
