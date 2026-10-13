import { Language, LanguageSupport } from "@codemirror/language";
import { parseMixed, Parser, TreeFragment } from "@lezer/common";

function lineAt(input, from) {
  if (input.lineChunks) {
    const line = input.chunk(from);
    return line === "\n" ? "" : line;
  }
  let line = "";
  for (let pos = from; pos < input.length; pos++) {
    const next = input.read(pos, pos + 1);
    if (next === "\n") break;
    line += next;
  }
  return line;
}

function opensFence(input) {
  const start = input.read(0, Math.min(1, input.length)) === "\uFEFF" ? 1 : 0;
  if (input.read(start, Math.min(start + 3, input.length)) !== "---") return false;
  for (let pos = start + 3; pos < input.length; pos++) {
    const next = input.read(pos, pos + 1);
    if (next === "\n") return true;
    if (next !== " " && next !== "\t" && next !== "\r") return false;
  }
  return true;
}

export function withFrontmatter(content, yamlParser, yamlFenceTag) {
  const mixFrontmatter = parseMixed(node => node.name === "FrontmatterContent" ? { parser: yamlParser } : null);

  // Match SkillParser's fences: the first LF/CRLF line, one optional BOM, only trailing ASCII space/tab/CR,
  // and a column-zero closing fence. Look ahead before consuming anything: an unclosed header stays Markdown.
  // The package's yamlFrontmatter grammar admits unclosed headers and rejects BOM/trailing-tab fences.
  const frontmatter = {
    defineNodes: ["Frontmatter", "FrontmatterContent", { name: "FrontmatterFence", style: yamlFenceTag }],
    parseBlock: [{
      name: "Frontmatter", before: "HorizontalRule",
      parse(cx, line) {
        if (cx.lineStart !== 0 || !/^\uFEFF?---[ \t\r]*$/.test(line.text)) return false;
        const contentFrom = Math.min(line.text.length + 1, cx.input.length);
        let closeFrom = contentFrom, closeTo = -1;
        while (closeFrom < cx.input.length) {
          const text = lineAt(cx.input, closeFrom);
          if (/^---[ \t\r]*$/.test(text)) { closeTo = closeFrom + text.length; break; }
          closeFrom += text.length + 1;
        }
        if (closeTo < 0) return false;
        const children = [cx.elt("FrontmatterFence", 0, line.text.length)];
        if (closeFrom > contentFrom) children.push(cx.elt("FrontmatterContent", contentFrom, closeFrom));
        children.push(cx.elt("FrontmatterFence", closeFrom, closeTo));
        while (cx.lineStart < closeTo && cx.nextLine()) { /* consume through the closing fence */ }
        cx.addElement(cx.elt("Frontmatter", 0, closeTo, children));
        return true;
      },
    }],
    wrap: mixFrontmatter,
  };
  const markdownSyntax = new LanguageSupport(
    new Language(content.language.data, content.language.parser.configure(frontmatter), [], "markdown"), content.support);
  class FrontmatterParser extends Parser {
    createParse(input, fragments, ranges) {
      // Only a possible fence needs lookahead after an edit. Keep ordinary Markdown's fragments intact,
      // and preserve the untouched fragments' boundaries and flags when invalidating a fence opener.
      let rest = fragments;
      const first = fragments[0];
      if (first?.from === 0 && opensFence(input)) {
        rest = first.to <= 1 ? fragments.slice(1) : [
          new TreeFragment(1, first.to, first.tree, first.offset, true, first.openEnd), ...fragments.slice(1),
        ];
      }
      return markdownSyntax.language.parser.startParse(input, rest, ranges);
    }
  }
  return new LanguageSupport(
    new Language(markdownSyntax.language.data, new FrontmatterParser(), [], "markdown"), markdownSyntax.support);
}
