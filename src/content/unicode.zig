/// Unicode White_Space characters normalize to the reader's single ASCII
/// separator. Zero-width format controls are retained, not word boundaries.
pub fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

pub fn isPunctuation(codepoint: u21) bool {
    return switch (codepoint) {
        0x2000...0x206f,
        0x2e00...0x2e7f,
        0x3000...0x303f,
        0xff01...0xff0f,
        0xff1a...0xff20,
        0xff3b...0xff40,
        0xff5b...0xff65,
        => true,
        else => false,
    };
}
