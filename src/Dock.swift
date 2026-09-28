// The dock itself: a column of rows in the bottom-right corner, one per live
// session. Collapsed, a row is a single line — status dot, project, age.
// Hovering opens it and shows what the session last said.
//
// Rows are individual windows anchored at their top-right corner, so an open
// row grows left and down without moving the pointer out of itself, and the
// rows below slide down in the same animation.

import AppKit

enum Layout {
    /// Set by the user, by dragging the column's left edge or from the menu.
    static var width: CGFloat { CGFloat(Settings.shared.dockWidth) }
    static var rowHeight: CGFloat { CGFloat(Settings.shared.rowHeight) }
    static let detailMax: CGFloat = 26
    static let gap: CGFloat = 6
    static let inset: CGFloat = 12
    /// Codex rounds its own glass panels at 16.
    static let corner: CGFloat = 16
    /// Transparent margin around each card, for the shadow to fall into.
    static let shadowPad: CGFloat = 16
    static let padding: CGFloat = 10
    /// Kept just under a row, so the crown reads as trim rather than as
    /// another row you could click.
    static var headerHeight: CGFloat { max(rowHeight - 6, 22) }
    /// Shortening this to chase a fast sweep made the movement feel clipped
    /// without making it feel any quicker: the work behind a row opening
    /// measures under a millisecond, so the delay being felt is the travel
    /// itself, not anything waiting to be computed.
    static let duration: TimeInterval = 0.2
}

/// The display the dock lives on: whichever the user pinned, falling back to
/// the one with the menu bar rather than to whichever happens to be focused.
enum Screens {
    static func number(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    static var target: NSScreen? {
        let pinned = Settings.shared.pinnedScreen
        if pinned != 0, let match = NSScreen.screens.first(where: { number($0) == pinned }) {
            return match
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    static var all: [NSScreen] { NSScreen.screens }
}

enum Palette {
    /// Fully opaque. The glass decides what comes through; fading the window
    /// on top of that only dulled the card and softened its text — a leftover
    /// from when transparency was being chased with an alpha instead.
    static let opacity: CGFloat = 1.0

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The card's own surface, under the blur.
    ///
    /// Put beside a real banner the glassy version read as washed out: a
    /// banner is a bright, nearly solid card, and what makes it look like
    /// glass is its shadow and its edge, not what shows through it. This layer
    /// is also what the shadow is cast from — a shadow needs something to fall
    /// from, and a path alone drew nothing at all.
    static var surface: NSColor {
        isDark ? NSColor(calibratedWhite: 0.16, alpha: 0.72)
               : NSColor(calibratedWhite: 1.0, alpha: 0.72)
    }

    /// The colour the card actually reads as, laid over the blur.
    ///
    /// Under the blur it did nothing: a behind-window effect paints what is
    /// behind the *window*, so the wallpaper and the material's own grey
    /// covered it and the card came out grey against a white banner. What is
    /// drawn last is what is seen, so the card's colour belongs here — the
    /// blur still softens the edges and gives it its depth.
    /// A light floor laid over the glass.
    ///
    /// The glass takes its colour from whatever is behind it, so over a dark
    /// desktop the card goes dark with it. A banner does not: it keeps a pale
    /// surface wherever it sits, and still shows what is behind. This is what
    /// holds that floor — thin enough that the boundary between two things
    /// behind the dock still reads straight through.
    static var backing: NSColor {
        let lift = CGFloat(Settings.shared.cardTint)
        guard lift > 0 else { return .clear }
        return isDark ? NSColor(calibratedWhite: 0.22, alpha: lift)
                      : NSColor(calibratedWhite: 1.0, alpha: lift)
    }

    static var openTint: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.05)
               : NSColor.black.withAlphaComponent(0.035)
    }
    static var title: NSColor { NSColor.labelColor }
    static var detail: NSColor { NSColor.labelColor.withAlphaComponent(0.68) }
    static var meta: NSColor { NSColor.labelColor.withAlphaComponent(0.45) }
}

/// Tool marks, drawn rather than loaded: the apps' own icons are square and
/// heavy, and at 14pt they turn to mush.
enum Marks {
    /// Where each tool lives when the session does not name its own copy.
    static let claudeApp = "/Applications/Claude.app"
    static let codexApp = "/Applications/ChatGPT.app"

    private static var cache: [String: NSImage] = [:]

    /// The app's own icon, from the copy this session belongs to.
    ///
    /// Codex sessions carry the bundle they were started in, so a cloned copy
    /// shows the icon that copy was given — the personal profile and the work
    /// one are told apart without reading a word.
    static func icon(for session: Session, size: CGFloat) -> NSImage {
        let owned = session.app ?? ""
        let bundle = owned.isEmpty ? (session.isCodex ? codexApp : claudeApp) : owned
        if let found = appIcon(bundle, size: size) { return found }
        // The app is not installed, or was moved after the session was
        // recorded; a mark still has to appear where one is expected.
        return symbol(session.isCodex ? "circle.hexagonpath" : "asterisk",
                      size: size, description: session.tool)
    }

    /// Rows redraw thirty times a second while anything is working, so the
    /// icon is fetched once per app and kept.
    private static func appIcon(_ bundle: String, size: CGFloat) -> NSImage? {
        let key = "\(bundle)@\(size)"
        if let hit = cache[key] { return hit }
        guard FileManager.default.fileExists(atPath: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        icon.size = NSSize(width: size, height: size)
        cache[key] = icon
        return icon
    }

    private static var glyphs: [String: NSImage] = [:]

    /// Held rather than rebuilt. These are fixed shapes, and the spinner asks
    /// for them thirty times a second.
    static func symbol(_ name: String, size: CGFloat,
                       description: String) -> NSImage {
        let key = "\(name)@\(size)"
        if let hit = glyphs[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let made = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: size, height: size))
        glyphs[key] = made
        return made
    }

    private static var tints: [String: NSImage] = [:]

    static func tinted(_ image: NSImage, _ color: NSColor, key: String) -> NSImage {
        if let hit = tints[key] { return hit }
        let made = tinted(image, color)
        tints[key] = made
        return made
    }

    /// Recolour a symbol, which otherwise draws in its own template black.
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// The turning arc, as a layer rather than something drawn.
///
/// It used to be redrawn from a timer thirty times a second. Even limited to
/// the badge, each frame dirtied a window whose background is a behind-window
/// blur, and the blur had to be recomposited every time — the app sat at a
/// fifth of a core with nothing happening but a spinner. Handed to Core
/// Animation the rotation runs on the render server and costs this process
/// nothing at all.
enum Spinner {
    static func make(diameter: CGFloat, colour: NSColor) -> CALayer {
        let box = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let arc = CAShapeLayer()
        arc.frame = box
        arc.path = CGPath(ellipseIn: box.insetBy(dx: 1, dy: 1), transform: nil)
        arc.fillColor = nil
        arc.strokeColor = colour.cgColor
        arc.lineWidth = 1.9
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.62
        // Anchored dead centre so the arc turns rather than orbits.
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -Double.pi * 2
        turn.duration = 1.2
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "turn")
        return arc
    }
}

/// The edges that make glass read as glass.
///
/// Codex draws its own overlay with a hairline border and two inset
/// highlights — a bright line just inside the top, a fainter one along the
/// bottom — over the native glass. They are what makes the surface look lit
/// without covering it, which is the part that was missing while brightness
/// was being chased with a wash of white over the whole card.
enum Rim {
    static func draw(in bounds: NSRect, corner: CGFloat) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let edge = NSBezierPath(roundedRect: inset, xRadius: corner - 0.5,
                                yRadius: corner - 0.5)
        edge.lineWidth = 1
        (Palette.isDark ? NSColor.white.withAlphaComponent(0.10)
                        : NSColor.black.withAlphaComponent(0.06)).setStroke()
        edge.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).addClip()
        // inset 0 1px 1px #fff9
        NSColor.white.withAlphaComponent(Palette.isDark ? 0.22 : 0.60).setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        // inset 0 -1px 2px #fff3
        NSColor.white.withAlphaComponent(Palette.isDark ? 0.08 : 0.20).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The ripple that goes out from a session waiting on you.
///
/// A finished turn is the one state that wants something, and a still mark
/// said so no louder than a parked one did. A ring around the badge was too
/// small to catch, a wash over the card too faint to notice, and a steady
/// glow just sat there. This grows out of the badge and fades, which reads as
/// something happening rather than something being lit. Two rings, half a
/// cycle apart, so there is always one on its way out.
enum Halo {
    static func make(diameter: CGFloat, colour: NSColor) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        for step in [0.0, 1.1] {
            host.addSublayer(ring(diameter: diameter, colour: colour, delay: step))
        }
        return host
    }

