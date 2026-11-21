import Foundation

extension TimeInterval {

    /// A rough length for a label: "30 sec", "3 min".
    public var clipLength: String {
        let seconds = Int(rounded())
        if seconds < 60 { return "\(seconds) sec" }
        return "\(Int((self / 60).rounded())) min"
    }

    /// A position on a timeline: "0:30", "2:00".
    public var clock: String {
        let seconds = Int(rounded())
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
