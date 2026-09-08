//! One light novel volume as an EPUB, for reading somewhere that is not this
//! app.
//!
//! **Hybrid, not one generation or the other.** The package is EPUB 3 and
//! carries an EPUB 3 `nav.xhtml`, *and* an EPUB 2 `toc.ncx` referenced from
//! the spine. Both are written because the point of exporting is that the file
//! leaves for a device nothing here can see: EPUB 3 readers open an EPUB 2
//! table of contents, EPUB 2 readers do not know what a nav document is, and
//! only carrying both makes the choice of device somebody else's to make.
//!
//! **The stylesheet is written for electronic paper**, which is why it looks
//! so bare:
//!
//! - Black on white, stated outright. The app's own palette is a dark theme,
//!   and a dark page on an e-ink panel is a full-frame inversion the display
//!   has to refresh -- it ghosts, and it costs a redraw per page turn.
//! - Every size is in `em` or `%`, never `px`. The font-size control on the
//!   device scales the root; a stylesheet in pixels overrides it and the
//!   buttons on the reader stop doing anything.
//! - No fixed widths, no positioning, no web fonts. The page is whatever
//!   shape the device is, and the device's own serif is the one its rendering
//!   is tuned for.
//!
//! Text only. The source's colour inserts are images this does not carry, and
//! a section that is nothing but images is left out rather than exported as a
//! blank page.

use crate::reader::zip::{self, ZipEntry};

pub struct EpubChapter {
    pub title: String,
    pub text: String,
}

pub struct EpubBook {
    pub title: String,
    pub author: String,
    /// Stable per volume, so re-exporting replaces rather than duplicates in a
    /// library that deduplicates on identifier.
    pub identifier: String,
    pub language: String,
    pub chapters: Vec<EpubChapter>,
}

const STYLESHEET: &str = r#"html { color: #000; background: #fff; }
body { margin: 0 5%; line-height: 1.45; text-align: justify; }
h1 { font-size: 1.35em; line-height: 1.25; margin: 1.5em 0 1em; text-align: left; page-break-before: always; }
p { margin: 0; text-indent: 1.2em; widows: 2; orphans: 2; }
p.opening { text-indent: 0; margin-top: 0.6em; }
"#;

/// The finished archive.
///
/// A chapter with no prose is dropped rather than written: the first entries
/// of every volume are the cover and the colour inserts, which are images, and
/// as spine items they would be blank pages the reader has to turn past before
/// the book starts.
pub fn build(book: &EpubBook) -> Result<Vec<u8>, String> {
    let chapters: Vec<&EpubChapter> =
        book.chapters.iter().filter(|c| !c.text.trim().is_empty()).collect();
    if chapters.is_empty() {
        return Err("nothing to export: this volume has no readable text".to_string());
    }

    let mut entries = Vec::with_capacity(chapters.len() + 5);

    // First and stored, which `zip::write` guarantees for every entry. An
    // EPUB whose mimetype is anywhere else, or compressed, is refused by
    // readers that sniff it at the fixed offset instead of unpacking.
    entries.push(ZipEntry { name: "mimetype".into(), data: b"application/epub+zip".to_vec() });

    entries.push(ZipEntry {
        name: "META-INF/container.xml".into(),
        data: CONTAINER_XML.as_bytes().to_vec(),
    });
    entries.push(ZipEntry { name: "OEBPS/style.css".into(), data: STYLESHEET.as_bytes().to_vec() });

    for (index, chapter) in chapters.iter().enumerate() {
        entries.push(ZipEntry {
            name: format!("OEBPS/{}", chapter_file(index)),
            data: chapter_xhtml(chapter).into_bytes(),
        });
    }

    entries.push(ZipEntry { name: "OEBPS/nav.xhtml".into(), data: nav_xhtml(book, &chapters).into_bytes() });
    entries.push(ZipEntry { name: "OEBPS/toc.ncx".into(), data: ncx(book, &chapters).into_bytes() });
    entries.push(ZipEntry { name: "OEBPS/content.opf".into(), data: opf(book, &chapters).into_bytes() });

    Ok(zip::write(&entries))
}

