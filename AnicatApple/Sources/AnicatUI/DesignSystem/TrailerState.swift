import Foundation
import Observation

/// Whether a trailer overlay is up, shared between the detail page that
/// shows it and the Escape ladder in `AppModel`, which has no other way to
/// reach a `@State` inside the page. Escape closes the trailer before it
/// closes the page underneath.
@Observable
@MainActor
public final class TrailerState {
    public static let shared = TrailerState()
    public var isOpen = false
    private init() {}
}
