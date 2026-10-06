import XCTest
import WebKit
@testable import Pensieve

@MainActor
final class MarkdownEditorHostTests: XCTestCase {
    /// The editor loaded in a programmatic window: navigation finished, the document ready, the coordinator
    /// and the window that keeps the web view alive.
    private func makeReadyEditor() -> (MarkdownEditorWebView.Coordinator, NSWindow) {
        let ready = expectation(description: "editorDidReady")
        let coordinator = MarkdownEditorWebView.Coordinator(onReady: { ready.fulfill() }, onContentChange: { _ in })
        let webView = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        wait(for: [ready], timeout: TestWait.hostedActionTimeoutSeconds)
        return (coordinator, window)
    }

    private func probe(_ coordinator: MarkdownEditorWebView.Coordinator, _ js: String) -> String {
        let done = expectation(description: "probe")
        var value = ""
        coordinator.evaluateJavaScript(js) { result, _ in
            value = "\(result ?? "")"
            done.fulfill()
        }
        wait(for: [done], timeout: TestWait.hostedActionTimeoutSeconds)
        return value
    }

    func testEditorLoadsOverPrivateSchemeAndIsStyled() {
        let coordinator = MarkdownEditorWebView.Coordinator(onReady: {}, onContentChange: { _ in })
        let navigated = expectation(description: "navigation finished")
        coordinator.onNavigationFinished = { navigated.fulfill() }
        let webView = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        wait(for: [navigated], timeout: TestWait.hostedActionTimeoutSeconds)

        let probed = expectation(description: "style probe")
        coordinator.evaluateJavaScript(
            "(function(){var c=document.querySelector('.cm-content');return c?getComputedStyle(c).fontFamily:'';})()"
        ) { result, _ in
            XCTAssertTrue("\(result ?? "")".contains("mono"),
                          "editor should render a styled .cm-content; got \(String(describing: result))")
            probed.fulfill()
        }
        wait(for: [probed], timeout: TestWait.hostedActionTimeoutSeconds)
    }