    private static func ring(diameter: CGFloat, colour: NSColor,
                             delay: Double) -> CALayer {
        let box = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let ring = CAShapeLayer()
        ring.frame = box
        // Stroked rather than filled: it passes over the mark on its way out,
        // and a filled disc would blank it every cycle.
        ring.path = CGPath(ellipseIn: box.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = colour.cgColor
        ring.lineWidth = 1.5
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.opacity = 0

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = 1.9

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.65, 0.0]
        fade.keyTimes = [0, 0.15, 1]

        let both = CAAnimationGroup()
        both.animations = [grow, fade]
        both.duration = 2.2
        both.repeatCount = .infinity
        both.isRemovedOnCompletion = false
        both.timeOffset = delay
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(both, forKey: "ripple")
        return ring
    }
}

final class RowView: NSView {
    weak var card: RowCard?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    private var spinner: CALayer?
    private var spinnerColour: NSColor?
    private var halo: CALayer?

    /// Put the breathing wash in place, or take it away.
    func setHalo(_ on: Bool, colour: NSColor) {
        guard on else {
            halo?.removeFromSuperlayer()
            halo = nil
            return
        }
        guard halo == nil else { return }
        let made = Halo.make(diameter: badgeRect.width, colour: colour)
        made.frame = badgeRect
        layer?.insertSublayer(made, at: 0)
        halo = made
    }

