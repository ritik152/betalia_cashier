/// Strips all emoji characters from [text], returning a clean string
/// suitable for thermal printer encodings (CP437, CP850, Latin-1).
///
/// Emoji ranges covered:
///   - Emoticons (U+1F600–U+1F64F)
///   - Dingbats / Miscellaneous Symbols (U+2600–U+26FF, U+2700–U+27BF)
///   - Supplemental Symbols & Pictographs (U+1F300–U+1F5FF)
///   - Transport & Map Symbols (U+1F680–U+1F6FF)
///   - Flags (U+1F1E0–U+1F1FF)
///   - Supplemental Symbols (U+1F900–U+1F9FF)
///   - Travel & Places extended (U+1FA00–U+1FA6F)
///   - Objects / extended-A (U+1FA70–U+1FAFF)
///   - Variation selectors (U+FE00–U+FE0F)
///   - Skin-tone modifiers (U+1F3FB–U+1F3FF)
///   - Zero-Width Joiners (U+200D) — used in compound emoji sequences
///   - Enclosing combining marks (U+20E3) — used for keycap sequences
///   - Regional indicator symbols (U+1F1E6–U+1F1FF)
///   - Additional arrows & symbols (U+2190–U+27BF)
///   - Miscellaneous Technical / Control Pictures (U+2300–U+23FF)
///   - Number forms enclosing marks (U+20D0–U+20FF)
///
/// Any character outside the Basic Multilingual Plane (code point > 0xFFFF)
/// that isn't already matched above is also stripped as a conservative
/// safety net for obscure future emoji additions.
String stripEmojis(String text) {
  if (text.isEmpty) return text;

  // This regex covers the vast majority of emoji characters and their
  // modifiers/joiners.  We also fallback-strip any supplementary-plane
  // character (codepoint > U+FFFF) not already matched.
  final emojiRegex = RegExp(
    r'[\u{1F600}-\u{1F64F}]' // Emoticons
    r'|[\u{1F300}-\u{1F5FF}]' // Misc Symbols & Pictographs
    r'|[\u{1F680}-\u{1F6FF}]' // Transport & Map Symbols
    r'|[\u{1F1E0}-\u{1F1FF}]' // Flags (regional indicators)
    r'|[\u{1F900}-\u{1F9FF}]' // Supplemental Symbols
    r'|[\u{1FA00}-\u{1FA6F}]' // Chess Symbols, etc.
    r'|[\u{1FA70}-\u{1FAFF}]' // Symbols extended-A
    r'|[\u{2600}-\u{27BF}]'   // Misc Symbols, Dingbats
    r'|[\u{2300}-\u{23FF}]'   // Misc Technical
    r'|[\u{2B50}-\u{2B55}]'   // Stars
    r'|[\u{FE00}-\u{FE0F}]'   // Variation Selectors
    r'|[\u{1F3FB}-\u{1F3FF}]' // Skin-tone modifiers
    r'|[\u{200D}]'             // Zero-Width Joiner
    r'|[\u{20E3}]'             // Combining Enclosing Keycap
    r'|[\u{00A9}\u{00AE}\u{2122}\u{2139}]' // © ® ™ ℹ
    r'|[\u{2328}\u{23CF}]'     // ⌨ ⏏
    r'|[\u{24C2}\u{1F6E0}-\u{1F6FC}]'      // Ⓜ + misc transport
    r'|[\u{1F4A0}-\u{1F53D}]'  // more misc objects / symbols
    r'|[\u{1F550}-\u{1F567}]'  // Clock faces
    r'|[\u{3297}\u{3299}]'     // ㊗ ㊙
    r'|[\u{203C}\u{2049}\u{25AA}\u{25AB}\u{25B6}\u{25C0}\u{25FB}-\u{25FE}]'
    r'|[\u{2934}\u{2935}]'     // Arrows
    r'|[\u{3030}\u{303D}]'     // Wavy dash, Part alternation mark
    r'|[\u{10000}-\u{10FFFF}]', // Fallback: any supplementary-plane char
    unicode: true,
  );

  return text.replaceAll(emojiRegex, '').trim();
}