import Foundation
import ApplicationServices

// MARK: - Text selection (select_text)
//
// Selects text inside an accessibility text element by writing AXSelectedTextRange.
// Nothing is ever pressed, clicked, or typed: the only writes are a best-effort AXFocused
// and the selection range itself, and the range is read back before success is claimed.

enum TextSelectionMode: String, CaseIterable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}

enum TextSelectionError: Error, Equatable {
    case invalidArgument(String)
    case emptyText
    case invalidOccurrence(Int)
    case noMatch
    case ambiguous(count: Int)
    case occurrenceOutOfRange(requested: Int, matches: Int)

    var message: String {
        switch self {
        case .invalidArgument(let message):
            return message
        case .emptyText:
            return "select_text needs a non-empty 'text'."
        case .invalidOccurrence(let occurrence):
            return "occurrence must be an integer >= 1 (got \(occurrence))."
        case .noMatch:
            return "No match for the requested text in the element's value. Matching is exact and case-sensitive against the full value, and prefix/suffix must be immediately adjacent. Nothing was selected."
        case .ambiguous(let count):
            return "Ambiguous: the text matches \(count) times. Pass prefix and/or suffix (the text immediately before/after it) or occurrence (1-\(count)) to pick one. Nothing was selected."
        case .occurrenceOutOfRange(let requested, let matches):
            return "occurrence \(requested) requested but only \(matches) match\(matches == 1 ? "" : "es") found. Nothing was selected."
        }
    }
}

struct TextSelectionRequest: Equatable {
    let text: String
    let prefix: String?
    let suffix: String?
    let occurrence: Int?
    let mode: TextSelectionMode
}

/// Finds the UTF-16 range to select (AX text ranges are UTF-16 based).
///
/// Every occurrence of `text` is collected, overlapping ones included, so ambiguity is
/// judged conservatively. Matches that start or end inside a composed character sequence
/// are discarded. `prefix`/`suffix` keep only matches immediately preceded/followed by
/// those strings; `occurrence` (1-based) then picks among what remains. Without an
/// occurrence, more than one remaining match is an error rather than a guess.
func textSelectionRange(
    in value: String,
    text: String,
    prefix: String? = nil,
    suffix: String? = nil,
    occurrence: Int? = nil,
    mode: TextSelectionMode = .text
) -> Result<NSRange, TextSelectionError> {
    guard !text.isEmpty else { return .failure(.emptyText) }
    if let occurrence, occurrence < 1 { return .failure(.invalidOccurrence(occurrence)) }

    let haystack = value as NSString
    let length = haystack.length
    let prefix = prefix.flatMap { $0.isEmpty ? nil : $0 }
    let suffix = suffix.flatMap { $0.isEmpty ? nil : $0 }

    func isCharacterBoundary(_ offset: Int) -> Bool {
        offset == 0 || offset == length
            || haystack.rangeOfComposedCharacterSequence(at: offset).location == offset
    }
    func anchoredMatch(_ needle: String, in range: NSRange, atEnd: Bool) -> Bool {
        guard range.length > 0 else { return false }
        let options: NSString.CompareOptions = atEnd ? [.anchored, .backwards] : [.anchored]
        return haystack.range(of: needle, options: options, range: range).location != NSNotFound
    }

    var matches: [NSRange] = []
    var searchStart = 0
    while searchStart < length {
        let found = haystack.range(
            of: text,
            options: [],
            range: NSRange(location: searchStart, length: length - searchStart)
        )
        guard found.location != NSNotFound, found.length > 0 else { break }
        // Resume one composed character later so overlapping matches are counted too.
        searchStart = NSMaxRange(haystack.rangeOfComposedCharacterSequence(at: found.location))

        let end = NSMaxRange(found)
        guard isCharacterBoundary(found.location), isCharacterBoundary(end) else { continue }
        if let prefix,
           !anchoredMatch(prefix, in: NSRange(location: 0, length: found.location), atEnd: true) {
            continue
        }
        if let suffix,
           !anchoredMatch(suffix, in: NSRange(location: end, length: length - end), atEnd: false) {
            continue
        }
        matches.append(found)
    }

    guard !matches.isEmpty else { return .failure(.noMatch) }
    let chosen: NSRange
    if let occurrence {
        guard occurrence <= matches.count else {
            return .failure(.occurrenceOutOfRange(requested: occurrence, matches: matches.count))
        }
        chosen = matches[occurrence - 1]
    } else {
        guard matches.count == 1 else { return .failure(.ambiguous(count: matches.count)) }
        chosen = matches[0]
    }

    switch mode {
    case .text:
        return .success(chosen)
    case .cursorBefore:
        return .success(NSRange(location: chosen.location, length: 0))
    case .cursorAfter:
        return .success(NSRange(location: NSMaxRange(chosen), length: 0))
    }
}

