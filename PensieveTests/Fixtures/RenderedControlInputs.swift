import AppKit
import SwiftUI

/// Reads control inputs from the mounted SwiftUI graph, including composed toolbar and menu
/// content. No body or action is evaluated. SwiftUI's actual isEnabled transforms are applied
/// to the inherited environment; this checks view wiring, not native tooltip presentation.
/// Unrecognized SDK fields leave a control absent, so its owner's assertion fails.
@MainActor
enum RenderedControlInputs {
    enum Kind { case button, menu, toggle }

    struct Control {
        let kind: Kind
        let title: String
        let enabled: Bool
        let help: String?
        var rowHelp: String?
    }

    static func controls(in host: NSView) -> [Control] {
        var controls: [Control] = []
        for value in RenderedViewTestSupport.values(in: host) {
            // Toggle state comes only from the live style probe below, including ancestor fences.
            for control in read(value, enabled: true, help: nil, depth: 24)
                where control.kind != .toggle
                    && !controls.contains(where: { $0.title == control.title && $0.kind == control.kind }) {
                controls.append(control)
            }
        }
        return controls + toggleControls(in: host)
    }

    private static func texts(_ node: _ViewDebug.Data) -> [String] {
        let fields = Mirror(reflecting: node)
        let properties = fields.descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
        let own = (properties[.value] as? Text).map(RenderedViewTestSupport.strings) ?? []
        return own + (fields.descendant("childData") as? [_ViewDebug.Data] ?? []).flatMap(texts)
    }

    /// Grouped Forms lower Toggle into their row representation. A test ToggleStyle exposes
    /// the real enabled environment beside its label. Match that pair within the actual
    /// TooltipModifier's descendants, so a missing help modifier cannot pass this inspection.
    private static func toggleControls(in host: NSView) -> [Control] {
        let nodes = RenderedViewTestSupport.nodes(in: host)
        var controls: [Control] = nodes.compactMap { node in
            let fields = Mirror(reflecting: node)
            guard let value = (fields.descendant("data") as? [_ViewDebug.Property: Any])?[.value] else { return nil }
            let modifier = Mirror(reflecting: value).descendant("modifier") ?? value
            guard String(reflecting: type(of: modifier)).hasSuffix(".TooltipModifier"),
                  let text = Mirror(reflecting: modifier).descendant("text") as? Text else { return nil }
            let labels = Set(texts(node).map(unescape))
            let enabled = labels.contains("__enabled_toggle__")
            let disabled = labels.contains("__disabled_toggle__")
            let titles = labels.subtracting(["__enabled_toggle__", "__disabled_toggle__"])
            guard enabled != disabled, titles.count == 1, let title = titles.first else { return nil }
            let reason = RenderedViewTestSupport.strings(in: text).first.map(unescape)
            return Control(kind: .toggle, title: title, enabled: enabled, help: reason,
                rowHelp: hasToggleContainer(node) ? reason : nil)
        }
        // Enabled switches need no tooltip. Retain the real environment probe even when
        // a view conditionally omits help, without accepting missing help for a fenced row.
        for node in nodes {
            let properties = Mirror(reflecting: node).descendant("data") as? [_ViewDebug.Property: Any] ?? [:]
            guard let value = properties[.value], String(reflecting: type(of: value)).hasPrefix("SwiftUI.HStack<") else {
                continue
            }
            let labels = Set(texts(node).map(unescape))
            let enabled = labels.contains("__enabled_toggle__")
            let disabled = labels.contains("__disabled_toggle__")
            let titles = labels.subtracting(["__enabled_toggle__", "__disabled_toggle__"])
            guard enabled != disabled, titles.count == 1, let title = titles.first,
                  !controls.contains(where: { $0.title == title }) else { continue }
            controls.append(Control(kind: .toggle, title: title, enabled: enabled, help: nil))
        }
        return controls
    }

