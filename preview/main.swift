// Renders dock rows offscreen to a PNG, so contrast and spacing can be judged
// without screen-recording access.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func sample(_ tool: String, _ state: String, _ chat: String, _ project: String,
            _ title: String, ago: TimeInterval = 120) -> Session {
    Session(id: tool + chat, tool: tool, cwd: "/Users/me/" + project,
            project: project, state: state, title: title, chat: chat,
            updated: Date().timeIntervalSince1970 - ago,
            started: Date().timeIntervalSince1970 - 3600, app: nil, filed: nil,
            origin: nil, source: "scan", queued: nil)
}

let sessions = [
    sample("claude", "waiting", "PR 알림을 맥 알림으로 띄우는 앱 만들어줘",
           "PycharmProjects", "카드 세 개를 띄웠습니다. 확인해 주세요."),
    queued(sample("claude", "working", "CAD 목록에 Simulation·Mesh 개수 추가",
                  "SolverAI-client", "", ago: 20), 2),
    sample("codex", "working", "jsp가 올린 backend pr 리뷰 ㄱ",
           "solverai-backend", "리뷰를 진행하고 있습니다."),
    sample("claude", "waiting", "PRO-792 해볼려?", "solverai-deployments", "",
           ago: 4 * 3600),
    delegated(sample("codex", "waiting", "신규 기획 구현 아젠다 Step collapsible 독립 작업",
                     "PycharmProjects", "")),
]

func queued(_ s: Session, _ count: Int) -> Session {
    Session(id: s.id, tool: s.tool, cwd: s.cwd, project: s.project, state: s.state,
            title: s.title, chat: s.chat, updated: s.updated, started: s.started,
            app: s.app, filed: s.filed, origin: s.origin, source: s.source,
            queued: count)
}

func delegated(_ s: Session) -> Session {
    Session(id: s.id, tool: s.tool, cwd: s.cwd, project: s.project, state: s.state,
            title: s.title, chat: s.chat, updated: s.updated, started: s.started,
            app: s.app, filed: s.filed, origin: "agent", source: s.source,
            queued: s.queued)
}

let dock = Dock()
let cards = sessions.map { RowCard(session: $0, dock: dock) }
cards[1].setOpen(true)

// The card draws itself; the window it normally lives in is not needed to
// look at one. Shadows are layer effects and do not appear in a cached draw.
let shots: [NSImage] = cards.compactMap { card in
    let size = card.isOpen ? card.expandedSize : card.collapsedSize
    card.frame = NSRect(origin: .zero, size: size)
    card.layoutSubtreeIfNeeded()
    guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
        return nil
    }
    card.cacheDisplay(in: card.bounds, to: rep)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

let scale: CGFloat = 2
let pad: CGFloat = 20
let columnWidth = shots.map(\.size.width).max() ?? 288
let columnHeight = shots.reduce(0) { $0 + $1.size.height + 8 }
let width = pad * 2 + columnWidth
let height = pad * 2 + columnHeight

let sheet = NSImage(size: NSSize(width: width * scale * 2, height: height * scale),
                    flipped: false) { _ in
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(calibratedRed: 0.78, green: 0.81, blue: 0.86, alpha: 1).setFill()
    NSRect(x: width, y: 0, width: width, height: height).fill()

    for panel in 0..<2 {
        var y = height - pad
        for shot in shots {
            y -= shot.size.height
            shot.draw(in: NSRect(x: CGFloat(panel) * width + pad, y: y,
                                 width: shot.size.width, height: shot.size.height))
            y -= 8
        }
    }
    return true
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview.png"
if let tiff = sheet.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
    print("saved \(out)")
}
exit(0)