    /// MarkEdit's metrics (PLAN-34 / 34.1): 12 px on 18 px lines.
    func testEditorUsesMarkEditMetrics() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            let metrics = probe(coordinator, "(function(){var c=document.querySelector('.cm-content');"
                + "var s=getComputedStyle(c);return s.fontSize+'/'+s.lineHeight;})()")
            XCTAssertEqual(metrics, "12px/18px")
        }
    }

    /// Read-only crosses the bridge as data and turns the content's editing off; off again restores it.
    func testReadOnlyEditorRefusesInput() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setReadOnly(true)
            XCTAssertEqual(probe(coordinator, "document.querySelector('.cm-content').getAttribute('contenteditable')"), "false")
            coordinator.setReadOnly(false)
            XCTAssertEqual(probe(coordinator, "document.querySelector('.cm-content').getAttribute('contenteditable')"), "true")
        }
    }

    /// A read-only file draws no caret-line band: nothing can be typed there, so nothing should look editable.
    /// Editable again, the band comes back.
    func testReadOnlyEditorDrawsNoCaretBand() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("one\ntwo")
            let bands = "document.querySelectorAll('.cm-activeLine, .cm-activeLineGutter').length"
            XCTAssertEqual(probe(coordinator, bands), "2")
            coordinator.setReadOnly(true)
            XCTAssertEqual(probe(coordinator, bands), "0")
            coordinator.setReadOnly(false)
            XCTAssertEqual(probe(coordinator, bands), "2")
        }
    }

    /// A wrapped numbered item continues under its text: the line carries a negative text-indent.
    func testAWrappedListItemHangsUnderItsText() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("1. " + String(repeating: "wrap ", count: 60) + "\nplain line")
            let indents = probe(coordinator, "(function(){var l=document.querySelectorAll('.cm-line');"
                + "return getComputedStyle(l[0]).textIndent+'|'+getComputedStyle(l[1]).textIndent;})()")
            let parts = indents.split(separator: "|").map(String.init)
            XCTAssertEqual(parts.count, 2, indents)
            XCTAssertTrue(parts.first?.hasPrefix("-") == true, "the list line should hang; got \(indents)")
            XCTAssertEqual(parts.last, "0px", "a plain line should not hang; got \(indents)")
        }
    }

    func testTheListMarkAloneIsTinted() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("- item text")
            let result = probe(coordinator, "(function(){var l=document.querySelector('.cm-line');"
                + "var s=l.querySelectorAll('span');return s.length+'|'+(s[0]?s[0].textContent:'')+'|'"
                + "+(s[0]?getComputedStyle(s[0]).color:'');})()")
            XCTAssertEqual(result, "1|-|rgb(138, 90, 43)")
        }
    }

    func testACodeBlockLineCarriesNoPill() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("```js\nlet x = 1;\n```\nplain `code` here")
            let result = probe(coordinator, "(function(){var ls=document.querySelectorAll('.cm-line');"
                + "function pills(l){return Array.from(l.querySelectorAll('span')).filter(function(s){"
                + "return getComputedStyle(s).borderRadius==='3px'}).length}return pills(ls[1])+'|'"
                + "+pills(ls[3]);})()")
            XCTAssertEqual(result, "0|1")
        }
    }

    func testTheDarkThemeKeepsCodeBlockInk() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setTheme("dark")
            coordinator.setBody("```bash\nlet x = 1;\n```")
            let result = probe(coordinator, "(function(){var l=document.querySelectorAll('.cm-line')[1];"
                + "var s=l.querySelector('span');return s?getComputedStyle(s).color+'|'"
                + "+getComputedStyle(s).borderRadius:getComputedStyle(l).color+'|none';})()")
            XCTAssertEqual(result, "rgb(159, 232, 141)|0px")
        }
    }

    func testALoadIsNotAnUndoStep() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("hello world")
            XCTAssertEqual(probe(coordinator, "window.Editor.undoDepth()"), "0", "a fresh mount's load is not undoable")
            coordinator.evaluateJavaScript("window.Editor.simulateEdit('hello')")
            XCTAssertEqual(probe(coordinator, "window.Editor.undoDepth()"), "1", "a typed edit is undoable")
            coordinator.setBody("new disk content")
            XCTAssertEqual(probe(coordinator, "window.Editor.undoDepth()"), "0", "a reload starts the history over")
            XCTAssertEqual(probe(coordinator, "window.Editor.redoDepth()"), "0")
            XCTAssertEqual(probe(coordinator, "window.Editor.undo()"), "false", "an Undo after a reload changes nothing")
            XCTAssertEqual(probe(coordinator, "window.Editor.getContent()"), "new disk content")
        }
    }

    func testAnUndoneEditDoesNotSurviveAReload() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("hello world")
            coordinator.evaluateJavaScript("window.Editor.simulateEdit('hello')")
            XCTAssertEqual(probe(coordinator, "window.Editor.undo()"), "true")
            XCTAssertEqual(probe(coordinator, "window.Editor.getContent()"), "hello world")
            XCTAssertEqual(probe(coordinator, "window.Editor.redoDepth()"), "1")
            coordinator.setBody("new disk content")
            XCTAssertEqual(probe(coordinator, "window.Editor.redoDepth()"), "0")
            XCTAssertEqual(probe(coordinator, "window.Editor.undo()"), "false")
            XCTAssertEqual(probe(coordinator, "window.Editor.getContent()"), "new disk content")
        }
    }

    func testTheCaretLinesNumberReadsPrimary() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("one\ntwo")
            let result = probe(coordinator, "(function(){var a=document.querySelector("
                + "'.cm-lineNumbers .cm-gutterElement.cm-activeLineGutter');var o=Array.from("
                + "document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')).find(function(e){"
                + "return !e.classList.contains('cm-activeLineGutter')&&e.textContent.trim()!==''});"
                + "return getComputedStyle(a).color+'|'+getComputedStyle(o).color;})()")
            XCTAssertEqual(result, "rgba(0, 0, 0, 0.85)|rgba(0, 0, 0, 0.25)")
        }
    }

    func testAListInsideAFenceDoesNotHangAndAQuotedItemDoes() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("```yaml\n- name: x\n```\n> - " + String(repeating: "quoted ", count: 60))
            let indents = probe(coordinator, "(function(){var l=document.querySelectorAll('.cm-line');"
                + "return getComputedStyle(l[1]).textIndent+'|'+getComputedStyle(l[3]).textIndent;})()")
            let parts = indents.split(separator: "|").map(String.init)
            XCTAssertEqual(parts.count, 2, indents)
            XCTAssertEqual(parts.first, "0px")
            XCTAssertTrue(parts.last?.hasPrefix("-") == true, "the quoted item should hang; got \(indents)")
        }
    }

    /// The hanging indent reads a range from its line's start (a very long item's visible range opens mid-line),
    /// keeps one indent per line, and takes the innermost mark's column — through the plugin's own function.
    func testTheHangSurvivesAVirtualizedLineStart() {
        let (coordinator, window) = makeReadyEditor()
        withExtendedLifetime(window) {
            coordinator.setBody("- " + String(repeating: "long ", count: 5000))
            XCTAssertEqual(probe(coordinator, "window.Editor.hangingIndentLines([{from:8000,to:13000}])"), "1:2")
            XCTAssertEqual(probe(coordinator, "window.Editor.hangingIndentLines([{from:0,to:3000},{from:8000,to:13000}])"), "1:2")
            coordinator.setBody("- - nested")
            XCTAssertEqual(probe(coordinator, "window.Editor.hangingIndentLines([{from:0,to:10}])"), "1:4")
        }
    }
}