    /// A disabled Toggle in a grouped Form drops help over its switch. Help on a surrounding
    /// row reaches both switch and label (macOS 26 probe). Require a rendered container holding
    /// the Toggle itself, rather than a stack inside its style or label. Native hover stays manual.
    private static func hasToggleContainer(_ node: _ViewDebug.Data) -> Bool {
        let fields = Mirror(reflecting: node)
        if let value = (fields.descendant("data") as? [_ViewDebug.Property: Any])?[.value] {
            let type = String(reflecting: Swift.type(of: value))
            if type.hasPrefix("SwiftUI.HStack<") || type.hasPrefix("SwiftUI.LabeledContent<") {
                if read(value, enabled: true, help: nil, depth: 24).contains(where: { $0.kind == .toggle }) {
                    return true
                }
            }
        }
        return (fields.descendant("childData") as? [_ViewDebug.Data] ?? []).contains(where: hasToggleContainer)
    }

    private static func read(_ value: Any, enabled: Bool, help: String?, depth: Int) -> [Control] {
        guard depth > 0 else { return [] }
        let mirror = Mirror(reflecting: value)
        let type = String(reflecting: Swift.type(of: value))
        if type.contains(".AnyViewStorage<"), let view = mirror.descendant("view") {
            return read(view, enabled: enabled, help: help, depth: depth - 1)
        }
        guard mirror.displayStyle != .class else { return [] }
        if type.hasPrefix("SwiftUI.HelpView<"), let content = mirror.descendant("content"),
           let text = mirror.descendant("text") as? Text {
            let reason = RenderedViewTestSupport.strings(in: text).first.map(unescape)
            return read(content, enabled: enabled, help: reason, depth: depth - 1)
        }
        if type.hasPrefix("SwiftUI.ModifiedContent<"), let content = mirror.descendant("content"),
           let modifier = mirror.descendant("modifier") {
            var enabled = enabled
            let fields = Mirror(reflecting: modifier)
            if fields.descendant("keyPath") as? WritableKeyPath<EnvironmentValues, Bool> == \.isEnabled {
                if let transform = fields.descendant("transform") as? (inout Bool) -> Void { transform(&enabled) }
                if let written = fields.descendant("value") as? Bool { enabled = written }
            }
            return read(content, enabled: enabled, help: help, depth: depth - 1)
        }
        if ["SwiftUI.Button<", "SwiftUI.Menu<", "SwiftUI.Toggle<"].contains(where: type.hasPrefix),
           let label = mirror.descendant("label"), let title = title(of: label) {
            let kind: Kind = type.hasPrefix("SwiftUI.Toggle<") ? .toggle
                : type.hasPrefix("SwiftUI.Menu<") ? .menu : .button
            return [Control(kind: kind, title: title, enabled: enabled, help: help)]
        }
        // Follow only SwiftUI composition and tuple/conditional storage, never model references
        // or captured closures. ForEach's rendered children are supplied by the live debug tree.
        guard type.hasPrefix("SwiftUI.") || [.tuple, .enum, .optional].contains(mirror.displayStyle) else { return [] }
        return mirror.children.flatMap { read($0.value, enabled: enabled, help: help, depth: depth - 1) }
    }

    static func unescape(_ text: String) -> String {
        var text = text
        // Nested Form hosts can escape a text payload more than once in debug data.
        while text.contains("\\'") { text = text.replacingOccurrences(of: "\\'", with: "'") }
        return text
    }

    private static func title(of label: Any, depth: Int = 24) -> String? {
        guard depth > 0, Mirror(reflecting: label).displayStyle != .class else { return nil }
        if let text = label as? Text { return RenderedViewTestSupport.strings(in: text).first }
        if let title = Mirror(reflecting: label).descendant("title") as? Text {
            return RenderedViewTestSupport.strings(in: title).first
        }
        return Mirror(reflecting: label).children.lazy.compactMap { title(of: $0.value, depth: depth - 1) }.first
    }
}