    /// Put the turning arc in place, or take it away.
    ///
    /// Rebuilt only when its colour changes, so the rotation is never
    /// restarted mid-turn by an unrelated redraw.
    func setSpinner(_ on: Bool, colour: NSColor) {
        // Probe: is the spinner layer what darkens a working row?
        let on = on && !UserDefaults.standard.bool(forKey: "noSpinner")
        guard on else {
            spinner?.removeFromSuperlayer()
            spinner = nil
            spinnerColour = nil
            return
        }
        if spinner != nil, spinnerColour == colour { return }
        spinner?.removeFromSuperlayer()
        let made = Spinner.make(diameter: badgeRect.width - 7, colour: colour)
        made.frame = badgeRect.insetBy(dx: 3.5, dy: 3.5)
        layer?.addSublayer(made)
        spinner = made
        spinnerColour = colour
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func mouseUp(with event: NSEvent) {
        card?.click(at: convert(event.locationInWindow, from: nil))
    }

    /// Where the status mark sits. The spinner turns inside this and nothing
    /// else moves, so it is the only part that has to be redrawn for it.
    var badgeRect: NSRect {
        NSRect(x: Layout.padding, y: (Layout.rowHeight - 16) / 2,
               width: 16, height: 16)
    }

    /// The clear-away control, top-right, only while the row is open.
    var resolveRect: NSRect {
        NSRect(x: bounds.width - 24, y: (Layout.rowHeight - 18) / 2,
               width: 18, height: 18)
    }

    private var hoverResolve = false

    func setResolveHover(_ on: Bool) {
        guard on != hoverResolve else { return }
        hoverResolve = on
        needsDisplay = true
    }

    /// The status mark inside its badge.
    ///
    /// Working is the only one that moves: an arc chasing its own tail, which
    /// reads as progress without needing a percentage nobody has. Waiting is
    /// an arrow pointing back at the reader, because the row is asking for
    /// something. Idle is a flat bar — present, but with nothing to say.
    private func drawStatus(_ session: Session, in badge: NSRect,
                            reversed: Bool = false) {
        let dimmed = session.mark == .parked
        let colour = reversed ? NSColor.white
            : (dimmed ? NSColor.labelColor.withAlphaComponent(0.45) : session.color)

        switch session.mark {
        case .working:
            break        // the spinner is a layer, and turns on its own

        case .yourTurn:
            // Solid, and pointing the way a thing you press points.
            let glyph = Marks.symbol("play.fill", size: 8,
                                     description: session.label)
            Marks.tinted(glyph, colour,
                         key: "play\(session.state)\(dimmed)\(reversed)").draw(
                in: NSRect(x: badge.midX - glyph.size.width / 2 + 0.5,
                           y: badge.midY - glyph.size.height / 2,
                           width: glyph.size.width, height: glyph.size.height))

        case .parked:
            let bar = NSRect(x: badge.midX - 3.5, y: badge.midY - 0.8,
                             width: 7, height: 1.6)
            colour.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let card, let session = card.session else { return }
        let open = card.isOpen

        // Wiped back to nothing first.
        //
        // This view is the glass's own contents, and drawing over what was
        // there before let everyhalf-transparent pixel pile onto the last one:
        // a row grew darker each time it redrew, while a row nobody touched
        // stayed as bright as it started.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        Palette.backing.setFill()
        bounds.fill()
        if open {
            Palette.openTint.setFill()
            bounds.fill()
        }
        Rim.draw(in: bounds, corner: Layout.corner)

        var x = Layout.padding

        // What the session is doing, as a mark rather than a word. A row is
        // read at a glance and sideways, so the shape has to carry it — the
        // three states are told apart by silhouette before colour.
        setSpinner(session.mark == .working, colour: session.color)
        setHalo(session.unseen, colour: session.color)
        let badge = badgeRect
        let dim = session.mark == .parked

        // A solid disc under the mark.
        //
        // It used to be a wash of the state's own colour at a fifth strength,
        // which was legible over the near-opaque card it was drawn on. On
        // glass the desktop comes through it, and the mark had to compete with
        // whatever happened to be behind the dock. The disc now carries its
        // own ground, so the mark reads the same over water as over a page.
        let disc = NSBezierPath(ovalIn: badge)
        let unseen = session.unseen
        if unseen {
            // A turn nobody has looked at yet gets the badge outright: solid
            // colour, mark reversed out of it. A pale disc with a tinted mark
            // read no louder than any other row, whatever was pulsing around
            // it.
            session.color.setFill()
            disc.fill()
        } else {
            (Palette.isDark ? NSColor(calibratedWhite: 0.16, alpha: 0.92)
                            : NSColor(calibratedWhite: 1.0, alpha: 0.92)).setFill()
            disc.fill()
            session.color.withAlphaComponent(dim ? 0.14 : 0.24).setFill()
            disc.fill()
            disc.lineWidth = 1
            session.color.withAlphaComponent(dim ? 0.30 : 0.55).setStroke()
            NSBezierPath(ovalIn: badge.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        drawStatus(session, in: badge, reversed: unseen)

        // How much is in flight, as a count pinned to the mark: background
        // jobs the session started, plus follow-ups a person queued behind
        // the turn. Only while it is working — the number is "how many things
        // are running for this row", and a row that is not running has none.
        let inFlight = session.backgroundCount + session.queuedCount
        if session.mark == .working && inFlight > 0 {
            let label = (inFlight > 9 ? "9+" : "\(inFlight)") as NSString
            let font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
            let size = label.size(withAttributes: [.font: font])
            let pill = NSRect(x: badge.maxX - 5, y: badge.minY - 3,
                              width: max(size.width + 5, 10), height: 10)
            let shape = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
            session.color.setFill()
            shape.fill()
            (Palette.isDark ? NSColor(calibratedWhite: 0.16, alpha: 1)
                            : NSColor.white).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            label.draw(at: NSPoint(x: pill.midX - size.width / 2,
                                   y: pill.midY - size.height / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
        }
        x = badge.maxX + 7

        // which tool this session belongs to
        // Drawn in its own colours: an app icon greyed out reads as disabled,
        // and these are the one place in the row that is meant to be
        // recognised rather than read.
        // Work another agent split off sits under a branch mark, so a task
        // that fanned out reads as one thing with limbs rather than as
        // several unrelated conversations.
        if session.isDelegated {
            let branch = Marks.symbol("arrow.turn.down.right", size: 8,
                                      description: "위임된 작업")
            Marks.tinted(branch, NSColor.labelColor.withAlphaComponent(0.32),
                         key: "branch")
                .draw(in: NSRect(x: x, y: Layout.rowHeight / 2 - branch.size.height / 2,
                                 width: branch.size.width, height: branch.size.height))
            x += branch.size.width + 3
        }

        let mark = Marks.icon(for: session, size: 14)
        mark.draw(in: NSRect(x: x, y: Layout.rowHeight / 2 - mark.size.height / 2,
                             width: mark.size.width, height: mark.size.height),
                  from: .zero, operation: .sourceOver,
                  fraction: session.mark == .parked ? 0.55 : 1.0)
        x += mark.size.width + 6

        var right = bounds.width - Layout.padding
        if open {
            // resolve control takes the age's place while the row is open
            let dot = resolveRect.insetBy(dx: 4, dy: 4)
            (hoverResolve ? NSColor.systemRed.withAlphaComponent(0.9)
                          : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
            NSBezierPath(ovalIn: dot).fill()
            if let glyph = NSImage(systemSymbolName: "checkmark",
                                   accessibilityDescription: "치우기") {
                let mark = NSImage(size: NSSize(width: 7, height: 7),
                                   flipped: false) { rect in
                    glyph.draw(in: rect)
                    (self.hoverResolve ? NSColor.white
                        : NSColor.labelColor.withAlphaComponent(0.6)).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                mark.draw(in: NSRect(x: dot.midX - 3.5, y: dot.midY - 3.5,
                                     width: 7, height: 7))
            }
            right = resolveRect.minX - 8
        }
        let age = Age.text(since: session.date)
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: Palette.meta, .kern: 0.2]
        let metaSize = (age as NSString).size(withAttributes: metaAttrs)
        right -= metaSize.width
        (age as NSString).draw(at: NSPoint(x: right, y: (Layout.rowHeight - 13) / 2),
                               withAttributes: metaAttrs)
        right -= 8

        let clip = NSMutableParagraphStyle()
        clip.lineBreakMode = .byTruncatingTail

        // The chat's own subject leads; the folder trails it, smaller.
        let line = NSMutableAttributedString(
            string: session.headline,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                         .foregroundColor: Palette.title, .kern: -0.1])
        if !session.subhead.isEmpty {
            line.append(NSAttributedString(
                string: "  " + session.subhead,
                attributes: [.font: NSFont.systemFont(ofSize: 10.5),
                             .foregroundColor: Palette.meta]))
        }
        line.addAttribute(.paragraphStyle, value: clip,
                          range: NSRange(location: 0, length: line.length))
        line.draw(in: NSRect(x: x, y: (Layout.rowHeight - 16) / 2,
                             width: max(20, right - x), height: 16))

        guard open else { return }
        // The open row says what the count on the badge is made of.
        let base = session.title.isEmpty ? session.cwd : session.title
        let detail = session.activity.isEmpty ? base : session.activity + "  —  " + base
        (detail as NSString).draw(
            in: NSRect(x: Layout.padding + 14, y: Layout.rowHeight - 4,
                       width: bounds.width - Layout.padding * 2 - 14,
                       height: Layout.detailMax),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: Palette.detail,
                             .paragraphStyle: clip])
    }
}

/// One card in the column: a blurred surface, its shadow, and its contents.
///
/// The effect view sits inside a wrapper again. Made the card itself, with the
/// shadows moved onto the window's content layer, the blur stopped sampling
/// anything at all — every material painted the same flat tint, which is what
/// a backdrop with nothing behind it looks like. This is the arrangement the
/// wallpaper was last seen through.
class CardView: NSView {
    /// Whether the system's own glass is available to build cards on.
    static let usesSystemGlass = NSClassFromString("NSGlassEffectView") != nil

    /// The surface the card is built on.
    ///
    /// macOS 26 has a glass effect of its own, and it is not one of the
    /// NSVisualEffectView materials — it refracts what is behind it rather
    /// than blurring and tinting it, which is why no combination of material
    /// and opacity ever came close. Codex asks for it by name: its own styles
    /// carry `-owl-native-material: glass` and switch their CSS blur off when
    /// it is available. Older systems fall back to the closest material.
    let glass: NSView
    private let effect: NSVisualEffectView?
    private let corner: CGFloat
    private let clear: Bool

    init(corner: CGFloat, shadow: CGFloat, clear: Bool = false) {
        self.corner = corner
        self.clear = clear
        if let type = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let made = type.init(frame: .zero)
            made.setValue(corner, forKey: "cornerRadius")
            glass = made
            effect = nil
        } else {
            let made = NSVisualEffectView()
            made.blendingMode = .behindWindow
            made.state = .active
            made.wantsLayer = true
            made.layer?.cornerRadius = corner
            made.layer?.cornerCurve = .continuous
            made.layer?.masksToBounds = true
            glass = made
            effect = made
        }

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        applyMaterial()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The glass is left alone.
    ///
    /// Its tintColor only ever darkened it, whatever colour or alpha it was
    /// given, and it was applied on every repaint — which is why the card
    /// started bright and dimmed as soon as anything redrew it. None of the
    /// private knobs lifted it either: each was either no change or a drop
    /// straight down to clear.
    /// The glass is left alone.
    ///
    /// Its tintColor does not tint. Given white and given black it settles on
    /// exactly the same colour, so the hue is discarded; only the alpha does
    /// anything, and it works backwards — the more of it, the darker the card.
    /// It reads as a dial on how much of the glass's own brightening to give
    /// up, and no setting of it goes past leaving it alone.
    func applyTint() {
        guard effect == nil else { return }
        glass.setValue(nil, forKey: "tintColor")
        // Regular for the cards, as Codex asks for its own. Clear for the tab:
        // measured, clear glass lets the desktop through almost untouched, and
        // that is the whole point of a tab meant to sit on the wallpaper.
        glass.setValue(clear ? 1 : 0, forKey: "style")
        // Adaptation off. The property defaults to 2, which is why setting it
        // to 2 earlier changed nothing — that was the default being written
        // back. Codex turns this off outright rather than leaving it on
        // automatic, which is what stops a card taking its colour from
        // whatever it happens to be sitting over.
        // 1, measured rather than guessed. The property defaults to 2, and both
        // 0 and 2 let each card take its lightness from whatever it sits over
        // — a column spanning a dark rock and bright water spread across
        // eleven levels of brightness, with some cards flipping to dark
        // outright. At 1 the spread is nil: every card holds the same surface
        // wherever it is.
        glass.setValue(1, forKey: "_adaptiveAppearance")
        // Pin the appearance so the glass stops following what is behind it.
        //
        // Left to itself it takes its light or dark look from the desktop, so
        // a card over a dark wallpaper turns dark with it. Codex holds its own
        // overlay still the same way — its glass carries a forced appearance
        // rather than an adaptive one.
        glass.appearance = NSAppearance(named: Palette.isDark ? .darkAqua : .aqua)
    }

    /// Only meaningful on the fallback: the glass effect has one look.
    func applyMaterial() {
        applyTint()
        guard let effect else { return }
        switch Settings.shared.cardMaterial {
        case "hudWindow": effect.material = .hudWindow
        case "fullScreenUI": effect.material = .fullScreenUI
        case "popover": effect.material = .popover
        case "sheet": effect.material = .sheet
        case "sidebar": effect.material = .sidebar
        case "selection": effect.material = .selection
        case "underWindowBackground": effect.material = .underWindowBackground
        default: effect.material = .menu
        }
    }

    /// The view drawn inside the glass, kept the size of the card.
    var content: NSView? {
        didSet {
            guard let content else { return }
            // The glass effect hosts its contents rather than having them
            // added as subviews; the fallback takes them the ordinary way.
            if effect == nil {
                glass.setValue(content, forKey: "contentView")
            } else {
                glass.addSubview(content)
            }
            content.frame = glass.bounds
        }
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content?.frame = glass.bounds
    }
}

/// A card standing for one session.
final class RowCard: CardView {
    private(set) var session: Session?
    private(set) var isOpen = false
    private weak var dock: Dock?
    private let view = RowView()

    init(session: Session, dock: Dock) {
        self.session = session
        self.dock = dock
        super.init(corner: Layout.corner, shadow: 11)
        view.card = self
        view.autoresizingMask = [.width, .height]
        content = view
    }

    required init?(coder: NSCoder) { fatalError() }

    var collapsedSize: NSSize { NSSize(width: Layout.width, height: Layout.rowHeight) }
    var expandedSize: NSSize {
        NSSize(width: Layout.width, height: Layout.rowHeight + Layout.detailMax)
    }

    func update(_ session: Session) {
        self.session = session
        view.needsDisplay = true
    }

    func refresh() { view.needsDisplay = true }

    @discardableResult
    func setOpen(_ open: Bool) -> Bool {
        guard open != isOpen else { return false }
        isOpen = open
        view.needsDisplay = true
        return true
    }

    private(set) var targetFrame: NSRect = .zero
    func setTarget(_ frame: NSRect) { targetFrame = frame }

    func click(at point: NSPoint) {
        guard let session else { return }
        if isOpen, view.resolveRect.contains(point) {
            dock?.resolve(session)
            return
        }
        dock?.activate(session)
    }

    /// Where the resolve control sits, in the dock's own coordinates.
    func resolveHitBox() -> NSRect {
        let local = view.resolveRect
        return NSRect(x: frame.minX + local.minX,
                      y: frame.maxY - local.maxY,
                      width: local.width, height: local.height)
    }

    func setResolveHover(_ on: Bool) { view.setResolveHover(on) }
}

/// The card at the top: how many sessions, a settings button, and a grip.
final class HeaderCard: CardView {
    private let view = HeaderView()
    private weak var dock: Dock?

    init(dock: Dock) {
        self.dock = dock
        super.init(corner: Layout.headerHeight / 2, shadow: 8)
        view.owner = self
        view.autoresizingMask = [.width, .height]
        content = view
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(counts: (waiting: Int, working: Int, idle: Int)) {
        view.counts = counts
        view.needsDisplay = true
    }

    func drag(by delta: CGSize) { dock?.moveAnchor(by: delta) }
    func resize(by delta: CGFloat) { dock?.resizeWidth(by: delta) }
    func fold() { dock?.toggleCollapsed() }
}

/// The button under the column that reaches further back.
final class MoreCard: CardView {
    private let view = MoreView()
    private weak var dock: Dock?

    init(dock: Dock) {
        self.dock = dock
        super.init(corner: Layout.headerHeight / 2, shadow: 8)
        view.owner = self
        view.autoresizingMask = [.width, .height]
        content = view
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(label: String, home: Bool) {
        guard view.label != label || view.showsHome != home else { return }
        view.label = label
        view.showsHome = home
        view.needsDisplay = true
    }

    func press() { dock?.reachFurther() }
    func goHome() { dock?.reachHome() }
}

final class MoreView: NSView {
    weak var owner: MoreCard?
    var label = ""
    var showsHome = false
    private var overHome = false
    private var overMain = false

    override var isFlipped: Bool { true }

    /// The way back, kept apart from the way further so returning never means
    /// pressing through every rung you climbed.
    private var homeRect: NSRect {
        showsHome ? NSRect(x: bounds.width - 36, y: 0, width: 36, height: bounds.height)
                  : .zero
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let home = homeRect.contains(point)
        let main = !home && bounds.contains(point)
        if home != overHome || main != overMain {
            overHome = home
            overMain = main
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        overHome = false
        overMain = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if homeRect.contains(convert(event.locationInWindow, from: nil)) {
            owner?.goHome()
        } else {
            owner?.press()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        Palette.backing.setFill()
        bounds.fill()
        Rim.draw(in: bounds, corner: bounds.height / 2)

        let home = homeRect
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor
                .withAlphaComponent(overMain ? 0.85 : 0.55),
            .kern: 0.2]
        let size = (label as NSString).size(withAttributes: attrs)
        let room = bounds.width - home.width
        (label as NSString).draw(
            at: NSPoint(x: (room - size.width) / 2,
                        y: (bounds.height - size.height) / 2),
            withAttributes: attrs)

        guard showsHome else { return }
        // A hairline between the two, so it reads as two controls rather than
        // one long bar with a mark floating at its end.
        (Palette.isDark ? NSColor.white.withAlphaComponent(0.12)
                        : NSColor.black.withAlphaComponent(0.10)).setStroke()
        let split = NSBezierPath()
        split.move(to: NSPoint(x: home.minX, y: 5))
        split.line(to: NSPoint(x: home.minX, y: bounds.height - 5))
        split.lineWidth = 1
        split.stroke()

        let glyph = Marks.symbol("arrow.uturn.left", size: 9,
                                 description: "처음 범위로")
        Marks.tinted(glyph, NSColor.labelColor.withAlphaComponent(overHome ? 0.85 : 0.5),
                     key: "home\(overHome)")
            .draw(in: NSRect(x: home.midX - glyph.size.width / 2,
                             y: home.midY - glyph.size.height / 2,
                             width: glyph.size.width, height: glyph.size.height))
    }
}

/// What is left of the dock when it is folded away.
///
/// A tab at the corner the column grows from, carrying the counts so the thing
/// you fold the dock away to avoid — checking it — is still answered without
/// unfolding it. Hovering brings the column back.
/// Water moving inside the tab.
///
/// Two translucent waves scroll across the pill at different speeds, so their
/// crests drift in and out of step and the surface never repeats exactly — the
/// difference between a loop and something that looks like it is moving. Each
/// path is two periods long and slides by one, which is seamless. Layers only:
/// the render server does the moving.
enum Sheen {
    static func make(size: NSSize, corner: CGFloat) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: size)
        host.masksToBounds = true
        host.cornerRadius = corner
        host.cornerCurve = .continuous

        // Back wave: long, slow, sits a touch lower.
        host.addSublayer(wave(in: size, period: size.width * 1.15, amplitude: 2.6,
                              level: 0.46, alpha: 0.16, seconds: 3.4, bob: 1.2))
        // Front wave: shorter and quicker, so the two cross.
        host.addSublayer(wave(in: size, period: size.width * 0.72, amplitude: 2.0,
                              level: 0.40, alpha: 0.22, seconds: 2.1, bob: 0.9))
        return host
    }

    private static func wave(in size: NSSize, period: CGFloat, amplitude: CGFloat,
                             level: CGFloat, alpha: CGFloat, seconds: Double,
                             bob: CGFloat) -> CALayer {
        let width = period * 2 + size.width      // room to slide a full period
        let path = CGMutablePath()
        let base = size.height * level
        path.move(to: CGPoint(x: 0, y: -size.height))
        path.addLine(to: CGPoint(x: 0, y: base))
        var x: CGFloat = 0
        while x <= width {
            let y = base + sin(x / period * .pi * 2) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        path.addLine(to: CGPoint(x: width, y: -size.height))
        path.closeSubpath()

        let shape = CAShapeLayer()
        shape.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        shape.path = path
        // On the pale wash a white crest disappears, so the light theme draws
        // the water as a faint shade rather than a highlight. Kept well under
        // the tint's own strength: a shadow, not a stripe.
        shape.fillColor = (Palette.isDark
            ? NSColor.white.withAlphaComponent(alpha)
            : NSColor(srgbRed: 0.24, green: 0.42, blue: 0.66,
                      alpha: alpha * 0.62)).cgColor

        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = shape.position.x
        slide.toValue = shape.position.x - period
        slide.duration = seconds
        slide.repeatCount = .infinity
        slide.isRemovedOnCompletion = false

        // A slow rise and fall as well, so the waterline itself breathes.
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = shape.position.y - bob
        rise.toValue = shape.position.y + bob
        rise.duration = seconds * 1.7
        rise.autoreverses = true
        rise.repeatCount = .infinity
        rise.isRemovedOnCompletion = false
        rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        shape.add(slide, forKey: "slide")
        shape.add(rise, forKey: "rise")
        return shape
    }
}

final class NubCard: CardView {
    private let view = NubView()
    private weak var dock: Dock?
    /// Taller than the header bars, so the counts have room to be read rather
    /// than squeezed into a strip meant for text.
    static let size = NSSize(width: 74, height: 28)

    /// Only as wide as the counts need. A fixed 74 left fifteen points of
    /// empty glass on either side of two small numbers, which made the tab
    /// read as a bar rather than a badge.
    static func width(for counts: (waiting: Int, working: Int, idle: Int)) -> CGFloat {
        max(NubView.run(of: NubView.labels(for: counts)) + 22, 44)
    }

    init(dock: Dock) {
        self.dock = dock
        super.init(corner: NubCard.size.height / 2, shadow: 8, clear: true)
        view.owner = self
        view.autoresizingMask = [.width, .height]
        content = view
    }

    func press() { dock?.openFromTab() }
    func drag(by delta: CGSize) { dock?.moveAnchor(by: delta) }

    required init?(coder: NSCoder) { fatalError() }

    func set(counts: (waiting: Int, working: Int, idle: Int)) {
        guard view.counts != counts else { return }
        view.counts = counts
        view.needsDisplay = true
    }
}

final class NubView: NSView {
    weak var owner: NubCard?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    var counts: (waiting: Int, working: Int, idle: Int) = (0, 0, 0)
    private var travelled: CGFloat = 0
    private var sheen: CALayer?

    /// Built when the frame is set, which is the one moment guaranteed to
    /// happen: layout() is not called on a view that has no constraints.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, sheen?.frame.size != newSize else { return }
        sheen?.removeFromSuperlayer()
        let made = Sheen.make(size: newSize, corner: newSize.height / 2)
        layer?.addSublayer(made)
        sheen = made
    }

    /// The tab is the whole dock while folded, so it has to be the thing you
    /// drag to move it — there is no header grip to reach for. A press that
    /// went somewhere is a drag, not a press.
    override func mouseDown(with event: NSEvent) { travelled = 0 }

    override func mouseDragged(with event: NSEvent) {
        travelled += abs(event.deltaX) + abs(event.deltaY)
        owner?.drag(by: CGSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if travelled < 4 { owner?.press() }
        travelled = 0
    }

    /// Fetched once: the tab redraws whenever a count changes.
    static let badge: NSImage = {
        let icon = NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 1, height: 1))
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }()

    static let dot: CGFloat = 5
    static let tight: CGFloat = 4      // dot to its number
    static let apart: CGFloat = 9      // one pair to the next

    /// The counts as they are written out, so width and drawing agree.
    static func labels(for counts: (waiting: Int, working: Int, idle: Int)) -> [String] {
        var out: [String] = []
        if counts.waiting > 0 { out.append("\(counts.waiting)") }
        if counts.working > 0 { out.append("\(counts.working)") }
        return out.isEmpty ? ["·"] : out
    }

    static let numerals: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: Palette.title, .kern: 0.2]

    /// How much room the dots and numbers actually take.
    static func run(of texts: [String]) -> CGFloat {
        var total: CGFloat = 0
        for text in texts {
            total += dot + tight + (text as NSString).size(withAttributes: numerals).width
        }
        return total + apart * CGFloat(max(texts.count - 1, 0))
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        // The wash goes on here rather than in a layer of its own: a sublayer
        // sits above whatever the view draws, so the tint was covering the
        // very numbers it was meant to sit behind. Painted first, it backs
        // them instead — bright enough to read against a busy desktop, and
        // still sheer enough to leave the wallpaper showing.
        let wash = NSBezierPath(roundedRect: bounds,
                                xRadius: bounds.height / 2,
                                yRadius: bounds.height / 2)
        (Palette.isDark ? NSColor(srgbRed: 0.30, green: 0.44, blue: 0.62, alpha: 0.52)
                        : NSColor(srgbRed: 0.90, green: 0.95, blue: 1.00, alpha: 0.72))
            .setFill()
        wash.fill()

        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2 - 0.5,
                                yRadius: bounds.height / 2 - 0.5)
        edge.lineWidth = 1
        NSColor.white.withAlphaComponent(Palette.isDark ? 0.25 : 0.60).setStroke()
        edge.stroke()

        var hues: [NSColor] = []
        if counts.waiting > 0 { hues.append(.systemOrange) }
        if counts.working > 0 { hues.append(.systemGreen) }
        if hues.isEmpty { hues = [Palette.meta] }
        let parts = Array(zip(NubView.labels(for: counts), hues))

        // Numbers in the text colour, the dot in the state's own hue: the dot
        // is the only colour on the tab, so it carries the meaning alone.
        let attrs: (NSColor) -> [NSAttributedString.Key: Any] = { _ in
            [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
             .foregroundColor: Palette.title, .kern: 0.2]
        }
        let dot = NubView.dot
        let tight = NubView.tight
        let apart = NubView.apart
        var x = (bounds.width - NubView.run(of: parts.map { $0.0 })) / 2

        // A dot before each count, so the two states are told apart by shape
        // as well as by colour.
        for (text, colour) in parts {
            let style = attrs(colour)
            let size = (text as NSString).size(withAttributes: style)
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - dot) / 2,
                                        width: dot, height: dot)).fill()
            x += dot + tight
            (text as NSString).draw(
                at: NSPoint(x: x, y: (bounds.height - size.height) / 2),
                withAttributes: style)
            x += size.width + apart
        }
    }
}

