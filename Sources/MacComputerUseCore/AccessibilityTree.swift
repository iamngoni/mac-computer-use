import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - AX tree
var elementRegistry: [Int: AXUIElement] = [:]
struct Node { let index: Int; let depth: Int; let role: String; let label: String; let frame: CGRect?; let actions: [String] }
// AX values routinely carry newlines and runs of whitespace (a whole note body arrives as
// one AXValue). Collapse them so one element stays one line and the text budget means
// what it says — otherwise 1200 elements render as thousands of lines.
func sanitizeText(_ s: String, limit: Int) -> String {
    let collapsed = s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
        .joined(separator: " ")
        .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    guard limit != Int.max, collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
}

func describe(_ el: AXUIElement, textLimit: Int) -> (String, String) {
    let role = axStr(el, "AXRole") ?? "AXUnknown"
    var label = axStr(el, "AXTitle") ?? ""
    if label.isEmpty { label = axStr(el, "AXValue") ?? "" }
    if label.isEmpty { label = axStr(el, "AXDescription") ?? "" }
    if label.isEmpty { label = axStr(el, "AXRoleDescription") ?? "" }
    return (role, sanitizeText(label, limit: textLimit))
}
func walk(_ el: AXUIElement, depth: Int, counter: inout Int, out: inout [Node], maxNodes: Int, maxDepth: Int, textLimit: Int) {
    if counter >= maxNodes || depth > maxDepth { return }
    let idx = counter; counter += 1; elementRegistry[idx] = el
    let d = describe(el, textLimit: textLimit)
    out.append(Node(index: idx, depth: depth, role: d.0, label: d.1, frame: axFrame(el), actions: axActions(el)))
    for child in axArr(el, "AXChildren") {
        if counter >= maxNodes { break }
        walk(child, depth: depth+1, counter: &counter, out: &out, maxNodes: maxNodes, maxDepth: maxDepth, textLimit: textLimit)
    }
}
let interactiveRoles: Set<String> = [
    "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXMenuItem", "AXTabButton", "AXTab",
    "AXSlider", "AXDisclosureTriangle", "AXSearchField", "AXIncrementor", "AXSegment",
]
let noiseActions: Set<String> = ["AXScrollToVisible", "AXShowMenu", "AXRaise"]

// Only emit interactive elements and text content. Structural AXGroup/AXList nodes
// with no label and no real action are dropped. All indices stay valid (the registry
// holds every walked element); we just don't print the noise.
// Coordinates are emitted in screenshot pixel space so they line up with the image the
// model is looking at — the same space `click(x, y)` expects. Elements that fall outside
// the captured window (menu bar extras, off-screen scrollers) get no coordinate at all
// rather than a misleading one.
func renderTree(_ nodes: [Node], ctx: SnapshotContext?, maxLines: Int) -> String {
    func interesting(_ n: Node) -> Bool {
        if n.role == "AXWindow" { return true }
        if interactiveRoles.contains(n.role) { return true }
        if !n.actions.filter({ !noiseActions.contains($0) }).isEmpty { return true }
        if (n.role == "AXStaticText" || n.role == "AXHeading"), !n.label.isEmpty { return true }
        return false
    }
    func coordinate(_ f: CGRect) -> String? {
        guard let ctx = ctx else { return "@(\(Int(f.midX)),\(Int(f.midY)))" }
        let p = screenToPixel(CGPoint(x: f.midX, y: f.midY), ctx)
        let w = CGFloat(ctx.windowBounds.width) * ctx.pixelScale
        let h = CGFloat(ctx.windowBounds.height) * ctx.pixelScale
        guard p.x >= 0, p.y >= 0, p.x <= w, p.y <= h else { return nil }
        return "@(\(Int(p.x)),\(Int(p.y)))"
    }
    var out: [String] = []
    var lastInteractiveLabel = ""
    for n in nodes {
        guard interesting(n) else { continue }
        // skip static text that just repeats the interactive element above it
        if n.role == "AXStaticText", n.label == lastInteractiveLabel { continue }
        let indent = String(repeating: " ", count: min(n.depth, 14))
        var line = "[\(n.index)]\(indent)\(n.role.replacingOccurrences(of: "AX", with: ""))"
        if !n.label.isEmpty { line += " \"\(n.label)\"" }
        if let f = n.frame, let c = coordinate(f) { line += " " + c }
        let acts = n.actions.filter { !noiseActions.contains($0) }
            .map { sanitizeText($0.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: "Action", with: ""), limit: 40) }
            .filter { !$0.isEmpty }
        if !acts.isEmpty { line += " {\(acts.joined(separator: ","))}" }
        // Belt and braces: some apps hand back multi-line action names or labels, and one
        // element must stay one line for the tree to be readable and for maxLines to hold.
        out.append(sanitizeText(line, limit: Int.max))
        if interactiveRoles.contains(n.role) { lastInteractiveLabel = n.label }
        if out.count >= maxLines { out.append("… (tree truncated at \(maxLines) elements; raise max_tree_nodes or scroll the view)"); break }
    }
    return out.joined(separator: "\n")
}
