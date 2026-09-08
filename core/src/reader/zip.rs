//! A minimal ZIP writer, store-only.
//!
//! Exists so building an EPUB adds no dependency. EPUB allows exactly two
//! storage methods, Stored and Deflate, and Stored is the one the format
//! *requires* for its first entry anyway -- so a writer that only stores is a
//! complete EPUB writer, not a subset of one. A volume of prose is a few
//! hundred KB; what deflate would save is not worth a compressor.

/// One file in the archive. Order is the order they are written, and for an
/// EPUB the first entry has to be `mimetype`.
pub struct ZipEntry {
    pub name: String,
    pub data: Vec<u8>,
}

/// Writes the archive: a local header and the bytes per entry, then the
/// central directory, then the end-of-central-directory record.
pub fn write(entries: &[ZipEntry]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut directory = Vec::new();
    let mut offsets = Vec::with_capacity(entries.len());

    for entry in entries {
        offsets.push(out.len() as u32);
        let crc = crc32(&entry.data);
        let size = entry.data.len() as u32;

        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes()); // local file header
        out.extend_from_slice(&10u16.to_le_bytes()); // version needed: 1.0, store
        out.extend_from_slice(&0u16.to_le_bytes()); // flags
        out.extend_from_slice(&0u16.to_le_bytes()); // method: stored
        out.extend_from_slice(&0u16.to_le_bytes()); // mod time
        out.extend_from_slice(&0u16.to_le_bytes()); // mod date
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&size.to_le_bytes()); // compressed
        out.extend_from_slice(&size.to_le_bytes()); // uncompressed
        out.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra length
        out.extend_from_slice(entry.name.as_bytes());
        out.extend_from_slice(&entry.data);

        let offset = *offsets.last().unwrap();
        directory.extend_from_slice(&0x0201_4b50u32.to_le_bytes()); // central header
        directory.extend_from_slice(&20u16.to_le_bytes()); // version made by
        directory.extend_from_slice(&10u16.to_le_bytes()); // version needed
        directory.extend_from_slice(&0u16.to_le_bytes());
        directory.extend_from_slice(&0u16.to_le_bytes()); // method: stored
        directory.extend_from_slice(&0u16.to_le_bytes());
        directory.extend_from_slice(&0u16.to_le_bytes());
        directory.extend_from_slice(&crc.to_le_bytes());
        directory.extend_from_slice(&size.to_le_bytes());
        directory.extend_from_slice(&size.to_le_bytes());
        directory.extend_from_slice(&(entry.name.len() as u16).to_le_bytes());
        directory.extend_from_slice(&0u16.to_le_bytes()); // extra
        directory.extend_from_slice(&0u16.to_le_bytes()); // comment
        directory.extend_from_slice(&0u16.to_le_bytes()); // disk number
        directory.extend_from_slice(&0u16.to_le_bytes()); // internal attributes
        directory.extend_from_slice(&0u32.to_le_bytes()); // external attributes
        directory.extend_from_slice(&offset.to_le_bytes());
        directory.extend_from_slice(entry.name.as_bytes());
    }

    let directory_offset = out.len() as u32;
    let directory_size = directory.len() as u32;
    out.extend_from_slice(&directory);

    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes()); // end of central directory
    out.extend_from_slice(&0u16.to_le_bytes()); // this disk
    out.extend_from_slice(&0u16.to_le_bytes()); // disk with directory
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&directory_size.to_le_bytes());
    out.extend_from_slice(&directory_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment length

    out
}

/// CRC-32, the ordinary reflected polynomial ZIP uses. The table is built per
/// call because an archive is written once, at export, and the build is 256
/// iterations.
fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (index, slot) in table.iter_mut().enumerate() {
        let mut value = index as u32;
        for _ in 0..8 {
            value = if value & 1 == 1 { 0xEDB8_8320 ^ (value >> 1) } else { value >> 1 };
        }
        *slot = value;
    }

    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc = table[((crc ^ *byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_crc_matches_the_known_check_value() {
        // The standard CRC-32 check vector. A wrong CRC still produces a file
        // that unzips on lenient tools and is refused by e-readers.
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn the_first_entrys_bytes_start_at_the_fixed_header_length() {
        let zip = write(&[ZipEntry { name: "mimetype".into(), data: b"application/epub+zip".to_vec() }]);
        // 30-byte local header plus the 8-character name. The EPUB OCF spec
        // pins the mimetype's bytes to offset 38 so a reader can sniff the
        // format without parsing the archive at all.
        assert_eq!(&zip[38..58], b"application/epub+zip");
        assert_eq!(&zip[0..4], &[0x50, 0x4b, 0x03, 0x04]);
        // Method 0, stored. A compressed mimetype is the single most common
        // reason a hand-built EPUB opens nowhere.
        assert_eq!(u16::from_le_bytes([zip[8], zip[9]]), 0);
    }

    #[test]
    fn the_end_record_points_at_a_directory_holding_every_entry() {
        let zip = write(&[
            ZipEntry { name: "a".into(), data: b"one".to_vec() },
            ZipEntry { name: "b".into(), data: b"two".to_vec() },
        ]);
        let end = zip.len() - 22;
        assert_eq!(&zip[end..end + 4], &[0x50, 0x4b, 0x05, 0x06]);
        assert_eq!(u16::from_le_bytes([zip[end + 10], zip[end + 11]]), 2);
        let size = u32::from_le_bytes(zip[end + 12..end + 16].try_into().unwrap()) as usize;
        let offset = u32::from_le_bytes(zip[end + 16..end + 20].try_into().unwrap()) as usize;
        assert_eq!(offset + size, end);
        assert_eq!(&zip[offset..offset + 4], &[0x50, 0x4b, 0x01, 0x02]);
    }
}