/// The one window everything lives in.
///
/// Clicks in the gaps between cards, and in the margin the shadows fall into,
/// pass through: the dock sits over the desktop, and a column of dead ground
/// around every row would swallow them.
final class DockContent: NSView {

    private var shadows: [CALayer] = []

    /// A shadow behind every card, kept light on purpose.
    ///
    /// The glass samples whatever is behind it, so a shadow laid there is
    /// partly drawn back into the card and greys it. Masking the card's own
    /// footprint out of the shadow did not work — the fill stayed and it came
    /// out darker still — so the shadow is simply kept faint enough that what
    /// the glass picks up costs a few levels rather than tens.
    func castShadows(_ boxes: [(NSRect, CGFloat)]) {
        wantsLayer = true
        layer?.masksToBounds = false
        // Measured: at this strength the glass gives back three or four levels
        // of brightness to the shadow behind it, against tens at the eleven
        // points and 0.18 it started on — that was what greyed the column.
        let strength: Float = Palette.isDark ? 0.24 : 0.12
        let spread: CGFloat = 5
        while shadows.count < boxes.count {
            let made = CALayer()
            made.shadowColor = NSColor.black.cgColor
            made.shadowOffset = CGSize(width: 0, height: -2)
            layer?.insertSublayer(made, at: 0)
            shadows.append(made)
        }
        while shadows.count > boxes.count { shadows.removeLast().removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, spec) in zip(shadows, boxes) {
            layer.frame = spec.0
            layer.shadowOpacity = strength
            layer.shadowRadius = spread
            layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: spec.0.size),
                                      cornerWidth: spec.1, cornerHeight: spec.1,
                                      transform: nil)
        }
        CATransaction.commit()
    }

    /// Cards go inside this when the system provides one.
    var group: NSView? {
        didSet { group?.frame = bounds }
    }

    /// Where a card belongs: inside the group if there is one.
    var cardHost: NSView { group ?? self }

    override func layout() {
        super.layout()
        group?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for card in cardHost.subviews where card.frame.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }

    /// Mouse-moved events only reach the active application, and this dock
    /// never becomes one — no event monitor sees the pointer while it is over
    /// the column. A tracking area is delivered either way.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    weak var dock: Dock?
    override func mouseEntered(with event: NSEvent) { dock?.pointerMoved() }
    override func mouseMoved(with event: NSEvent) { dock?.pointerMoved() }
    override func mouseExited(with event: NSEvent) { dock?.pointerMoved() }
}

