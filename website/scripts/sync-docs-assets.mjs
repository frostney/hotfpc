// Copies the files under docs/ that aren't pages (the demo recordings and any image) into
// public/docs-assets/, so the static site serves the files the Markdown links to;
// lib/remark-repo-links.mjs points the links there. Runs before `next build` and
// `next dev`.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const docs = path.resolve(here, '../../docs');
const target = path.resolve(here, '../public/docs-assets');

function isAsset(file) {
  return !file.endsWith('.md') && path.basename(file) !== 'meta.json';
}

fs.rmSync(target, { recursive: true, force: true });
let count = 0;
for (const entry of fs.readdirSync(docs, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile()) continue;
  const file = path.join(entry.parentPath, entry.name);
  if (!isAsset(file)) continue;
  const destination = path.join(target, path.relative(docs, file));
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(file, destination);
  count += 1;
}
console.log(`docs-assets: copied ${count} file(s) from docs/`);
