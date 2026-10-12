// One type and icon scale for the whole app. Sizes are points on macOS:
// 13 is the system body size; everything else steps from it.

import SwiftUI

enum AFont {
    /// Section and page titles: "Inbox · 934", the person's name, "Connections".
    static let title = Font.system(size: 13, weight: .semibold)
    /// Row primary text.
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    /// Row secondary text: previews, briefs, descriptions.
    static let secondary = Font.system(size: 12)
    static let secondaryStrong = Font.system(size: 12, weight: .semibold)
    /// Meta: times, counts, handles, captions.
    static let meta = Font.system(size: 11)
    static let metaStrong = Font.system(size: 11, weight: .semibold)
    /// The smallest text: tertiary lines, badges.
    static let micro = Font.system(size: 10)
    static let microStrong = Font.system(size: 10, weight: .semibold)
    /// Chips (labels, inbox tabs).
    static let chip = Font.system(size: 11)
    static let chipStrong = Font.system(size: 11, weight: .semibold)
    static let chipIcon = Font.system(size: 10, weight: .medium)
    /// Toolbar / bar icons.
    static let icon = Font.system(size: 13, weight: .medium)
    /// Status glyphs beside text (bell, note, moon).
    static let smallIcon = Font.system(size: 10, weight: .medium)
}
