import Testing
import Foundation
import SwiftUI
@testable import AnicatUI

@Suite("Third-party notices")
struct AcknowledgementsTests {
    /// The Settings button disables itself when the file cannot be found, so a
    /// dropped `.copy("Resources/Legal")` would ship as a greyed-out row that
    /// nobody reports rather than as a failure anywhere.
    @Test func noticesAreBundled() throws {
        let url = try #require(AcknowledgementsButton<EmptyView>.noticesURL)
        let text = try String(contentsOf: url, encoding: .utf8)

        // One name from each half: the MPVKit table is written by hand and the
        // crate list comes from Cargo.lock, and either can go missing alone.
        #expect(text.contains("FFmpeg 8.1.2"))
        #expect(text.contains("librqbit "))
        #expect(text.contains("SIL OPEN FONT LICENSE"))
        #expect(text.contains("GNU GENERAL PUBLIC LICENSE"))
    }
}
