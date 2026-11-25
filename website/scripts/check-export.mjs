// Runs after `next build` (npm's postbuild) and checks what the static export in out/ gives
// readers outside the pages themselves:
//
// - Every search result's #anchor is an id on the page it names, so a result lands on its
//   heading.
// - In the Markdown copies (out/llms.mdx/) and llms-full.txt, no heading ends with fumadocs'
//   `[#id]` suffix, which only fumadocs' own parser reads. The files are parsed as Markdown,
//   so a heading inside a quote counts and a line in a code block doesn't.
//
// It exits 1 and lists each problem when one fails.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fromMarkdown } from 'mdast-util-from-markdown';
import { fileURLToPath } from 'node:url';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'out');
const problems = [];

// the ids on the exported page for a site path such as /docs/guides/edits
const idsByPath = new Map();
function pageIds(path) {
  if (!idsByPath.has(path)) {
    const file = join(out, path, 'index.html');
    const ids = new Set();
    if (existsSync(file)) {
      for (const m of readFileSync(file, 'utf8').matchAll(/\sid="([^"]*)"/g)) ids.add(m[1]);
      idsByPath.set(path, ids);
    } else {
      idsByPath.set(path, null);
    }
  }
  return idsByPath.get(path);
}

const index = JSON.parse(readFileSync(join(out, 'api', 'search'), 'utf8'));
let anchors = 0;
for (const doc of Object.values(index.docs.docs)) {
  const [path, anchor] = String(doc.url).split('#');
  const ids = pageIds(path);
  if (ids === null) {
    problems.push(`search result ${doc.url}: no page ${path}`);
    continue;
  }
  if (anchor === undefined) continue;
  anchors++;
  if (!ids.has(decodeURIComponent(anchor))) problems.push(`search result ${doc.url}: the page has no id "${anchor}"`);
}

function markdownFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? markdownFiles(path) : name.endsWith('.md') ? [path] : [];
  });
}

// the text of a node and everything in it, as a reader sees it
function text(node) {
  if ('value' in node && typeof node.value === 'string') return node.value;
  return (node.children ?? []).map(text).join('');
}

function headings(node, found = []) {
  if (node.type === 'heading') found.push(node);
  for (const child of node.children ?? []) headings(child, found);
  return found;
}

const copies = [...markdownFiles(join(out, 'llms.mdx')), join(out, 'llms-full.txt')];
for (const file of copies) {
  for (const heading of headings(fromMarkdown(readFileSync(file, 'utf8')))) {
    const title = text(heading);
    if (/\[#[^\]]*\]\s*$/.test(title)) {
      problems.push(`${file.slice(out.length + 1)}:${heading.position.start.line}: heading ends with an [#id] suffix: ${title}`);
    }
  }
}

if (problems.length > 0) {
  console.error(problems.join('\n'));
  console.error(`check-export: ${problems.length} problems`);
  process.exit(1);
}
console.log(`check-export: ${anchors} search anchors and ${copies.length} Markdown files OK`);
