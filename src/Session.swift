// A local AI chat session, as recorded by the hooks and the home scan.

import AppKit

struct Session: Codable, Equatable {
    let id: String
    let tool: String          // "claude" | "codex"
    let cwd: String
    let project: String
    let state: String         // working | waiting | idle
    let title: String
    /// What the conversation is about — the first thing the user typed.
    let chat: String?
    let updated: Double
    let started: Double
    let app: String?
    /// The id the desktop app files this conversation under.
    let filed: String?
    /// "agent" when another agent handed this run its brief.
    let origin: String?
    let source: String?
    /// Messages a person typed that are lined up to run after this turn.
    /// Background-task notices are left out: they are not work, and counting
    /// them kept finished sessions looking busy.
    let queued: Int?

    var queuedCount: Int { queued ?? 0 }

    var date: Date { Date(timeIntervalSince1970: updated) }

    /// Live sessions together, ordered by whichever moved last; quiet ones
    /// below.
    ///
    /// Waiting used to outrank working, which sank a session the moment it
    /// picked up work and floated it again the moment it stopped — the list
    /// reshuffled for reasons that had nothing to do with what just happened.
    /// Both states are live, so they are ranked the same and recency alone
    /// separates them.
    var rank: Int { state == "idle" ? 1 : 0 }

    var isCodex: Bool { tool == "codex" }

    /// Work split off by another agent rather than opened by a person. Kept
    /// in the list — it is real work and worth seeing — but marked, so a
    /// burst of them reads as one task branching rather than as several
    /// conversations competing for attention.
    var isDelegated: Bool { origin == "agent" }

    /// Where this session was started from, as something to filter on.
    ///
    /// The recorded value is either the path of the app bundle that owns the
    /// session — one per installed copy, so a cloned Codex profile is its own
    /// source — or the short name of an editor a run was launched inside. A
    /// session with neither is named after its tool.
    var sourceKey: String {
        let owner = (app ?? "").trimmingCharacters(in: .whitespaces)
        if owner.isEmpty { return tool }
        return owner.hasSuffix(".app")
            ? (owner as NSString).lastPathComponent : owner
    }

    var sourceLabel: String {
        let key = sourceKey
        switch key {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "Code": return "VS Code"
        default:
            return key.hasSuffix(".app")
                ? String(key.dropLast(".app".count)) : key
        }
    }

    /// How long a finished turn stays a live prompt before it is just parked.
    ///
    /// "waiting" is a firm reading, not a guess: for Claude the last entry is
    /// an assistant message carrying no tool call, and for Codex the turn's
    /// closing marker has been written. Both mean the same thing — it said its
    /// piece and the next move is yours. What that does not say is whether the
    /// next move is still coming. Half an hour without a reply and the session
    /// is not asking for anything any more.
    static let replyWindow: TimeInterval = 30 * 60

    /// What the badge should show, which is the state read together with age.
    enum Mark { case working, yourTurn, parked }

    var mark: Mark {
        switch state {
        case "working": return .working
        case "waiting":
            return Date().timeIntervalSince1970 - updated < Session.replyWindow
                ? .yourTurn : .parked
        default: return .parked
        }
    }

    /// Whether this one should still be asking for attention.
    ///
    /// The ripple is for a turn nobody has looked at yet. Going on age alone
    /// meant it kept pulsing after the card had been opened and read, which
    /// teaches people to ignore it.
    var unseen: Bool {
        mark == .yourTurn && !Settings.shared.wasSeen(id, updated: updated)
    }

    /// The line that names this session. Falls back to the folder when the
    /// transcript has not been scanned yet.
    var headline: String {
        let chat = (chat ?? "").trimmingCharacters(in: .whitespaces)
        return chat.isEmpty ? project : chat
    }

    /// Shown small next to the headline, and dropped when it would repeat it.
    var subhead: String {
        headline == project ? "" : project
    }

    var label: String {
        switch state {
        case "waiting": return "입력 대기"
        case "working": return "작업 중"
        default: return "대기"
        }
    }

    var color: NSColor {
        switch state {
        case "waiting": return .systemOrange
        case "working": return .systemGreen
        default: return NSColor.secondaryLabelColor
        }
    }
}

/// Reads the state directory the hooks write into.
enum SessionStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/state/chat-sessions")

    /// How far back the dock shows without being asked.
    static let staleAfter: TimeInterval = 6 * 3600

    /// The rungs the reach climbs each time the button at the bottom is
    /// pressed. It resets when the app restarts, since reaching further is
    /// something you do to answer a question, not a setting you keep.
    static let reaches: [TimeInterval] = [6 * 3600, 24 * 3600, 48 * 3600, 72 * 3600]

    /// How many sessions sit further back than the given reach.
    static func countBeyond(_ reach: TimeInterval) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return 0 }
        let decoder = JSONDecoder()
        let cutoff = Date().timeIntervalSince1970 - reach
        var total = 0
        for name in names where name.hasSuffix(".json")
            && (name.hasPrefix("claude-") || name.hasPrefix("codex-")) {
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                  let session = try? decoder.decode(Session.self, from: data),
                  session.updated <= cutoff else { continue }
            total += 1
        }
        return total
    }

    static func load(reach: TimeInterval = staleAfter) -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        let cutoff = Date().timeIntervalSince1970 - reach

        var out: [Session] = []
        // Only the session records: the ledger shares this directory.
        for name in names where name.hasSuffix(".json")
            && (name.hasPrefix("claude-") || name.hasPrefix("codex-")) {
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                  let session = try? decoder.decode(Session.self, from: data),
                  session.updated > cutoff else { continue }
            out.append(session)
        }
        out.sort {
            $0.rank == $1.rank ? $0.updated > $1.updated : $0.rank < $1.rank
        }
        return out
    }
}

/// "방금", "3분 전"
enum Age {
    static func text(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<45: return "방금"
        case ..<3600: return "\(max(1, Int((Double(seconds) / 60).rounded())))분 전"
        case ..<86_400: return "\(seconds / 3600)시간 전"
        default: return "\(seconds / 86_400)일 전"
        }
    }
}


/// What the day cost, in waiting.
///
/// The dock is the one thing that sees both sides of every handover: when a
/// session stopped and when it was answered. Counted up, that says whether the
/// person or the agents are the ones holding the work — which a list of
/// current states cannot.
struct Ledger: Codable {
    let day: String
    let waited_on_me: Double
    let waited_on_them: Double
    let longest_chat: String
    let longest_seconds: Double

    static func load() -> Ledger? {
        let path = SessionStore.directory.appending(path: "ledger.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Ledger.self, from: data)
    }

    static func spell(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)초" }
        if whole < 3600 { return "\(whole / 60)분" }
        let hours = whole / 3600, minutes = (whole % 3600) / 60
        return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
    }
}
