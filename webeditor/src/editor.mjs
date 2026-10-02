import { EditorState, Annotation, Compartment, countColumn } from "@codemirror/state";
import { EditorView, lineNumbers, keymap, drawSelection, highlightActiveLine, highlightActiveLineGutter, Decoration, ViewPlugin } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab, undoDepth, redoDepth, undo as undoCommand } from "@codemirror/commands";
import { syntaxHighlighting, HighlightStyle, indentOnInput, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { styleTags, Tag, tags as t } from "@lezer/highlight";

const post = (name, body) => window.webkit?.messageHandlers?.[name]?.postMessage(body ?? null);
const cspNonce = document.querySelector('meta[name="csp-nonce"]')?.content ?? "";
const fromSwift = Annotation.define();

// Two nodes the base grammar tags too broadly for MarkEdit's look (Layer-2 over 34.1): `t.list` covers a
// list item's whole prose, and `t.monospace` covers a fenced block's lines as well as inline code. Each gets
// its own tag through a later prop source, which replaces the base rule for that node alone, so the brown
// reaches the mark and the pill reaches inline code — a code block's lines stay plain.
const listMarkTag = Tag.define();
const inlineCodeTag = Tag.define();
const markdownSupport = markdown({ extensions: [{ props: [styleTags({ ListMark: listMarkTag, InlineCode: inlineCodeTag })] }] });

// MarkEdit's values: SF Mono 12 px on an 18 px
// line; the gutter a 28 px column of right-aligned numbers, the content at 40; a full-width caret-line
// band, gutter included, whose color the appearance sets; transparent background (the host WKWebView is
// non-drawing, so Color(.textBackgroundColor) shows through and follows light/dark).
const baseTheme = EditorView.theme({
  "&": { fontSize: "12px", backgroundColor: "transparent", height: "100%" },
  ".cm-content": { fontFamily: "ui-monospace, 'SF Mono', Menlo, monospace", lineHeight: "18px", padding: "12px 12px 12px 0" },
  ".cm-scroller": { overflow: "auto", fontFamily: "ui-monospace, 'SF Mono', Menlo, monospace", lineHeight: "18px" },
  ".cm-gutters": { backgroundColor: "transparent", border: "none", minWidth: "28px" },
  ".cm-lineNumbers .cm-gutterElement": { textAlign: "right", padding: "0", minWidth: "28px" },
  ".cm-line": { padding: "0 0 0 12px" },
});

// Headings bold in a dark blue that is never the system accent, at base + 5 / + 3 / + 1 on taller lines;
// bold runs bold, inline code on a grey pill, list marks warm brown, links underlined (MarkEdit's style).
const lightHighlight = HighlightStyle.define([
  { tag: t.heading1, color: "#0f5db5", fontWeight: "bold", fontSize: "17px", lineHeight: "24px" },
  { tag: t.heading2, color: "#0f5db5", fontWeight: "bold", fontSize: "15px", lineHeight: "22px" },
  { tag: [t.heading3, t.heading4, t.heading5, t.heading6], color: "#0f5db5", fontWeight: "bold", fontSize: "13px", lineHeight: "20px" },
  { tag: t.strong, fontWeight: "bold" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: inlineCodeTag, backgroundColor: "rgba(0,0,0,0.06)", borderRadius: "3px", padding: "0 3px" },
  { tag: listMarkTag, color: "#8a5a2b" },
  { tag: [t.link, t.url], color: "#0f5db5", textDecoration: "underline" },
  { tag: t.comment, color: "#7f848e", fontStyle: "italic" },
]);

const darkHighlight = HighlightStyle.define([
  { tag: t.heading1, color: "#6fb3ff", fontWeight: "bold", fontSize: "17px", lineHeight: "24px" },
  { tag: t.heading2, color: "#6fb3ff", fontWeight: "bold", fontSize: "15px", lineHeight: "22px" },
  { tag: [t.heading3, t.heading4, t.heading5, t.heading6], color: "#6fb3ff", fontWeight: "bold", fontSize: "13px", lineHeight: "20px" },
  { tag: t.strong, fontWeight: "bold", color: "#e6e6e6" },
  { tag: t.emphasis, fontStyle: "italic", color: "#e6e6e6" },
  { tag: inlineCodeTag, color: "#9fe88d", backgroundColor: "rgba(255,255,255,0.08)", borderRadius: "3px", padding: "0 3px" },
  { tag: t.monospace, color: "#9fe88d" },   // a code block's text keeps the dark code ink, without the pill
  { tag: listMarkTag, color: "#d9a066" },
  { tag: [t.link, t.url], color: "#6fb3ff", textDecoration: "underline" },
  { tag: t.comment, color: "#7f848e", fontStyle: "italic" },
]);

// Appearance compartment: text/cursor/selection color, the caret-line band, the gutter numbers, and
// the highlight style, swapped by setTheme().
const appearance = new Compartment();
function appearanceFor(scheme) {
  const dark = scheme === "dark";
  const band = dark ? "rgba(255,255,255,0.04)" : "rgba(0,0,0,0.02)";
  return [
    EditorView.theme({
      ".cm-content": { color: dark ? "#e6e6e6" : "#1d1d1f", caretColor: dark ? "#e6e6e6" : "#1d1d1f" },
      ".cm-cursor, .cm-dropCursor": { borderLeftColor: dark ? "#e6e6e6" : "#1d1d1f" },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": {
        backgroundColor: dark ? "rgba(120,160,255,0.30)" : "rgba(0,90,200,0.18)",
      },
      ".cm-lineNumbers .cm-gutterElement": { color: dark ? "rgba(255,255,255,0.25)" : "rgba(0,0,0,0.25)" },
      ".cm-lineNumbers .cm-gutterElement.cm-activeLineGutter": { backgroundColor: band, color: dark ? "rgba(255,255,255,0.85)" : "rgba(0,0,0,0.85)" },
      ".cm-activeLine": { backgroundColor: band },
    }, { dark }),
    syntaxHighlighting(dark ? darkHighlight : lightHighlight, { fallback: true }),
  ];
}