final class DockWindow: NSPanel {
    let content = DockContent()

    /// No glass container.
    ///
    /// Apple's NSGlassEffectContainerView merges sibling glass views into one
    /// piece, which is right for the single bubble Codex uses it for. A column
    /// of ten cards merges into something much heavier: measured against the
    /// same wallpaper the cards dropped from 210 to 185, a quarter of the way
    /// back to opaque, for nothing gained.

    init(dock: Dock) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the notification banners and the Codex pet, both of which sit
        // higher than .floating and were covering the column.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false            // each card carries its own
        hidesOnDeactivate = false
        alphaValue = Palette.opacity
        content.dock = dock
        content.autoresizingMask = [.width, .height]
        contentView = content
    }
}

/// Hands the dock the same menu the status item shows.
///
/// The settings live in the menu bar, which means leaving the dock to change
/// anything about it. This lets the header open that menu where the dock
/// already is.
enum Menus {
    static var build: (() -> NSMenu)?
}

final class HeaderView: NSView {
    weak var owner: HeaderCard?
    var counts: (waiting: Int, working: Int, idle: Int) = (0, 0, 0)
    private var dragging = false
    private var sizing = false
    private var hoverEdge = false
    private var hoverGrip = false
    private var hoverGear = false
    private var hoverFold = false

