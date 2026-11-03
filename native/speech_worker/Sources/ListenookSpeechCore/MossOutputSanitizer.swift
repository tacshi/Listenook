import Foundation

func isMossControlOnlyText(_ text: String) -> Bool {
    let hasSpeakerTag = text.range(
        of: #"\[S\d+\]"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
    guard hasSpeakerTag else { return false }

    let withoutControlTags = text.replacingOccurrences(
        of: #"\[(?:S\d+|\d+(?:\.\d+)?)\]"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
    )
    return withoutControlTags.trimmingCharacters(
        in: .whitespacesAndNewlines
    ).isEmpty
}
