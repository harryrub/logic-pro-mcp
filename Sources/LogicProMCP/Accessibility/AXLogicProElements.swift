import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot() -> AXUIElement? {
        guard let pid = ProcessUtils.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid)
    }

    /// Get the main window element.
    ///
    /// Prefers Logic's standard arrange window (subrole = AXStandardWindow) over
    /// whatever AX reports as the "main" window. AX's main-window attribute can
    /// point at a modal dialog (e.g. "Import", "Save As") when one is open,
    /// which will shadow the real arrange hierarchy and break track enumeration.
    static func mainWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        // Scan all app windows and prefer the standard arrange window.
        if let windows: CFArray = AXHelpers.getAttribute(app, kAXWindowsAttribute) {
            for i in 0..<CFArrayGetCount(windows) {
                let ptr = CFArrayGetValueAtIndex(windows, i)
                let win = unsafeBitCast(ptr, to: AXUIElement.self)
                let subrole: String? = AXHelpers.getAttribute(win, kAXSubroleAttribute)
                if subrole == "AXStandardWindow" {
                    return win
                }
            }
        }
        // Fallback to AX's main window if we couldn't pick a standard one.
        return AXHelpers.getAttribute(app, kAXMainWindowAttribute)
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro's transport is typically an AXToolbar or AXGroup near the top
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole) {
            return toolbar
        }
        // Fallback: search for a group containing transport-like buttons
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport")
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String) -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: name) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            if AXHelpers.getDescription(button) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the track header area containing individual track rows.
    ///
    /// In Logic Pro 11, the arrange window's track list lives in an `AXGroup`
    /// whose `AXDescription` is literally `"Tracks header"`. Each child of that
    /// group is an `AXLayoutItem` with description of the form
    /// `Track 1 "Kick"` — one per track visible in the arrange area.
    ///
    /// Previous implementations fell back to the first `AXOutline` / `AXList`
    /// in the window, which picked up the Library browser or the Region
    /// Inspector panel instead of the real track list. The Inspector's rows
    /// show labels like `Mute:`, `Loop:`, `Quantize:`, `Q-Swing:`, etc., which
    /// is exactly what was leaking through as track "names".
    static func getTrackHeaders() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Primary: find by the stable Apple-provided AXDescription "Tracks header".
        if let group = findDescendantByDescription(
            of: window, role: kAXGroupRole, description: "Tracks header", maxDepth: 10
        ) {
            return group
        }
        // Fallback for Logic versions that might label differently: find any
        // group whose direct children are AXLayoutItems with "Track N" descriptions.
        if let group = findFirstGroupContainingTrackLayoutItems(of: window, maxDepth: 12) {
            return group
        }
        return nil
    }

    /// Find a track header at a specific index (0-based).
    static func findTrackHeader(at index: Int) -> AXUIElement? {
        let items = allTrackHeaders()
        guard index >= 0 && index < items.count else { return nil }
        return items[index]
    }

    /// Enumerate all track header rows.
    ///
    /// Returns only children that look like actual tracks (AXLayoutItem with
    /// description prefix "Track "). This filters out any splitter/padding
    /// siblings that occasionally appear inside the "Tracks header" group.
    static func allTrackHeaders() -> [AXUIElement] {
        guard let headers = getTrackHeaders() else { return [] }
        let children = AXHelpers.getChildren(headers)
        return children.filter { child in
            guard AXHelpers.getRole(child) == "AXLayoutItem" else { return false }
            let desc = AXHelpers.getDescription(child) ?? ""
            return desc.hasPrefix("Track ")
        }
    }

    // MARK: - Mixer

    /// Find the mixer area.
    static func getMixerArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // The mixer typically appears as a distinct group/scroll area
        if let mixer = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Mixer") {
            return mixer
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Mixer")
    }

    /// Find a volume fader for a specific track index within the mixer.
    static func findFader(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Fader is an AXSlider within the channel strip
        return AXHelpers.findDescendant(of: strip, role: kAXSliderRole, maxDepth: 4)
    }

    /// Find the pan knob for a track in the mixer.
    static func findPanKnob(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = AXHelpers.getChildren(mixer)
        guard trackIndex >= 0 && trackIndex < strips.count else { return nil }
        let strip = strips[trackIndex]
        // Pan is typically the second slider or a knob-type element
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        // Convention: first slider = volume, second = pan (if present)
        return sliders.count > 1 ? sliders[1] : nil
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String]) -> AXUIElement? {
        guard var current = getMenuBar() else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Arrangement") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Arrangement")
    }

    // MARK: - Track Controls

    // Track headers expose mute/solo/arm/input-monitor as AXCheckBox children
    // of the track's AXLayoutItem. Descriptions are fixed strings that Logic
    // provides for VoiceOver: "Mute", "Solo", "Record Enable", "Input Monitoring".

    /// Find the mute checkbox on a track header.
    static func findTrackMuteButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findCheckBoxByDescription(in: header, description: "Mute")
    }

    /// Find the solo checkbox on a track header.
    static func findTrackSoloButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findCheckBoxByDescription(in: header, description: "Solo")
    }

    /// Find the record-arm checkbox on a track header. Only audio / software
    /// instrument tracks expose this; audio-only (playback) tracks don't.
    static func findTrackArmButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return findCheckBoxByDescription(in: header, description: "Record Enable")
    }

    /// Find the track name text field on a header.
    /// Logic exposes the name as an `AXTextField` whose AXDescription is the
    /// track's current display name. Returns the element for reading or editing.
    static func findTrackNameField(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 3)
    }

    /// Find the "Has Focus" radio button that represents track selection state.
    /// Each track layout item has one of these; its AXValue is 1 when the
    /// track is selected in the arrange window.
    static func findTrackFocusElement(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        let radios = AXHelpers.findAllDescendants(of: header, role: kAXRadioButtonRole, maxDepth: 2)
        return radios.first { radio in
            AXHelpers.getDescription(radio) == "Has Focus"
        }
    }

    // MARK: - Helpers

    private static func findCheckBoxByDescription(
        in element: AXUIElement, description: String
    ) -> AXUIElement? {
        // Track control checkboxes are direct children of the AXLayoutItem,
        // so a shallow scan is enough and avoids picking up Inspector controls.
        let boxes = AXHelpers.findAllDescendants(of: element, role: kAXCheckBoxRole, maxDepth: 2)
        return boxes.first { box in
            AXHelpers.getDescription(box) == description
        }
    }

    /// Recursive search for the first descendant whose role matches and whose
    /// AXDescription equals the given string. Needed because `AXHelpers.findDescendant`
    /// only matches on role/title/identifier, not description — and Logic's
    /// "Tracks header" group is identified by description.
    private static func findDescendantByDescription(
        of element: AXUIElement,
        role: String,
        description: String,
        maxDepth: Int
    ) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }
        for child in AXHelpers.getChildren(element) {
            if AXHelpers.getRole(child) == role,
               AXHelpers.getDescription(child) == description {
                return child
            }
            if let found = findDescendantByDescription(
                of: child, role: role, description: description, maxDepth: maxDepth - 1
            ) {
                return found
            }
        }
        return nil
    }

    /// Fallback locator: DFS for the first AXGroup whose direct children
    /// include at least one AXLayoutItem whose description starts with "Track ".
    /// Used in case Logic renames the "Tracks header" group in a future version.
    private static func findFirstGroupContainingTrackLayoutItems(
        of element: AXUIElement, maxDepth: Int
    ) -> AXUIElement? {
        guard maxDepth > 0 else { return nil }
        for child in AXHelpers.getChildren(element) {
            if AXHelpers.getRole(child) == kAXGroupRole {
                let grandKids = AXHelpers.getChildren(child)
                let hasTracks = grandKids.contains { gc in
                    AXHelpers.getRole(gc) == "AXLayoutItem"
                        && (AXHelpers.getDescription(gc) ?? "").hasPrefix("Track ")
                }
                if hasTracks {
                    return child
                }
            }
            if let found = findFirstGroupContainingTrackLayoutItems(
                of: child, maxDepth: maxDepth - 1
            ) {
                return found
            }
        }
        return nil
    }
}
