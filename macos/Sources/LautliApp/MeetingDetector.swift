import Foundation

public enum MeetingApp: Equatable {
    case zoom
    case teams
}

public struct MeetingObservation {
    public let app: MeetingApp?
    public let meetingControlsVisible: Bool
    public let audioOutputActive: Bool
    public let accessibilityAvailable: Bool
    public let timestamp: Date

    public init(
        app: MeetingApp?,
        meetingControlsVisible: Bool,
        audioOutputActive: Bool,
        accessibilityAvailable: Bool,
        timestamp: Date
    ) {
        self.app = app
        self.meetingControlsVisible = meetingControlsVisible
        self.audioOutputActive = audioOutputActive
        self.accessibilityAvailable = accessibilityAvailable
        self.timestamp = timestamp
    }
}

public enum MeetingDetectionState: Equatable {
    case idle
    case candidate(MeetingApp)
    case capturing(MeetingApp)
    case failed(String)
}

public struct MeetingDetector {
    private var state: MeetingDetectionState = .idle
    private var candidateStart: Date?
    private var candidateSamples = 0
    private var missingSamples = 0

    public init() {}

    public mutating func update(_ observation: MeetingObservation) -> MeetingDetectionState {
        guard observation.accessibilityAvailable else {
            if case .capturing = state { return state }
            resetCandidate()
            state = .idle
            return state
        }

        switch state {
        case .capturing(let activeApp):
            if observation.app == activeApp && observation.meetingControlsVisible {
                missingSamples = 0
                return state
            }
            missingSamples += 1
            if missingSamples >= 10 {
                resetCandidate()
                missingSamples = 0
                state = .idle
            }
            return state

        case .idle, .candidate:
            guard
                let app = observation.app,
                observation.meetingControlsVisible,
                observation.audioOutputActive
            else {
                resetCandidate()
                state = .idle
                return state
            }

            if case .candidate(let candidateApp) = state, candidateApp == app {
                candidateSamples += 1
            } else {
                candidateStart = observation.timestamp
                candidateSamples = 1
                state = .candidate(app)
            }

            let candidateAge = observation.timestamp.timeIntervalSince(candidateStart ?? observation.timestamp)
            if candidateSamples >= 3 && candidateAge >= 5 {
                missingSamples = 0
                state = .capturing(app)
            }
            return state

        case .failed:
            return state
        }
    }

    private mutating func resetCandidate() {
        candidateStart = nil
        candidateSamples = 0
    }
}
