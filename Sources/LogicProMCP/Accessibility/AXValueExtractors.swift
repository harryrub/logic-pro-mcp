import ApplicationServices
import Foundation

/// Extract typed values from AX elements.
/// These handle the various ways Logic Pro represents values in its AX tree.
enum AXValueExtractors {
    /// Extract a numeric value from a slider (volume fader, pan knob, etc.)
    /// Returns the AXValue as a Double, or nil if unavailable.
    static func extractSliderValue(_ element: AXUIElement) -> Double? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // AXSlider values can come as NSNumber or CFNumber
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        // Try string-based value and parse
        if let str = value as? String, let parsed = Double(str) {
            return parsed
        }
        return nil
    }

    /// Extract a text value from a static text or text field element.
    /// Used for tempo display, position readout, track names, etc.
    static func extractTextValue(_ element: AXUIElement) -> String? {
        // Try kAXValueAttribute first (text fields, static text)
        if let value = AXHelpers.getValue(element) as? String {
            return value
        }
        // Fallback to kAXTitleAttribute
        return AXHelpers.getTitle(element)
    }

    /// Extract a boolean state from a button or checkbox element.
    /// For toggle buttons (mute, solo, arm, cycle, metronome), the value
    /// indicates pressed/active state.
    static func extractButtonState(_ element: AXUIElement) -> Bool? {
        guard let value = AXHelpers.getValue(element) else { return nil }
        // Toggle buttons typically report 0/1 as NSNumber
        if let number = value as? NSNumber {
            return number.boolValue
        }
        // Some buttons use string "1"/"0"
        if let str = value as? String {
            return str == "1" || str.lowercased() == "true"
        }
        return nil
    }

    /// Extract checkbox state (a variant of button state, but checks kAXValueAttribute specifically).
    static func extractCheckboxState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXValueAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        return nil
    }

    /// Extract the selected state of an element.
    static func extractSelectedState(_ element: AXUIElement) -> Bool? {
        guard let value: AnyObject = AXHelpers.getAttribute(element, kAXSelectedAttribute) else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    /// Extract slider range (min/max) for interpreting fader values.
    struct SliderRange {
        let min: Double
        let max: Double
    }

    static func extractSliderRange(_ element: AXUIElement) -> SliderRange? {
        guard let minVal: AnyObject = AXHelpers.getAttribute(element, kAXMinValueAttribute),
              let maxVal: AnyObject = AXHelpers.getAttribute(element, kAXMaxValueAttribute),
              let min = (minVal as? NSNumber)?.doubleValue,
              let max = (maxVal as? NSNumber)?.doubleValue else {
            return nil
        }
        return SliderRange(min: min, max: max)
    }

    /// Read a track header and extract its basic state.
    ///
    /// Expects `header` to be an AXLayoutItem from Logic's "Tracks header"
    /// group — its own AXDescription is of the form `Track N "Name"` and its
    /// children include AXCheckBox elements with descriptions "Mute", "Solo",
    /// "Record Enable", "Input Monitoring" plus an AXRadioButton "Has Focus".
    static func extractTrackState(from header: AXUIElement, index: Int) -> TrackState {
        let name = extractTrackName(from: header)
        let muted = extractCheckBoxStateByDescription(from: header, description: "Mute") ?? false
        let soloed = extractCheckBoxStateByDescription(from: header, description: "Solo") ?? false
        let armed = extractCheckBoxStateByDescription(from: header, description: "Record Enable") ?? false
        let selected = extractTrackSelection(from: header) ?? false
        let trackType = inferTrackType(from: header)

        return TrackState(
            id: index,
            name: name,
            type: trackType,
            isMuted: muted,
            isSoloed: soloed,
            isArmed: armed,
            isSelected: selected,
            volume: 0.0,
            pan: 0.0,
            color: extractTrackColor(from: header)
        )
    }

    /// Read transport bar elements and build a TransportState.
    static func extractTransportState(from transport: AXUIElement) -> TransportState {
        var state = TransportState()

        // Find and read transport button states
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            let desc = AXHelpers.getDescription(button) ?? AXHelpers.getTitle(button) ?? ""
            let pressed = extractButtonState(button) ?? false
            let descLower = desc.lowercased()

            if descLower.contains("play") {
                state.isPlaying = pressed
            } else if descLower.contains("record") && !descLower.contains("arm") {
                state.isRecording = pressed
            } else if descLower.contains("cycle") || descLower.contains("loop") {
                state.isCycleEnabled = pressed
            } else if descLower.contains("metronome") || descLower.contains("click") {
                state.isMetronomeEnabled = pressed
            }
        }

        // Find text fields for tempo, position
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXStaticTextRole, maxDepth: 4)
        for text in texts {
            guard let value = extractTextValue(text) else { continue }
            let desc = AXHelpers.getDescription(text) ?? ""
            let descLower = desc.lowercased()

            if descLower.contains("tempo") || descLower.contains("bpm") {
                if let tempo = Double(value.replacingOccurrences(of: " BPM", with: "")) {
                    state.tempo = tempo
                }
            } else if descLower.contains("position") || value.contains(".") && value.contains(":") == false {
                // Bar.Beat.Division.Tick format
                if value.filter({ $0 == "." }).count >= 2 {
                    state.position = value
                }
            } else if value.contains(":") {
                // Time format HH:MM:SS
                state.timePosition = value
            }
        }

        state.lastUpdated = Date()
        return state
    }

    // MARK: - Private helpers

    /// Extract the track's display name from its AXLayoutItem.
    ///
    /// Priority:
    /// 1. Parse the layout item's own AXDescription — Logic formats it as
    ///    `Track N "Name"`. This is the most reliable source because it's set
    ///    by Logic for VoiceOver and always reflects the visible name.
    /// 2. Fall back to the embedded AXTextField's AXDescription (which also
    ///    carries the name in current Logic versions).
    /// 3. Fall back to the text field's AXValue.
    private static func extractTrackName(from header: AXUIElement) -> String {
        if let desc = AXHelpers.getDescription(header),
           let parsed = parseTrackDescription(desc) {
            return parsed
        }
        if let field = AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 2) {
            if let desc = AXHelpers.getDescription(field), !desc.isEmpty {
                return desc
            }
            if let value = extractTextValue(field), !value.isEmpty {
                return value
            }
        }
        return AXHelpers.getTitle(header) ?? "Untitled"
    }

    /// Parse a layout-item description like `Track 12 "My Track"` and return
    /// just the quoted name. Handles both straight (") and curly (“ ”) quotes
    /// since Logic uses curly quotes in its AX descriptions.
    private static func parseTrackDescription(_ desc: String) -> String? {
        guard desc.hasPrefix("Track ") else { return nil }
        // Look for curly-quote pair first, then straight quotes.
        if let start = desc.firstIndex(of: "\u{201C}"),
           let end = desc.lastIndex(of: "\u{201D}"),
           start < end {
            return String(desc[desc.index(after: start)..<end])
        }
        if let start = desc.firstIndex(of: "\""),
           let end = desc.lastIndex(of: "\""),
           start < end {
            return String(desc[desc.index(after: start)..<end])
        }
        return nil
    }

    /// Read an AXCheckBox inside a track header by its AXDescription
    /// (e.g. "Mute", "Solo", "Record Enable"). Returns true if the checkbox
    /// is currently on. Shallow depth to avoid descending into Inspector rows
    /// that happen to contain similarly-named labels.
    private static func extractCheckBoxStateByDescription(
        from header: AXUIElement, description: String
    ) -> Bool? {
        let boxes = AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 2)
        for box in boxes where AXHelpers.getDescription(box) == description {
            if let state = extractCheckboxState(box) { return state }
            if let state = extractButtonState(box) { return state }
        }
        return nil
    }

    /// Extract whether this track is the currently-selected (focused) track.
    /// Logic puts a "Has Focus" AXRadioButton inside each track AXLayoutItem;
    /// its AXValue is 1 when focused. We don't rely on AXSelected because the
    /// AXLayoutItem itself doesn't expose selection state.
    private static func extractTrackSelection(from header: AXUIElement) -> Bool? {
        let radios = AXHelpers.findAllDescendants(of: header, role: kAXRadioButtonRole, maxDepth: 2)
        for radio in radios where AXHelpers.getDescription(radio) == "Has Focus" {
            if let state = extractButtonState(radio) { return state }
        }
        return nil
    }

    private static func inferTrackType(from header: AXUIElement) -> TrackType {
        // Attempt to infer type from icon description or element identifiers
        let desc = AXHelpers.getDescription(header)?.lowercased() ?? ""
        let title = AXHelpers.getTitle(header)?.lowercased() ?? ""
        let combined = desc + " " + title

        if combined.contains("audio") { return .audio }
        if combined.contains("instrument") || combined.contains("software") { return .softwareInstrument }
        if combined.contains("drummer") { return .drummer }
        if combined.contains("external") || combined.contains("midi") { return .externalMIDI }
        if combined.contains("aux") { return .aux }
        if combined.contains("bus") { return .bus }
        if combined.contains("master") || combined.contains("stereo out") { return .master }
        return .unknown
    }

    private static func extractTrackColor(from header: AXUIElement) -> String? {
        // Logic Pro may expose color via a custom attribute or the element's description
        let desc = AXHelpers.getDescription(header) ?? ""
        if desc.lowercased().contains("color") {
            return desc
        }
        return nil
    }
}
