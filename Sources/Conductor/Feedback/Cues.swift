import AppKit
import Combine

/// Optional sounds, and VoiceOver announcements whenever VoiceOver is running, for the moments a
/// user can't see: taking or giving back control, pausing, and clicks.
@MainActor
final class Cues {
    private var cancellables: Set<AnyCancellable> = []

    init(state: TrackingState, preferences: Preferences) {
        state.events
            .sink { [weak preferences] event in
                guard let preferences else { return }
                Self.handle(event, sounds: preferences.soundCues)
            }
            .store(in: &cancellables)
        state.clicks
            .sink { [weak preferences] in
                if preferences?.soundCues == true { Self.play("Tink") }
            }
            .store(in: &cancellables)
    }

    private static func handle(_ event: GestureRecognizer.Event, sounds: Bool) {
        let (sound, announcement): (String, String) = {
            switch event {
            case .tookControl: return ("Pop", "Conductor has control")
            case .releasedControl: return ("Bottle", "Conductor released control")
            case .paused: return ("Purr", "Conductor paused")
            case .resumed: return ("Pop", "Conductor resumed")
            }
        }()
        if sounds { play(sound) }
        announce(announcement)
    }

    static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.4
        sound.play()
    }
}
