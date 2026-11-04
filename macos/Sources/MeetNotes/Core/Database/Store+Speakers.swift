import Foundation

extension Store {
    /// People in this meeting who still carry an automatic "Speaker N" name.
    func unnamedSpeakers(in meetingID: String) throws -> [Speaker] {
        try participants(of: meetingID).filter { $0.name.wholeMatch(of: #/Speaker \d+/#) != nil }
    }
}