// Line start → the item text's column, for every line whose ListMark lies in `ranges` or on a line a range begins
// inside; the innermost mark on a line wins.
function hangingColumns(state, ranges) {
  const tree = syntaxTree(state);
  const columns = new Map();
  for (const { from, to } of ranges) {
    tree.iterate({ from: state.doc.lineAt(from).from, to, enter: (node) => {
      if (node.name !== "ListMark") return;
      const line = state.doc.lineAt(node.from);
      const rel = node.to - line.from;
      const after = /^\s*/.exec(line.text.slice(rel))[0].length;
      const n = countColumn(line.text, state.tabSize, rel + after);
      columns.set(line.from, Math.max(columns.get(line.from) ?? 0, n));
    } });
  }
  return columns;
}

// A wrapped list item continues under its text, not under its mark (MarkEdit's hanging indent; "1. " on SF
// Mono 12 is 22 px, decision 5): every ListMark the parse tree holds in the viewport marks its line with a
// negative text-indent of the item text's column — tabs at the editor's tab size, a quote's "> " included —
// and the matching padding. The tree, not a regex: a "- " inside a fenced block is code, a "* * *" is a rule,
// and "> - x" is an item (Layer-2 over 34.1). Each visible range is read from the start of the line it begins
// in — CodeMirror virtualizes the middle of a very long wrapped line, so a range can open past its ListMark
// (Layer-1 over the 34.1 fix batch) — and each line keeps one indent, its innermost mark's.
const hangingIndent = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = this.build(view); }
  update(update) {
    if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) {
      this.decorations = this.build(update.view);
    }
  }
  build(view) {
    const marks = [];
    for (const [lineFrom, n] of hangingColumns(view.state, view.visibleRanges)) {
      marks.push(Decoration.line({ attributes: { style: `text-indent:-${n}ch;padding-left:calc(12px + ${n}ch)` } }).range(lineFrom));
    }
    return Decoration.set(marks, true);
  }
}, { decorations: (v) => v.decorations });

// Read-only compartment: the Content tab shows the bundle's other files in this editor without editing them. The
// caret-line band belongs to editing, so a read-only file draws none — on a file you cannot type in it reads as a
// place to type.
const readOnly = new Compartment();
const readOnlyFor = (flag) => flag
  ? [EditorState.readOnly.of(true), EditorView.editable.of(false)]
  : [EditorState.readOnly.of(false), EditorView.editable.of(true), highlightActiveLine(), highlightActiveLineGutter()];

// The undo history in its own compartment, so a push can start it over: `addToHistory.of(false)` alone keeps
// the load out of the history but maps earlier events through the replacement, and an Undo after a reload then
// splices the old text into the new (Layer-1 over the 34.1 fix batch: "new disk content world").
const undoHistory = new Compartment();

const view = new EditorView({
  state: EditorState.create({
    doc: "",
    extensions: [
      EditorView.cspNonce.of(cspNonce),
      lineNumbers(), undoHistory.of(history()), drawSelection(), indentOnInput(),
      markdownSupport,
      EditorView.lineWrapping,
      hangingIndent,
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      baseTheme,
      appearance.of(appearanceFor("light")),
      readOnly.of(readOnlyFor(false)),
      EditorView.updateListener.of((v) => {
        if (!v.docChanged) return;
        if (v.transactions.some((tr) => tr.annotation(fromSwift))) return;
        post("contentDidChange", view.state.doc.toString());
      }),
    ],
  }),
  parent: document.body,
});

window.Editor = {
  // A push is the document arriving, not an edit: the history starts over at the loaded text, so no Undo reaches
  // behind it (Layer-2 over 34.1; the mechanism, Layer-1 over its fix batch). An equal push returns early and
  // keeps the history — the text did not move.
  setContent(text) {
    if (text === view.state.doc.toString()) return;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text },
                    annotations: fromSwift.of(true), effects: undoHistory.reconfigure([]) });
    view.dispatch({ effects: undoHistory.reconfigure(history()) });
  },
  getContent() { return view.state.doc.toString(); },
  setTheme(scheme) { view.dispatch({ effects: appearance.reconfigure(appearanceFor(scheme)) }); },
  setReadOnly(flag) { view.dispatch({ effects: readOnly.reconfigure(readOnlyFor(flag === true)) }); },
  simulateEdit(text) { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } }); },
  undoDepth() { return undoDepth(view.state); },
  redoDepth() { return redoDepth(view.state); },
  undo() { return String(undoCommand(view)); },   // test seam: "true" when an Undo changed something
  // Test seam: the hanging indents the plugin would draw for `ranges` over the current document, as "line:column".
  hangingIndentLines(ranges) {
    return Array.from(hangingColumns(view.state, ranges), ([pos, n]) => `${view.state.doc.lineAt(pos).number}:${n}`).join(",");
  },
};

post("editorDidReady");
