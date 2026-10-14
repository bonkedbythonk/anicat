import Foundation
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Whether Ask can run on this device, and when it cannot, the one thing the
/// viewer can do about it. Without this the feature just never appeared on a
/// Mac that did not qualify (macOS before 26, Apple Intelligence off, the model
/// still downloading) and nothing said why: a friend on a nightly asked.
enum AskAvailability {
    static var summary: (isOn: Bool, text: String) {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "Describe what you want in Search, or type a mood in Pick for me, and press Return.")
            case .unavailable(.deviceNotEligible):
                return (false, "This device does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return (false, "Turn on Apple Intelligence in System Settings to use it.")
            case .unavailable(.modelNotReady):
                return (false, "The Apple Intelligence model is still downloading. Try again in a while.")
            case .unavailable:
                return (false, "Apple Intelligence is not available right now.")
            }
        }
        #endif
        #if os(macOS)
        return (false, "Needs macOS 26 or later with Apple Intelligence.")
        #elseif os(iOS)
        return (false, "Needs iOS 26 or later with Apple Intelligence.")
        #else
        return (false, "Not available on this device.")
        #endif
    }
}
