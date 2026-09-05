import Testing

@testable import Atlas

struct EmojiShortcodesTests {
    @Test func replacesKnownShortcodes() {
        #expect(EmojiShortcodes.emojized("loud :speaker_high_volume:") == "loud 🔊")
        #expect(EmojiShortcodes.emojized(":face_with_rolling_eyes: ok :fire:") == "🙄 ok 🔥")
        #expect(EmojiShortcodes.emojized(":joy::joy:") == "😂😂")
    }

    @Test func leavesUnknownAndPlainColons() {
        #expect(EmojiShortcodes.emojized("time 10:30:45 today") == "time 10:30:45 today")
        #expect(EmojiShortcodes.emojized(":not_a_real_emoji_xyz:") == ":not_a_real_emoji_xyz:")
        #expect(EmojiShortcodes.emojized("no colons") == "no colons")
        #expect(EmojiShortcodes.emojized("ratio :: lol") == "ratio :: lol")
    }
}
