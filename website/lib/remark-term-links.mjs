// Links well-known tools: the first plain-text mention of each term on a page becomes a
// link to its site, once per page, and not at all when the page links there already.
// Matches are case-sensitive and whole words (so `lwpt.cfg` and `fpc-toolchain` stay
// plain), and never inside code, links or headings.

// Longest first, so a longer term wins where two start at the same place.
const TERMS = [
  ['Free Pascal', 'https://www.freepascal.org'],
  ['raylib', 'https://www.raylib.com'],
  ['lwpt', 'https://github.com/frostney/lwpt'],
  ['Wine', 'https://www.winehq.org'],
];

const SKIP_TYPES = new Set(['link', 'linkReference', 'heading', 'code', 'inlineCode']);

// A term must not touch letters, digits or the joiners of file and unit names.
const BOUNDARY = /[A-Za-z0-9_.\-/]/;

function normalize(url) {
  return url.replace(/\/+$/, '');
}

function collectExistingLinks(node, seen) {
  if ((node.type === 'link' || node.type === 'definition') && typeof node.url === 'string') {
    seen.add(normalize(node.url));
  }
  for (const child of node.children ?? []) collectExistingLinks(child, seen);
}

function earliestMatch(text, seen) {
  let best = null;
  for (const [term, url] of TERMS) {
    if (seen.has(normalize(url))) continue;
    let from = 0;
    for (;;) {
      const at = text.indexOf(term, from);
      if (at === -1) break;
      const before = at === 0 ? '' : text[at - 1];
      const after = text[at + term.length] ?? '';
      if ((before === '' || !BOUNDARY.test(before)) && (after === '' || !BOUNDARY.test(after))) {
        if (!best || at < best.at || (at === best.at && term.length > best.term.length)) {
          best = { at, term, url };
        }
        break;
      }
      from = at + 1;
    }
  }
  return best;
}

function linkTerms(node, seen) {
  if (SKIP_TYPES.has(node.type) || !node.children) return;
  for (let i = 0; i < node.children.length; i++) {
    const child = node.children[i];
    if (child.type !== 'text') {
      linkTerms(child, seen);
      continue;
    }
    const match = earliestMatch(child.value, seen);
    if (!match) continue;
    seen.add(normalize(match.url));
    const before = child.value.slice(0, match.at);
    const after = child.value.slice(match.at + match.term.length);
    const replacement = [];
    if (before) replacement.push({ type: 'text', value: before });
    replacement.push({ type: 'link', url: match.url, children: [{ type: 'text', value: match.term }] });
    if (after) replacement.push({ type: 'text', value: after });
    node.children.splice(i, 1, ...replacement);
    // look at the text after the link again, for the other terms
    i = node.children.indexOf(replacement[replacement.length - 1]) - 1;
  }
}

export function remarkTermLinks() {
  return (tree) => {
    const seen = new Set();
    collectExistingLinks(tree, seen);
    linkTerms(tree, seen);
  };
}
