use super::*;

fn item(number: &str, url: &str) -> ChapterItem {
    ChapterItem { title: format!("Chapter {number}"), number: number.to_string(), url: url.to_string() }
}

#[test]
fn chapters_come_out_oldest_first_by_number_not_by_text() {
    // The API lists newest first; "10" sorts ahead of "9" as text.
    let rows = chapter_rows("slug", vec![item("10", "10.2"), item("9", "9.1"), item("9.5", "9.5.3")]);
    let numbers: Vec<_> = rows.iter().map(|r| r.number.as_str()).collect();
    assert_eq!(numbers, ["9", "9.5", "10"]);
    assert_eq!(rows[0].id, "senmanga:slug/9.1");
}

#[test]
fn adult_genre_is_refused_whatever_its_case_or_position() {
    assert!(is_adult(Some("Action,Adult,Adventure")));
    assert!(is_adult(Some("Drama, HENTAI")));
    assert!(!is_adult(Some("Action,Adventure,Seinen")));
    assert!(!is_adult(None));
}

#[test]
fn ids_round_trip_through_the_prefix() {
    assert!(is_senmanga_id("senmanga:one-piece"));
    assert!(!is_senmanga_id("https://mangakatana.com/manga/x"));
    assert!(!is_senmanga_id("a1c7c817-4e59-43b7-9365-09675a149a6f"));
}

#[test]
fn slugs_match_the_sites_kebab_case_romaji() {
    assert_eq!(slugify("Chainsaw Man"), "chainsaw-man");
    assert_eq!(slugify("Frieren: Beyond Journey's End"), "frieren-beyond-journeys-end");
    assert_eq!(slugify("  One   Piece!! "), "one-piece");
    // Japanese-only text has no slug, so there is nothing to ask for.
    assert_eq!(slugify("\u{30c1}\u{30a7}\u{30f3}\u{30bd}\u{30fc}"), "");
}

#[tokio::test]
#[ignore]
async fn live_search_detail_and_pages() {
    let client = SenMangaClient::new(reqwest::Client::new());
    let hits = client.search("Chainsaw Man").await.unwrap();
    let hit = hits.iter().find(|h| h.title == "Chainsaw Man").expect("no Chainsaw Man hit");
    let detail = client.detail(&hit.id).await.unwrap();
    println!("chapters={}", detail.chapters.len());
    assert!(detail.chapters.len() > 100);
    let pages = client.chapter_pages(&detail.chapters[0].id).await.unwrap();
    println!("pages in first chapter={}", pages.len());
    assert!(pages.len() > 1);
}

#[tokio::test]
#[ignore]
async fn live_a_title_the_site_lacks_is_an_empty_search_not_an_error() {
    // Nisekoi is not on Sen Manga; the site answers 500 for it.
    let client = SenMangaClient::new(reqwest::Client::new());
    assert!(client.search("Nisekoi").await.unwrap().is_empty());
}
