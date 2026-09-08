use super::*;

fn sample() -> EpubBook {
    EpubBook {
        title: "Mushoku Tensei: Jobless Reincarnation Vol. 1".into(),
        author: "Rifujin na Magonote".into(),
        identifier: "anicat:lnori:12020".into(),
        language: "en".into(),
        chapters: vec![
            EpubChapter { title: "Color Inserts".into(), text: String::new() },
            EpubChapter {
                title: "Chapter 1: Is This Another World?".into(),
                text: "When I opened my eyes.\n\nOnce my vision adjusted.\nShe was a woman."
                    .into(),
            },
            EpubChapter {
                title: "Rock & Roll <Extra>".into(),
                text: "Ends here.".into(),
            },
        ],
    }
}

fn entry(zip: &[u8], name: &str) -> String {
    // Store-only, so a local header is followed directly by the bytes. Finding
    // it by scanning the archive is what a reader does too.
    let mut cursor = 0;
    while let Some(found) = zip[cursor..].windows(4).position(|w| w == b"PK\x03\x04") {
        let start = cursor + found;
        let size = u32::from_le_bytes(zip[start + 18..start + 22].try_into().unwrap()) as usize;
        let name_len = u16::from_le_bytes([zip[start + 26], zip[start + 27]]) as usize;
        let extra_len = u16::from_le_bytes([zip[start + 28], zip[start + 29]]) as usize;
        let name_start = start + 30;
        let found_name = String::from_utf8_lossy(&zip[name_start..name_start + name_len]).to_string();
        let data_start = name_start + name_len + extra_len;
        if found_name == name {
            return String::from_utf8_lossy(&zip[data_start..data_start + size]).to_string();
        }
        cursor = data_start + size;
    }
    panic!("no entry named {name}");
}

#[test]
fn the_mimetype_is_the_first_entry_and_uncompressed() {
    let zip = build(&sample()).unwrap();
    // The OCF rule that makes or breaks a hand-built EPUB: readers sniff these
    // exact bytes at this exact offset rather than unpacking to find out what
    // the file is.
    assert_eq!(&zip[30..38], b"mimetype");
    assert_eq!(&zip[38..58], b"application/epub+zip");
}

#[test]
fn an_image_only_section_is_left_out_rather_than_exported_blank() {
    let zip = build(&sample()).unwrap();
    let opf = entry(&zip, "OEBPS/content.opf");
    assert!(!opf.contains("Color Inserts"));
    // Two chapters survive, and the spine names both.
    assert_eq!(opf.matches("<itemref").count(), 2);
    assert!(entry(&zip, "OEBPS/ch0000.xhtml").contains("When I opened my eyes."));
}

#[test]
fn both_tables_of_contents_are_present_and_the_spine_names_the_ncx() {
    let zip = build(&sample()).unwrap();
    let opf = entry(&zip, "OEBPS/content.opf");
    // Hybrid on purpose: an EPUB 2 reader finds the ncx, an EPUB 3 reader
    // finds the nav, and the exported file does not care which one the
    // device turns out to be.
    assert!(opf.contains(r#"<spine toc="ncx">"#));
    assert!(opf.contains(r#"properties="nav""#));
    assert!(entry(&zip, "OEBPS/toc.ncx").contains("<navMap>"));
    assert!(entry(&zip, "OEBPS/nav.xhtml").contains(r#"epub:type="toc""#));
}

#[test]
fn markup_characters_in_a_title_stay_escaped_everywhere_they_appear() {
    let zip = build(&sample()).unwrap();
    for file in ["OEBPS/ch0001.xhtml", "OEBPS/nav.xhtml", "OEBPS/toc.ncx"] {
        let text = entry(&zip, file);
        assert!(text.contains("Rock &amp; Roll &lt;Extra&gt;"), "{file} left it raw");
    }
}

#[test]
fn a_line_break_inside_a_paragraph_survives_as_a_break_not_a_new_paragraph() {
    let zip = build(&sample()).unwrap();
    let chapter = entry(&zip, "OEBPS/ch0000.xhtml");
    assert!(chapter.contains("Once my vision adjusted.<br/>She was a woman."));
    assert_eq!(chapter.matches("<p").count(), 2);
    // The paragraph that opens the chapter is the only unindented one.
    assert_eq!(chapter.matches(r#"class="opening""#).count(), 1);
}

#[test]
fn the_stylesheet_carries_nothing_an_e_ink_panel_cannot_use() {
    let zip = build(&sample()).unwrap();
    let css = entry(&zip, "OEBPS/style.css");
    // Pixels override the device's own font-size control; a dark ground is a
    // full-frame inversion the panel repaints on every page turn.
    assert!(!css.contains("px"));
    assert!(!css.contains("@font-face"));
    assert!(!css.contains("position:"));
    assert!(css.contains("color: #000"));
    assert!(css.contains("background: #fff"));
}

#[test]
fn a_volume_with_no_prose_at_all_refuses_rather_than_writing_an_empty_book() {
    let book = EpubBook {
        chapters: vec![EpubChapter { title: "Cover".into(), text: "  \n ".into() }],
        ..sample()
    };
    assert!(build(&book).is_err());
}

/// Live. `cargo test --lib epub -- --ignored --nocapture` writes a real
/// volume to /tmp so it can be opened on an actual device -- the only check
/// that matters for a format whose failures are silent.
#[tokio::test]
#[ignore]
async fn a_real_volume_exports() {
    let client = crate::reader::lnori::LnoriClient::new(reqwest::Client::new());
    let book = "https://lnori.com/book/12020/mushoku-tensei-jobless-reincarnation-vol-1";
    let refs = client.volume_chapters(book).await.unwrap();

    let mut chapters = Vec::new();
    for chapter in &refs {
        let anchor = chapter.url.split('#').nth(1).unwrap_or_default();
        let content = client.chapter_content(book, anchor).await.unwrap();
        chapters.push(EpubChapter { title: content.title, text: content.text });
    }

    let bytes = build(&EpubBook {
        title: "Mushoku Tensei: Jobless Reincarnation Vol. 1".into(),
        author: "Rifujin na Magonote".into(),
        identifier: format!("anicat:test:{book}"),
        language: "en".into(),
        chapters,
    })
    .unwrap();

    let path = std::env::temp_dir().join("anicat-live-volume.epub");
    std::fs::write(&path, &bytes).unwrap();
    println!("wrote {} ({} KB)", path.display(), bytes.len() / 1024);
}