    override var isFlipped: Bool { true }
    /// The column's own left edge. Dragged left it widens, since the dock is
    /// pinned by its right edge and grows into the desktop beside it. Checked
    /// before the grip, which starts at the same corner and would otherwise
    /// swallow every attempt to catch such a narrow strip.
    private var edgeRect: NSRect { NSRect(x: 0, y: 0, width: 9, height: bounds.height) }
    private var gripRect: NSRect { NSRect(x: 0, y: 0, width: 26, height: bounds.height) }
    private var gearRect: NSRect {
        NSRect(x: 26, y: 0, width: 22, height: bounds.height)
    }
    /// Only while the column is out. In the folded mode the tab underneath
    /// does the opening and closing, and a second control for it up here just
    /// asked the same question twice.
    private var foldRect: NSRect {
        Settings.shared.collapsed ? .zero
            : NSRect(x: 48, y: 0, width: 22, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edge = edgeRect.contains(point)
        let grip = !edge && gripRect.contains(point)
        let gear = gearRect.contains(point)
        let fold = foldRect.contains(point)
        if edge != hoverEdge || grip != hoverGrip || gear != hoverGear || fold != hoverFold {
            hoverEdge = edge
            hoverGrip = grip
            hoverGear = gear
            hoverFold = fold
            needsDisplay = true
        }
        // Set by hand rather than through a cursor rect: the dock is a
        // non-activating panel, and AppKit only keeps cursor rects for the
        // window it thinks is in front.
        if edge { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        hoverEdge = false
        hoverGrip = false
        hoverGear = false
        hoverFold = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if foldRect.contains(point) {
            owner?.fold()
            return
        }
        if gearRect.contains(point), let menu = Menus.build?() {
            // Upwards. The header sits on top of the stack, and this view is
            // flipped, so opening downwards would lay the menu straight over
            // the rows it is meant to be filtering.
            menu.popUp(positioning: nil,
                       at: NSPoint(x: gearRect.minX, y: gearRect.minY - 4),
                       in: self)
            return
        }
        sizing = edgeRect.contains(point)
        dragging = !sizing && gripRect.contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        if sizing {
            owner?.resize(by: -event.deltaX)     // leftwards is wider
            return
        }
        guard dragging else { return }
        owner?.drag(by: CGSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        sizing = false
    }

    override func draw(_ dirtyRect: NSRect) {
        // Wiped back to nothing first, the same way a row is.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        Palette.backing.setFill()
        bounds.fill()
        Rim.draw(in: bounds, corner: bounds.height / 2)

        // Always drawn, not just on hover: a control that only appears once
        // the pointer is already on it is a control nobody finds. It brightens
        // under the pointer instead.
        NSColor.labelColor.withAlphaComponent(hoverEdge || sizing ? 0.62 : 0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: bounds.height / 2 - 6,
                                         width: 2, height: 12),
                     xRadius: 1, yRadius: 1).fill()

        NSColor.labelColor.withAlphaComponent(hoverGrip ? 0.6 : 0.3).setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(column) * 4,
                                            y: bounds.height / 2 - 5 + CGFloat(row) * 4,
                                            width: 2.5, height: 2.5)).fill()
            }
        }

        if !Settings.shared.collapsed {
            let fold = Marks.symbol("arrow.down.right.and.arrow.up.left", size: 9,
                                    description: "접어두기")
            Marks.tinted(fold,
                         NSColor.labelColor.withAlphaComponent(hoverFold ? 0.7 : 0.32),
                         key: "fold\(hoverFold)")
                .draw(in: NSRect(x: foldRect.midX - fold.size.width / 2,
                                 y: bounds.height / 2 - fold.size.height / 2,
                                 width: fold.size.width, height: fold.size.height))
        }

        let gear = Marks.symbol("slider.horizontal.3", size: 10,
                                description: "설정")
        Marks.tinted(gear, NSColor.labelColor.withAlphaComponent(hoverGear ? 0.7 : 0.32),
                     key: "gear\(hoverGear)")
            .draw(in: NSRect(x: gearRect.midX - gear.size.width / 2,
                             y: bounds.height / 2 - gear.size.height / 2,
                             width: gear.size.width, height: gear.size.height))

        // The counts live on the folded tab, where they are the only thing
        // left to read. Repeating them over a column you can already see was
        // saying the same thing twice.
    }
}

