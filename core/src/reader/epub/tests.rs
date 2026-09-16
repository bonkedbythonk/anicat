use super::*;

fn sample() -> EpubBook {
    EpubBook {
        title: "Mushoku Tensei: Jobless Reincarnation Vol. 1".into(),
        author: "Rifujin na Magonote".into(),
        identifier: "anicat:lnori:12020".into(),
        language: "en".into(),
        cover: Some(("cover.jpg".to_string(), b"cover-bytes".to_vec())),
        chapters: vec![
            EpubChapter {
                title: "Color Inserts".into(),
                text: String::new(),
                images: vec![EpubImage {
                    after_paragraph: -1,
                    file: "0000-000.jpg".into(),
                    bytes: b"jpeg-bytes".to_vec(),
                }],
            },
            EpubChapter {
                title: "Chapter 1: Is This Another World?".into(),
                text: "When I opened my eyes.\n\nOnce my vision adjusted.\nShe was a woman."
                    .into(),
                images: vec![EpubImage {
                    after_paragraph: 0,
                    file: "0001-000.png".into(),
                    bytes: b"png-bytes".to_vec(),
                }],
            },
            EpubChapter {
                title: "Rock & Roll <Extra>".into(),
                text: "Ends here.".into(),
                images: vec![],
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
fn a_section_of_pictures_and_no_prose_is_still_part_of_the_book() {
    // The colour inserts. Dropping them was what "the EPUB is missing the
    // inserts" meant -- they are the section a light novel is bought for.
    let zip = build(&sample()).unwrap();
    let opf = entry(&zip, "OEBPS/content.opf");
    assert_eq!(opf.matches("<itemref").count(), 3);
    assert!(entry(&zip, "OEBPS/ch0000.xhtml").contains("images/0000-000.jpg"));
    assert_eq!(entry(&zip, "OEBPS/images/0000-000.jpg"), "jpeg-bytes");
}

#[test]
fn a_section_with_neither_prose_nor_pictures_is_left_out() {
    let book = EpubBook {
        chapters: vec![
            EpubChapter { title: "Cover".into(), text: "  ".into(), images: vec![] },
            EpubChapter { title: "One".into(), text: "Words.".into(), images: vec![] },
        ],
        ..sample()
    };
    let opf = entry(&build(&book).unwrap(), "OEBPS/content.opf");
    assert_eq!(opf.matches("<itemref").count(), 1);
    assert!(!opf.contains("Cover"));
}

#[test]
fn an_illustration_lands_after_the_paragraph_it_belongs_to() {
    let zip = build(&sample()).unwrap();
    let chapter = entry(&zip, "OEBPS/ch0001.xhtml");
    let image = chapter.find("images/0001-000.png").unwrap();
    let first = chapter.find("When I opened my eyes.").unwrap();
    let second = chapter.find("Once my vision adjusted.").unwrap();
    assert!(first < image && image < second);
}

#[test]
fn every_image_file_is_declared_in_the_manifest_with_its_own_media_type() {
    // An `<img>` whose target is not in the manifest is an EPUB error, and the
    // stricter readers refuse the whole book rather than dropping the picture.
    let opf = entry(&build(&sample()).unwrap(), "OEBPS/content.opf");
    assert!(opf.contains(r#"href="images/0000-000.jpg" media-type="image/jpeg""#));
    assert!(opf.contains(r#"href="images/0001-000.png" media-type="image/png""#));
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
    for file in ["OEBPS/ch0002.xhtml", "OEBPS/nav.xhtml", "OEBPS/toc.ncx"] {
        let text = entry(&zip, file);
        assert!(text.contains("Rock &amp; Roll &lt;Extra&gt;"), "{file} left it raw");
    }
}

#[test]
fn a_line_break_inside_a_paragraph_survives_as_a_break_not_a_new_paragraph() {
    let zip = build(&sample()).unwrap();
    let chapter = entry(&zip, "OEBPS/ch0001.xhtml");
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
        chapters: vec![EpubChapter { title: "Cover".into(), text: "  \n ".into(), images: vec![] }],
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
    for (section, chapter) in refs.iter().enumerate() {
        let anchor = chapter.url.split('#').nth(1).unwrap_or_default();
        let content = client.chapter_content(book, anchor).await.unwrap();
        // Fetched here rather than read from a store, so the live test does
        // not need a download to have happened first.
        let mut images = Vec::new();
        for (position, (after, url)) in content.images.iter().enumerate() {
            let bytes = reqwest::get(url).await.unwrap().bytes().await.unwrap();
            images.push(EpubImage {
                after_paragraph: *after,
                // Keyed by section as well as position: every chapter starts
                // its own count, so a position-only name collided across them
                // and the archive kept one picture per index for the whole
                // book.
                file: format!("{section:04}-{position:03}.jpg"),
                bytes: bytes.to_vec(),
            });
        }
        chapters.push(EpubChapter { title: content.title, text: content.text, images });
    }

    let cover = match client.volume_cover(book).await.unwrap() {
        Some(url) => {
            let bytes = reqwest::get(&url).await.unwrap().bytes().await.unwrap();
            Some(("cover.jpg".to_string(), bytes.to_vec()))
        }
        None => None,
    };
    let bytes = build(&EpubBook {
        title: "Mushoku Tensei: Jobless Reincarnation Vol. 1".into(),
        author: "Rifujin na Magonote".into(),
        identifier: format!("anicat:test:{book}"),
        language: "en".into(),
        cover,
        chapters,
    })
    .unwrap();

    let path = std::env::temp_dir().join("anicat-live-volume.epub");
    std::fs::write(&path, &bytes).unwrap();
    println!("wrote {} ({} KB)", path.display(), bytes.len() / 1024);
}

#[test]
fn the_cover_is_declared_the_way_both_generations_look_for_it() {
    let zip = build(&sample()).unwrap();
    let opf = entry(&zip, "OEBPS/content.opf");
    // EPUB 3 reads the manifest property; EPUB 2 reads the meta. A device that
    // knows only one shows a blank tile without the other.
    assert!(opf.contains(r#"properties="cover-image""#));
    assert!(opf.contains(r#"<meta name="cover" content="cover"/>"#));
    // The id is literally "cover": readers exist that look it up by that and
    // by neither the property nor the meta.
    assert!(opf.contains(r#"<item id="cover" "#));
    assert_eq!(entry(&zip, "OEBPS/images/cover.jpg"), "cover-bytes");
}
