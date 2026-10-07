// Getting from a row in the dock back to the session it stands for.
//
// Three ways, best first:
//   1. a deep link, if the app turns out to take one
//   2. the accessibility API: find the window whose title names this project
//      and raise it (needs Accessibility permission)
//   3. just activate the app
//
// Only the third always works, so it is the floor rather than the goal.

import AppKit
import ApplicationServices

enum Route {
    static let claudeBundle = "com.anthropic.claudefordesktop"
    static let codexBundle = "com.openai.codex"

    static func bundleID(for session: Session) -> String {
        session.isCodex ? codexBundle : claudeBundle
    }

    static var canUseAccessibility: Bool { AXIsProcessTrusted() }

    static func open(_ session: Session) {
        // Both apps document a deep link that lands on the exact conversation.
        // Their windows expose nothing through accessibility — the tree stops
        // at the app name — so this is the only way in.
        guard let url = deepLink(for: session) else {
            log("앱만 실행: \(session.project)")
            activateApp(for: session)
            return
        }

        // Every installed copy of Codex claims the codex:// scheme, so letting
        // the OS choose sends the link to whichever copy it picked — usually
        // not the one holding the thread. The scan recorded which app the
        // session's home belongs to, so open the link against that copy.
        if let bundle = ownerApp(for: session) {
            deliver(url, to: bundle)
            return
        }

        log("딥링크: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    /// Copies of the app we started that have not finished starting, and the
    /// link to hand each once it has.
    private static var starting: [String: URL] = [:]

    /// Open a link against one copy of the app, without stacking up windows.
    ///
    /// A link sent to a running copy lands in the window it already has —
    /// measured, six windows stayed six after links to an open session, to a
    /// different one, and to one with no window. A link sent while the copy
    /// is still starting does not: each became a window of its own, and a
    /// launch takes long enough that a second or third click is the natural
    /// thing to do. Three clicks during one launch left three windows. So a
    /// copy that is not running gets the first link to start it, and any
    /// further ones wait and the last of them is delivered once it is up.
    static func deliver(_ url: URL, to bundle: URL) {
        let key = bundle.path
        let id = bundleID(at: bundle) ?? ""
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.isFinishedLaunching }

        if starting[key] != nil {
            log("딥링크 보류(실행 중인 앱 기다림): \(url.absoluteString) → \(bundle.lastPathComponent)")
            starting[key] = url
            return
        }

        log("딥링크: \(url.absoluteString) → \(bundle.lastPathComponent)")
        if running {
            NSWorkspace.shared.open([url], withApplicationAt: bundle,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }

        starting[key] = url
        NSWorkspace.shared.open([url], withApplicationAt: bundle,
                                configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            DispatchQueue.main.async { waitUntilUp(app, key: key, bundle: bundle, first: url) }
        }
    }

    /// Poll until the copy reports it has finished launching, give its window
    /// a moment to come up, then send the last link that was held back.
    private static func waitUntilUp(_ app: NSRunningApplication?, key: String,
                                    bundle: URL, first: URL, tries: Int = 0) {
        let up = app?.isFinishedLaunching ?? true
        if !up && tries < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                waitUntilUp(app, key: key, bundle: bundle, first: first, tries: tries + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let last = starting.removeValue(forKey: key)
            guard let last, last != first else { return }
            log("보류한 딥링크 전달: \(last.absoluteString) → \(bundle.lastPathComponent)")
            NSWorkspace.shared.open([last], withApplicationAt: bundle,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The copy of the app this session actually lives in, when the scan
    /// managed to name one and it is still installed.
    static func ownerApp(for session: Session) -> URL? {
        guard let path = session.app, !path.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: path) else {
            log("기록된 앱이 사라짐: \(path)")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// claude://resume?session=<uuid>&cwd=<path>
    /// codex://threads/<thread id>
    static func deepLink(for session: Session) -> URL? {
        let id = session.id
        guard !id.isEmpty, id != "unknown" else { return nil }

        if session.isCodex {
            let allowed = CharacterSet.urlPathAllowed
            guard let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed)
            else { return nil }
            return URL(string: "codex://threads/\(escaped)")
        }

        // The link has to name the id the desktop app files the conversation
        // under, which is usually the CLI session id but is a different one
        // for a session that has been used through Remote Control. Handed the
        // CLI id, the app finds no record, makes a new one, and the same
        // conversation appears twice in its list — that is where five
        // duplicates came from. Without a filed id there is nothing safe to
        // send, so the app is raised instead.
        guard let filed = session.filed, !filed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        var items = [URLQueryItem(name: "session", value: filed)]
        if !session.cwd.isEmpty {
            items.append(URLQueryItem(name: "cwd", value: session.cwd))
        }
        components.queryItems = items
        return components.url
    }

    /// Bring the app forward, without touching any particular window.
    ///
    /// The copy that filed the session comes first. Falling back to the stock
    /// bundle id raised the original app for a conversation that only exists
    /// inside a clone, which is a window that will never show it.
    static func activateApp(for session: Session) {
        if let bundle = ownerApp(for: session) {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID(at: bundle) ?? "").first {
                running.activate(options: [.activateAllWindows])
                return
            }
            NSWorkspace.shared.openApplication(
                at: bundle, configuration: NSWorkspace.OpenConfiguration())
            return
        }

        let id = bundleID(for: session)
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: id).first {
            running.activate(options: [.activateAllWindows])
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return
        }
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// The bundle id inside an app on disk. A clone's is generated per copy,
    /// so it cannot be guessed from the tool the session belongs to.
    static func bundleID(at bundle: URL) -> String? {
        Bundle(url: bundle)?.bundleIdentifier
    }

    /// Raise the window whose title mentions this session's project. Desktop
    /// apps put the project or conversation name in the title, which is the
    /// only handle we get without a documented deep link.
    @discardableResult
    static func raiseWindow(for session: Session) -> Bool {
        guard canUseAccessibility else { return false }
        let id = bundleID(for: session)
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: id).first else { return false }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        // The session's own title is the strongest handle: the desktop app
        // shows it in both the sidebar and the window title.
        let needles = [session.chat ?? "", session.project,
                       lastPathComponent(session.cwd)]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        // The needles are the conversation's own title. Matching on it is the
        // point, writing it to a file on the way past is not.
        log("창 \(windows.count)개 탐색, 단서 \(needles.count)개")
        for window in windows {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                                &raw) == .success,
                  let title = raw as? String else { continue }
            guard needles.contains(where: { title.localizedCaseInsensitiveContains($0) })
            else {
                log("  건너뜀")
                continue
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString,
                                         kCFBooleanTrue)
            app.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }

    /// Dump what the desktop apps call their windows. Matching a session to a
    /// window depends entirely on these strings, and they are not documented.
    static func describeWindows() {
        guard canUseAccessibility else {
            log("창 조사 불가 — 접근성 권한 없음")
            return
        }
        for (name, bundle) in [("Claude", claudeBundle), ("Codex", codexBundle)] {
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundle).first else {
                log("[\(name)] 실행 중이 아님")
                continue
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString,
                                                &value) == .success,
                  let windows = value as? [AXUIElement] else {
                log("[\(name)] 창 목록을 못 읽음")
                continue
            }
            log("[\(name)] 창 \(windows.count)개")
            for window in windows {
                // The window title is just the app name; the sessions live in a
                // sidebar inside it, so walk in and list anything pressable.
                var found = 0
                walk(window, depth: 0) { element, label, depth in
                    guard found < 40, label.count >= 2 else { return }
                    found += 1
                    log("   \(String(repeating: "·", count: depth))\"\(label.prefix(60))\"")
                }
                log("   → 이름 있는 요소 \(found)개")
            }
        }
    }

    /// Depth-first over an accessibility subtree, reporting anything that
    /// carries a human-readable label.
    static func walk(_ element: AXUIElement, depth: Int,
                     limit: Int = 9,
                     visit: (AXUIElement, String, Int) -> Void) {
        guard depth < limit else { return }
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success,
               let text = raw as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                visit(element, text, depth)
                break
            }
        }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &kids) == .success,
              let children = kids as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, limit: limit, visit: visit)
        }
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Open the session's working directory in Finder — a useful fallback when
    /// the app cannot be steered to the right conversation.
    static func revealFolder(_ session: Session) {
        guard !session.cwd.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }
}
