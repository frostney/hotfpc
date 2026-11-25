// Runs after `next build` (npm's postbuild) and checks what the static export in out/ gives
// readers outside the pages themselves:
//
// - Every search result's #anchor is an id on the page it names, so a result lands on its
//   heading.
// - In the Markdown copies (out/llms.mdx/) and llms-full.txt, no heading ends with fumadocs'
//   `[#id]` suffix, which only fumadocs' own parser reads. The files are parsed as the site
//   parses Markdown (GitHub's, with footnotes), so a heading inside a quote or a footnote
//   counts, a line in a code block doesn't, and so doesn't a heading that ends with `[#id]`
//   in a code span: fumadocs reads the suffix only from the heading's last plain text.
//
// It exits 1 and lists each problem when one fails.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import { visit } from 'unist-util-visit';
import { fileURLToPath } from 'node:url';

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'out');
const problems = [];

// React escapes these characters in an attribute's value; the browser reads them back
const entities = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#x27;': "'", '&#39;': "'" };
function attributeValue(raw) {
  return raw.replace(/&amp;|&lt;|&gt;|&quot;|&#x27;|&#39;/g, (entity) => entities[entity]);
}

// the ids on the exported page for a site path such as /docs/guides/edits, as the browser reads
// them
const idsByPath = new Map();
function pageIds(path) {
  if (!idsByPath.has(path)) {
    const file = join(out, path, 'index.html');
    const ids = new Set();
    if (existsSync(file)) {
      for (const m of readFileSync(file, 'utf8').matchAll(/\sid="([^"]*)"/g)) ids.add(attributeValue(m[1]));
      idsByPath.set(path, ids);
    } else {
      idsByPath.set(path, null);
    }
  }
  return idsByPath.get(path);
}

// a URL fragment as the browser matches it to an id: everything after the first #, with
// percent escapes decoded
function fragmentId(fragment) {
  try {
    return decodeURIComponent(fragment);
  } catch {
    return fragment;
  }
}

const index = JSON.parse(readFileSync(join(out, 'api', 'search'), 'utf8'));
let anchors = 0;
for (const doc of Object.values(index.docs.docs)) {
  const url = String(doc.url);
  const hash = url.indexOf('#');
  const path = hash < 0 ? url : url.slice(0, hash);
  const ids = pageIds(path);
  if (ids === null) {
    problems.push(`search result ${url}: no page ${path}`);
    continue;
  }
  if (hash < 0) continue;
  anchors++;
  const id = fragmentId(url.slice(hash + 1));
  if (!ids.has(id)) problems.push(`search result ${url}: the page has no id "${id}"`);
}

function markdownFiles(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? markdownFiles(path) : name.endsWith('.md') ? [path] : [];
  });
}

const parser = unified().use(remarkParse).use(remarkGfm);
// the suffix fumadocs-core's remark-heading reads as a custom id: a non-empty id after `[#`
// and up to the last `]`, so `[#]` is plain text and `[#a]b]` is the id `a]b`
const suffix = /\s*\[#[^]+?]\s*$/;
const copies = [...markdownFiles(join(out, 'llms.mdx')), join(out, 'llms-full.txt')];
for (const file of copies) {
  visit(parser.parse(readFileSync(file, 'utf8')), 'heading', (heading) => {
    const last = heading.children.at(-1);
    if (last?.type === 'text' && suffix.test(last.value)) {
      problems.push(`${file.slice(out.length + 1)}:${heading.position.start.line}: heading ends with an [#id] suffix: ${last.value.trim()}`);
    }
  });
}

if (problems.length > 0) {
  console.error(problems.join('\n'));
  console.error(`check-export: ${problems.length} problems`);
  process.exit(1);
}
console.log(`check-export: ${anchors} search anchors and ${copies.length} Markdown files OK`);