/// Validates the select_text arguments other than app and element_index. Pure.
func parseTextSelectionRequest(_ args: [String: Any]) -> Result<TextSelectionRequest, TextSelectionError> {
    guard let text = args["text"] as? String else {
        return .failure(.invalidArgument("select_text needs string 'text'."))
    }
    guard !text.isEmpty else { return .failure(.emptyText) }

    func optionalString(_ key: String) -> Result<String?, TextSelectionError> {
        guard let raw = args[key], !(raw is NSNull) else { return .success(nil) }
        guard let value = raw as? String else {
            return .failure(.invalidArgument("\(key) must be a string."))
        }
        return .success(value)
    }
    let prefix: String?
    switch optionalString("prefix") {
    case .success(let value): prefix = value
    case .failure(let error): return .failure(error)
    }
    let suffix: String?
    switch optionalString("suffix") {
    case .success(let value): suffix = value
    case .failure(let error): return .failure(error)
    }

    var occurrence: Int?
    if let raw = args["occurrence"], !(raw is NSNull) {
        guard let value = strictJSONInteger(raw), value >= 1 else {
            return .failure(.invalidArgument("occurrence must be an integer >= 1."))
        }
        occurrence = value
    }

    var mode = TextSelectionMode.text
    if let raw = args["selection"], !(raw is NSNull) {
        guard let name = raw as? String, let parsed = TextSelectionMode(rawValue: name) else {
            let allowed = TextSelectionMode.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure(.invalidArgument("selection must be one of: \(allowed)."))
        }
        mode = parsed
    }

    return .success(TextSelectionRequest(
        text: text,
        prefix: prefix,
        suffix: suffix,
        occurrence: occurrence,
        mode: mode
    ))
}

/// element_index arrives as a non-negative integer string (per the schema); a JSON
/// integer is tolerated. Booleans and fractional numbers are rejected.
func textElementIndex(_ raw: Any?) -> Int? {
    if let string = raw as? String {
        guard let value = Int(string), value >= 0 else { return nil }
        return value
    }
    guard let value = strictJSONInteger(raw), value >= 0 else { return nil }
    return value
}

private func axIsSettable(_ el: AXUIElement, _ attribute: String) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(el, attribute as CFString, &settable) == .success
        && settable.boolValue
}

private func axAdvertises(_ el: AXUIElement, _ attribute: String) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success else { return false }
    return ((names as? [String]) ?? []).contains(attribute)
}

private func axIsFocused(_ el: AXUIElement) -> Bool {
    (axCopy(el, kAXFocusedAttribute) as? Bool) == true
}

private func axSelectedTextRange(_ el: AXUIElement) -> CFRange? {
    guard let raw = axCopy(el, kAXSelectedTextRangeAttribute),
          CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    var range = CFRange()
    guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
    return range
}

private func focusTextElementIfPossible(_ el: AXUIElement) {
    if axIsFocused(el) { return }
    guard axIsSettable(el, kAXFocusedAttribute) else { return }
    if AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
        usleep(60_000)
    }
}

private func quotedForMessage(_ text: String) -> String {
    let limit = 80
    let clipped = text.count > limit ? String(text.prefix(limit)) + "…" : text
    return String(reflecting: clipped)
}

