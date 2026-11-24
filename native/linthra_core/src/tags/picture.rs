//! One embedded picture: FLAC's PICTURE block, which Ogg carries base64'd in a
//! METADATA_BLOCK_PICTURE comment. Big-endian: picture type, MIME type,
//! description, width, height, depth, colour count, then the image.

pub const FRONT_COVER: u32 = 3;

pub struct Picture {
    pub kind: u32,
    pub data: Vec<u8>,
}

/// The picture in `block`, or `None` when its lengths don't hold together or
/// it has no image.
pub fn parse(block: &[u8]) -> Option<Picture> {
    let len = block.len() as u64;
    let mut at: u64 = 0;
    let read_u32 = |at: &mut u64| -> Option<u64> {
        if *at + 4 > len {
            return None;
        }
        let i = *at as usize;
        *at += 4;
        Some(u64::from(u32::from_be_bytes([
            block[i],
            block[i + 1],
            block[i + 2],
            block[i + 3],
        ])))
    };
    let kind = read_u32(&mut at)?;
    let mime = read_u32(&mut at)?;
    at += mime;
    let description = read_u32(&mut at)?;
    at += description + 16; // then width, height, depth, colours
    let length = read_u32(&mut at)?;
    if length == 0 || at + length > len {
        return None;
    }
    Some(Picture {
        kind: kind as u32,
        data: block[at as usize..(at + length) as usize].to_vec(),
    })
}

/// The front cover among `pictures`, or the first one when none is.
pub fn cover(pictures: Vec<Picture>) -> Option<Vec<u8>> {
    let front = pictures.iter().position(|p| p.kind == FRONT_COVER);
    pictures
        .into_iter()
        .nth(front.unwrap_or(0))
        .map(|picture| picture.data)
}