const CONTAINER_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"#;

fn chapter_file(index: usize) -> String {
    format!("ch{index:04}.xhtml")
}

fn chapter_xhtml(chapter: &EpubChapter) -> String {
    let mut body = String::new();
    for (index, paragraph) in chapter.text.split("\n\n").enumerate() {
        let paragraph = paragraph.trim();
        if paragraph.is_empty() {
            continue;
        }
        // A soft break inside a paragraph is a line the source broke on
        // purpose, so it stays a break rather than becoming a new paragraph.
        let inner = paragraph
            .split('\n')
            .map(escape)
            .collect::<Vec<_>>()
            .join("<br/>");
        // The first paragraph after a heading is not indented; that is the
        // typesetting convention every printed novel follows.
        let class = if index == 0 { " class=\"opening\"" } else { "" };
        body.push_str(&format!("    <p{class}>{inner}</p>\n"));
    }

    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head>
    <title>{title}</title>
    <link rel="stylesheet" type="text/css" href="style.css"/>
  </head>
  <body>
    <h1>{title}</h1>
{body}  </body>
</html>
"#,
        title = escape(&chapter.title),
        body = body
    )
}

fn nav_xhtml(book: &EpubBook, chapters: &[&EpubChapter]) -> String {
    let items = chapters
        .iter()
        .enumerate()
        .map(|(index, c)| {
            format!(
                "        <li><a href=\"{}\">{}</a></li>",
                chapter_file(index),
                escape(&c.title)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head>
    <title>{title}</title>
    <link rel="stylesheet" type="text/css" href="style.css"/>
  </head>
  <body>
    <nav epub:type="toc" id="toc">
      <h1>Contents</h1>
      <ol>
{items}
      </ol>
    </nav>
  </body>
</html>
"#,
        title = escape(&book.title),
        items = items
    )
}

fn ncx(book: &EpubBook, chapters: &[&EpubChapter]) -> String {
    let points = chapters
        .iter()
        .enumerate()
        .map(|(index, c)| {
            format!(
                "    <navPoint id=\"nav{index}\" playOrder=\"{order}\">\n      <navLabel><text>{label}</text></navLabel>\n      <content src=\"{file}\"/>\n    </navPoint>",
                index = index,
                order = index + 1,
                label = escape(&c.title),
                file = chapter_file(index)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="{id}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>{title}</text></docTitle>
  <navMap>
{points}
  </navMap>
</ncx>
"#,
        id = escape(&book.identifier),
        title = escape(&book.title),
        points = points
    )
}

fn opf(book: &EpubBook, chapters: &[&EpubChapter]) -> String {
    let manifest = chapters
        .iter()
        .enumerate()
        .map(|(index, _)| {
            format!(
                "    <item id=\"ch{index}\" href=\"{file}\" media-type=\"application/xhtml+xml\"/>",
                index = index,
                file = chapter_file(index)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let spine = chapters
        .iter()
        .enumerate()
        .map(|(index, _)| format!("    <itemref idref=\"ch{index}\"/>"))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="bookid">{id}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>{author}</dc:creator>
    <dc:language>{language}</dc:language>
    <meta property="dcterms:modified">{modified}</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
{manifest}
  </manifest>
  <spine toc="ncx">
{spine}
  </spine>
</package>
"#,
        id = escape(&book.identifier),
        title = escape(&book.title),
        author = escape(&book.author),
        language = escape(&book.language),
        // Second precision with a literal Z, which is the only form
        // `dcterms:modified` is allowed to take; a fractional or offset
        // timestamp is an EPUB 3 validation error.
        modified = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
        manifest = manifest,
        spine = spine
    )
}

/// The five XML predefined entities. A raw `&` or `<` from a chapter title
/// makes the whole document unparseable, and an EPUB reader that hits a
/// malformed XHTML file shows the error instead of the page.
fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(ch),
        }
    }
    out
}

#[cfg(test)]
mod tests;