func toolSelectText(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    let request: TextSelectionRequest
    switch parseTextSelectionRequest(args) {
    case .success(let parsed): request = parsed
    case .failure(let error): return toolText(error.message, isError: true)
    }
    guard let idx = textElementIndex(args["element_index"]) else {
        return toolText(
            "select_text needs a valid element_index (a non-negative integer string from this app's last get_app_state).",
            isError: true
        )
    }
    guard let el = registryElement(idx, forPid: pid) else { return staleIndexError(idx) }

    let role = axStr(el, kAXRoleAttribute) ?? "AXUnknown"
    let subrole = axStr(el, kAXSubroleAttribute)
    let target = "\(role) [\(idx)]"
    if role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole {
        return toolText("\(target) is a secure text field; select_text does not operate on password fields. Nothing was changed.", isError: true)
    }
    // AppKit text fields only make AXSelectedTextRange settable while they are being edited,
    // so an unfocused text element that advertises the attribute is allowed through here and
    // re-checked after focusing. Anything else is refused before any write.
    let selectionSettable = axIsSettable(el, kAXSelectedTextRangeAttribute)
    let settableAfterFocus = !axIsFocused(el)
        && axIsSettable(el, kAXFocusedAttribute)
        && axAdvertises(el, kAXSelectedTextRangeAttribute)
    guard selectionSettable || settableAfterFocus else {
        return toolText("\(target) does not allow setting a text selection (AXSelectedTextRange is not settable). Nothing was changed.", isError: true)
    }
    guard let value = axCopy(el, kAXValueAttribute) as? String else {
        return toolText("\(target) has no readable text value. Nothing was changed.", isError: true)
    }

    let range: NSRange
    switch textSelectionRange(
        in: value,
        text: request.text,
        prefix: request.prefix,
        suffix: request.suffix,
        occurrence: request.occurrence,
        mode: request.mode
    ) {
    case .success(let found): range = found
    case .failure(let error): return toolText("\(target): \(error.message)", isError: true)
    }

    return controlled("Selecting text", appPID: pid, targetQuartz: elementFrame(idx)) {
        if cancelFlag.value { return toolText("Cancelled (Esc).") }
        focusTextElementIfPossible(el)
        if cancelFlag.value { return toolText("Cancelled (Esc).") }
        guard axIsSettable(el, kAXSelectedTextRangeAttribute) else {
            return toolText("\(target) does not allow setting a text selection even after focusing it (AXSelectedTextRange is not settable). It may now have keyboard focus; no text was selected.", isError: true)
        }
        guard (axCopy(el, kAXValueAttribute) as? String) == value else {
            return toolText("The text in \(target) changed when it was focused; no text was selected. Call get_app_state and retry.", isError: true)
        }

        var requested = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &requested) else {
            return toolText("Could not encode the selection range. Nothing was selected.", isError: true)
        }
        let setResult = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange)
        guard setResult == .success else {
            return toolText("\(target) rejected the selection (AXError \(setResult.rawValue)).", isError: true)
        }

        // Some apps apply the selection asynchronously; give the read-back a short window.
        var actual = axSelectedTextRange(el)
        for _ in 0..<10 {
            if let current = actual,
               current.location == requested.location, current.length == requested.length { break }
            if cancelFlag.value { return toolText("Cancelled (Esc).") }
            usleep(30_000)
            actual = axSelectedTextRange(el)
        }
        guard let actual else {
            return toolText("The app did not report a selection for \(target) after setting it; the selection could not be verified.", isError: true)
        }
        guard actual.location == requested.location, actual.length == requested.length else {
            return toolText(
                "The app did not accept the selection: requested characters \(requested.location)–\(requested.location + requested.length), but \(target) reports \(actual.location)–\(actual.location + actual.length).",
                isError: true
            )
        }
        guard (axCopy(el, kAXValueAttribute) as? String) == value else {
            return toolText("The text in \(target) changed while selecting, so the selection may not cover the requested text. Call get_app_state and retry.", isError: true)
        }

        let quoted = quotedForMessage(request.text)
        switch request.mode {
        case .text:
            return toolText("Selected \(quoted) (characters \(range.location)–\(NSMaxRange(range))) in \(target).")
        case .cursorBefore:
            return toolText("Placed the caret before \(quoted) (character \(range.location)) in \(target).")
        case .cursorAfter:
            return toolText("Placed the caret after \(quoted) (character \(range.location)) in \(target).")
        }
    }
}