// MARK: - the dock

final class Dock {
    private var rows: [RowCard] = []
    private lazy var window = DockWindow(dock: self)
    private lazy var header = HeaderCard(dock: self)
    private lazy var more = MoreCard(dock: self)
    private lazy var nub = NubCard(dock: self)

    /// Whether the column is showing while folded, because the pointer is on
    /// the tab. It lasts as long as the pointer does, so it is held here
    /// rather than saved.
    private var peeking = false

    /// How far back the column currently reaches. Held here rather than in
    /// settings: it lasts as long as the question that made you press it.
    private var reach = SessionStore.staleAfter
    private var older = 0
    private var shrinkTimer: Timer?

    /// How long a widened column stays open once nothing is touching it.
    private static let shrinkAfter: TimeInterval = 12
    private var hoverTimer: Timer?
    private var reloadTimer: Timer?
    private var lastCounts: (waiting: Int, working: Int, idle: Int) = (0, 0, 0)

    func start() {
        window.content.cardHost.addSubview(header)
        window.content.cardHost.addSubview(more)
        window.content.cardHost.addSubview(nub)
        reload()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
        // Pointer still, cards moving underneath it: no tracking area reports
        // that. A backstop only, so it can tick slowly.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) {
            [weak self] _ in
            self?.updateHover()
        }
    }

    func stop() {
        shrinkTimer?.invalidate()
        hoverTimer?.invalidate()
        reloadTimer?.invalidate()
        window.orderOut(nil)
    }

    // MARK: data

    func reload() {
        let sessions = SessionStore.load(reach: reach)
            .filter { Settings.shared.showIdle || $0.state != "idle" }
            .filter { Settings.shared.showDelegated || !$0.isDelegated }
            .filter { !Settings.shared.isHidden(source: $0.sourceKey) }
            .filter { !Settings.shared.isResolved($0.id, updated: $0.updated) }

        // Rows are sorted by how recently they moved, so the order churns every
        // few seconds. Re-sorting while the pointer is on a row yanks it away
        // mid-hover, which is what made the whole column judder. Hold the
        // order still until the pointer leaves.
        if rows.contains(where: { $0.isOpen }) {
            for session in sessions {
                rows.first { $0.session?.id == session.id }?.update(session)
            }
            return
        }

        var kept: [RowCard] = []
        for session in sessions {
            if let existing = rows.first(where: { $0.session?.id == session.id }) {
                existing.update(session)
                kept.append(existing)
            } else {
                let card = RowCard(session: session, dock: self)
                card.alphaValue = 0
                window.content.cardHost.addSubview(card)
                kept.append(card)
            }
        }
        for gone in rows where !kept.contains(where: { $0 === gone }) {
            gone.removeFromSuperview()
        }
        rows = kept

        // Counted by the mark each row actually wears, not by its raw state.
        // "waiting" covers both a fresh reply and one left for hours, and the
        // rows already draw the second as a grey dash; the tab counted it
        // orange anyway, so it said twelve were asking while one was.
        let counts = (
            waiting: sessions.filter { $0.mark == .yourTurn }.count,
            working: sessions.filter { $0.mark == .working }.count,
            idle: sessions.filter { $0.mark == .parked }.count
        )
        lastCounts = counts
        header.set(counts: counts)
        nub.set(counts: counts)

        // The button only earns its row when there is something behind it.
        older = SessionStore.countBeyond(reach)
        let next = SessionStore.reaches.first { $0 > reach }
        let widened = reach > SessionStore.staleAfter
        if older > 0, let next {
            more.set(label: "\(Int(next / 3600))시간 전까지 더 보기  ·  \(older)건",
                     home: widened)
            more.isHidden = false
        } else if widened {
            more.set(label: "\(Int(reach / 3600))시간 전까지 모두 보는 중", home: true)
            more.isHidden = false
        } else {
            more.isHidden = true
        }
        if !window.isVisible { window.orderFrontRegardless() }

        layout(animated: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.duration
            for card in rows where card.alphaValue < Palette.opacity {
                card.animator().alphaValue = Palette.opacity
            }
        }
    }

    /// Redraw every card, for a change that alters how they look but not
    /// where they are.
    func repaint() {
        window.alphaValue = Palette.opacity
        header.applyMaterial()
        header.set(counts: lastCounts)
        rows.forEach { card in
            card.applyMaterial()
            card.refresh()
        }
    }

    func pointerMoved() { updateHover() }

    private func updateHover() {
        guard window.isVisible else { return }
        guard !rows.isEmpty, !(Settings.shared.collapsed && !peeking) else { return }
        if reach > SessionStore.staleAfter { armShrink() }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)

        // Half the gap counts as part of the card on either side. A pointer
        // crossing the clear air between two cards belonged to neither, so the
        // open one shut and the next opened, and the column sprang about while
        // nothing had really changed.
        let reach = Layout.gap / 2
        let target = rows.first {
            $0.frame.insetBy(dx: 0, dy: -reach).contains(point)
        }
        var changed = false
        for card in rows {
            if card.setOpen(card === target) { changed = true }
            card.setResolveHover(card === target && card.resolveHitBox().contains(point))
        }
        if changed { layout(animated: true) }
    }

    // MARK: layout

    /// Bottom-right by default, stacked upwards: the newest and most urgent
    /// sits closest to the corner, where the eye already is.
    func layout(animated: Bool) {
        guard let screen = Screens.target else { return }
        let offset = Settings.shared.anchorOffset
        let pad = Layout.shadowPad

        // The window is sized for the tallest the column can get, so opening a
        // row never resizes it. A window resize is the app's own work, frame
        // by frame; the cards inside are layers, and moving them is not.
        let right = screen.visibleFrame.maxX - Layout.inset - offset.width
        let bottom = screen.visibleFrame.minY + Layout.inset + offset.height

        var stack = Layout.headerHeight + Layout.gap
        if Settings.shared.collapsed { stack += NubCard.size.height + Layout.gap }
        if !more.isHidden { stack += Layout.headerHeight + Layout.gap }
        for _ in rows { stack += Layout.rowHeight + Layout.gap }
        let tallest = stack + Layout.detailMax
        let size = NSSize(width: Layout.width + pad * 2, height: tallest + pad * 2)

        let origin = NSPoint(x: right - Layout.width - pad, y: bottom - pad)
        let wanted = NSRect(origin: origin, size: size)
        if window.frame != wanted { window.setFrame(wanted, display: true) }

        // Folded away, the column is a single tab in the corner it grows from.
        // The tab stays put once the column is open, since pressing it again
        // is how it closes — taking it away left nothing to press.
        let collapsed = Settings.shared.collapsed
        let folded = collapsed && !peeking
        nub.isHidden = !collapsed
        header.isHidden = folded
        rows.forEach { $0.isHidden = folded }
        if folded { more.isHidden = true }

        if folded {
            let span = NubCard.width(for: lastCounts)
            let tab = NSRect(x: pad + Layout.width - span, y: pad,
                             width: span, height: NubCard.size.height)
            let wanted = NSRect(x: right - Layout.width - pad, y: bottom - pad,
                                width: Layout.width + pad * 2,
                                height: NubCard.size.height + pad * 2)
            if window.frame != wanted { window.setFrame(wanted, display: true) }
            nub.frame = tab
            nub.set(counts: lastCounts)
            window.content.castShadows([(tab, NubCard.size.height / 2)])
            return
        }

        var y = pad
        // The tab keeps the bottom of the column when the mode is on.
        let tab = collapsed
            ? NSRect(x: pad + Layout.width - NubCard.width(for: lastCounts), y: y,
                     width: NubCard.width(for: lastCounts), height: NubCard.size.height)
            : nil
        if tab != nil { y += NubCard.size.height + Layout.gap }

        // Below the oldest row, which is where the column runs out.
        let ledge = more.isHidden ? nil
            : NSRect(x: pad, y: y, width: Layout.width, height: Layout.headerHeight)
        if ledge != nil { y += Layout.headerHeight + Layout.gap }

        var targets: [(RowCard, NSRect)] = []
        for card in rows.reversed() {
            let height = (card.isOpen ? card.expandedSize : card.collapsedSize).height
            targets.append((card, NSRect(x: pad, y: y, width: Layout.width, height: height)))
            y += height + Layout.gap
        }
        let crown = NSRect(x: pad, y: y, width: Layout.width, height: Layout.headerHeight)

        let moved = targets.filter { $0.0.targetFrame != $0.1 }
        moved.forEach { $0.0.setTarget($0.1) }
        guard !moved.isEmpty || header.frame != crown else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Layout.duration : 0
            context.allowsImplicitAnimation = false
            if animated {
                // Off the mark immediately: easing in as well made a card feel
                // like it was deciding whether to follow.
                context.timingFunction =
                    CAMediaTimingFunction(controlPoints: 0.05, 0.8, 0.2, 1)
            }
            if animated {
                self.header.animator().frame = crown
                if let ledge { self.more.animator().frame = ledge }
                if let tab { self.nub.animator().frame = tab }
                for (card, box) in moved { card.animator().frame = box }
            } else {
                self.header.frame = crown
                if let ledge { self.more.frame = ledge }
                if let tab { self.nub.frame = tab }
                for (card, box) in moved { card.frame = box }
            }
        }

        // Shadows only where the glass cannot draw its own.
        //
        // NSGlassEffectView carries a shadow already — measured, the twenty
        // points outside a card sit eight levels darker than the desktop
        // further out. Adding another put black behind the cards, which is
        // exactly where the glass samples from, and every card refracted its
        // neighbours' shadow and came out grey. Codex splits it the same way:
        // `0 0 transparent` under native glass, `0 3px 16px` in the CSS
        // fallback.
        var boxes: [(NSRect, CGFloat)] = [(crown, Layout.headerHeight / 2)]
        if let ledge { boxes.append((ledge, Layout.headerHeight / 2)) }
        if let tab { boxes.append((tab, NubCard.size.height / 2)) }
        for (card, box) in targets { boxes.append((box, Layout.corner)) }
        window.content.castShadows(boxes)

    }

    /// One rung further back, or all the way home from the last one.
    func reachFurther() {
        guard let next = SessionStore.reaches.first(where: { $0 > reach }), older > 0
        else { return }
        reach = next
        reload()
        armShrink()
    }

    /// Open the column from the tab.
    ///
    /// Hovering used to do this, which meant the column appeared whenever the
    /// pointer crossed the corner on its way somewhere else. A press says you
    /// meant it; the arrow in the header puts it back.
    func openFromTab() {
        guard Settings.shared.collapsed else { return }
        peeking.toggle()
        if !peeking { rows.forEach { $0.setOpen(false) } }
        reload()
    }

    /// Fold the column away, or bring it back for good.
    func toggleCollapsed() {
        if Settings.shared.collapsed && peeking {
            // Opened from the tab: the arrow puts it back rather than leaving
            // the mode, which is what someone reaching for it there means.
            peeking = false
        } else {
            Settings.shared.collapsed.toggle()
            peeking = false
        }
        rows.forEach { $0.setOpen(false) }
        reload()
    }

    /// Straight back to the usual few hours, however far it climbed.
    func reachHome() {
        shrinkTimer?.invalidate()
        shrinkTimer = nil
        reach = SessionStore.staleAfter
        reload()
    }

    /// Start the column folding back on its own.
    ///
    /// Reaching further is for finding one thing, so the extra rows go away by
    /// themselves rather than being left to push everything else off screen.
    /// The countdown restarts while the pointer is on the dock, since folding
    /// the list away under someone reading it is the one thing worse than
    /// leaving it open.
    private func armShrink() {
        shrinkTimer?.invalidate()
        shrinkTimer = nil
        guard reach > SessionStore.staleAfter else { return }
        shrinkTimer = Timer.scheduledTimer(withTimeInterval: Dock.shrinkAfter,
                                           repeats: false) { [weak self] _ in
            guard let self, self.reach > SessionStore.staleAfter else { return }
            self.reach = SessionStore.staleAfter
            self.reload()
        }
    }

    /// Widen or narrow the column, keeping its pinned right edge where it is.
    func resizeWidth(by delta: CGFloat) {
        let wanted = Settings.shared.dockWidth + Double(delta)
        guard let screen = Screens.target else { return }
        // Never wider than the desktop it has left of the anchor.
        let room = Double(screen.visibleFrame.width
                          - Layout.inset * 2 - Settings.shared.anchorOffset.width)
        Settings.shared.dockWidth = min(wanted, room)
        layout(animated: false)
    }

    /// Set outright, from the menu.
    func setWidth(_ points: Double) {
        Settings.shared.dockWidth = points
        layout(animated: true)
    }

    /// Rows have to be rebuilt: their own height is fixed at the size they
    /// were made, and only a fresh pass reads the new one.
    func setRowHeight(_ points: Double) {
        Settings.shared.rowHeight = points
        rows.forEach { $0.refresh() }
        layout(animated: true)
    }

    func moveAnchor(by delta: CGSize) {
        guard let screen = Screens.target else { return }
        var offset = Settings.shared.anchorOffset
        offset.width = min(max(0, offset.width - delta.width),
                           screen.visibleFrame.width - Layout.width - Layout.inset)
        offset.height = min(max(0, offset.height - delta.height),
                            screen.visibleFrame.height - 160)
        Settings.shared.anchorOffset = offset
        layout(animated: false)
    }

    func activate(_ session: Session) {
        // Opening a card is the acknowledgement; the ripple has done its job.
        Settings.shared.acknowledge(session.id, updated: session.updated)
        Route.open(session)
        rows.first { $0.session?.id == session.id }?.refresh()
    }

    /// Clear a session away until it does something new.
    func resolve(_ session: Session) {
        Settings.shared.resolve(session.id, updated: session.updated)
        reload()
    }
}
