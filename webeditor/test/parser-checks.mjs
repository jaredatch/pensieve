import { markdown } from "@codemirror/lang-markdown";
import { yamlLanguage } from "@codemirror/lang-yaml";
import { Text } from "@codemirror/state";
import { DocInput } from "@codemirror/language";
import { TreeFragment } from "@lezer/common";
import { Tag } from "@lezer/highlight";
import { withFrontmatter } from "../src/frontmatter.mjs";

const parser = withFrontmatter(markdown(), yamlLanguage.parser, Tag.define()).language.parser;

function checkedInput(text, headerEnd = 0, headerOnly = false) {
  const input = new DocInput(Text.of(text.split("\n")));
  const read = input.read.bind(input);
  input.read = (from, to) => {
    if ((headerOnly || from < headerEnd) && to > headerEnd) throw new Error(`read crossed closing fence: ${from}..${to} > ${headerEnd}`);
    return read(from, to);
  };
  const chunk = input.chunk.bind(input);
  input.chunk = pos => {
    const value = chunk(pos);
    if ((headerOnly || pos < headerEnd) && pos + value.length > headerEnd) {
      throw new Error(`chunk crossed closing fence: ${pos}..${pos + value.length} > ${headerEnd}`);
    }
    return value;
  };
  return input;
}

// These probes exercise the production language factory through Lezer's Input and fragment APIs.
// The read bound permits body reads, but refuses a header read that copies past its closing fence.
// Tree identity proves actual block reuse rather than estimating parser work from elapsed time.
globalThis.EditorParserChecks = {
  boundedClosedHeader() {
    for (const opening of ["---", "\uFEFF--- \t"]) {
      const header = `${opening}\nname: Example\ndescription: test\n---\t \n`;
      const text = header + ("body paragraph\n\n".repeat(2000));
      // A header-only parse range isolates lookahead from the body's legitimate parser reads.
      for (const lineChunks of [true, false]) {
        const input = checkedInput(text, header.length, true);
        Object.defineProperty(input, "lineChunks", { value: lineChunks });
        parser.parse(input, [], [{ from: 0, to: header.length - 1 }]);
      }
      const tree = parser.parse(checkedInput(text, header.length));
      const pos = text.length - 10;
      const changed = text.slice(0, pos) + "x" + text.slice(pos);
      const fragments = TreeFragment.applyChanges(TreeFragment.addTree(tree),
        [{ fromA: pos, toA: pos, fromB: pos, toB: pos + 1 }]);
      parser.parse(checkedInput(changed, header.length), fragments);
    }
    return "bounded";
  },
  nonFenceReuse() {
    for (const opening of ["# Heading", "plain paragraph", " ---", "\uFEFF\uFEFF---", "---\u00A0"]) {
      const text = opening + "\n\n" + "body paragraph\n\n".repeat(2000);
      const tree = parser.parse(checkedInput(text));
      const pos = text.length - 10;
      const changed = text.slice(0, pos) + "x" + text.slice(pos);
      const fragments = TreeFragment.applyChanges(TreeFragment.addTree(tree),
        [{ fromA: pos, toA: pos, fromB: pos, toB: pos + 1 }]);
      const updated = parser.parse(checkedInput(changed), fragments);
      if (!tree.topNode.firstChild.tree || tree.topNode.firstChild.tree !== updated.topNode.firstChild.tree) {
        throw new Error(`first block reparsed: ${JSON.stringify(opening)}`);
      }
    }
    return "reused";
  },
};
