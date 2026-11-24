// Link mapping for rendering the repository's docs/ directly. A link to a page inside
// docs/ becomes a site route; a link to a file the docs keep beside their pages (the demo
// recordings) and an image become that file in the site's copy, docs-assets/; a link that
// leaves docs/ (README.md, the source, the examples) becomes its GitHub URL. Every target is
// checked against the working tree, so a broken link or image fails the build.
import path from 'node:path';
import fs from 'node:fs';
import { visit } from 'unist-util-visit';

const githubBase = 'https://github.com/frostney/hotfpc';
// Mirrors basePath in lib/shared.ts and next.config.mjs: an <img> or a plain <a> doesn't
// get it from Next.
const basePath = '/hotfpc';
const assetsRoute = '/docs-assets';

// The repository's root is the directory that holds source/HotFPC.pas, found from the file
// being processed: bundlers move import.meta paths.
function findRepoRoot(from) {
  let dir = from;
  for (;;) {
    if (fs.existsSync(path.join(dir, 'source', 'HotFPC.pas'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error(`repository root not found above ${from}`);
    dir = parent;
  }
}

function isAbsolute(href) {
  return /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#') || href.startsWith('//');
}

// The target of a relative link, checked: it exists and stays in the repository.
function resolveTarget(href, filePath, what) {
  const repoRoot = findRepoRoot(path.dirname(filePath));
  const [target, hash] = href.split('#');
  const resolved = path.resolve(path.dirname(filePath), decodeURI(target));
  const from = path.relative(repoRoot, filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`broken ${what} "${href}" in ${from}: ${path.relative(repoRoot, resolved)} does not exist`);
  }
  if (path.relative(repoRoot, resolved).startsWith('..')) {
    throw new Error(`${what} "${href}" in ${from} leaves the repository`);
  }
  return { repoRoot, resolved, suffix: hash ? '#' + hash : '' };
}

// A file under docs/ that isn't a page: the site serves its copy.
function assetPath(repoRoot, resolved) {
  const fromDocs = path.relative(path.join(repoRoot, 'docs'), resolved);
  if (fromDocs.startsWith('..') || fs.statSync(resolved).isDirectory()) return undefined;
  if (resolved.endsWith('.md') || path.basename(resolved) === 'meta.json') return undefined;
  return `${basePath}${assetsRoute}/${fromDocs.split(path.sep).join('/')}`;
}

function mapLink(node, filePath) {
  if (isAbsolute(node.url)) return;
  const { repoRoot, resolved, suffix } = resolveTarget(node.url, filePath, 'link');
  const fromDocs = path.relative(path.join(repoRoot, 'docs'), resolved);
  if (!fromDocs.startsWith('..') && resolved.endsWith('.md')) {
    const slug = fromDocs.replace(/\.md$/, '').split(path.sep).join('/').replace(/(^|\/)index$/, '');
    node.url = `/docs/${slug}${slug ? '/' : ''}${suffix}`;
    return;
  }
  const asset = assetPath(repoRoot, resolved);
  if (asset) {
    // a plain link, not a route: the file is served as it is
    node.url = asset;
    node.data = { ...node.data, hProperties: { ...(node.data?.hProperties ?? {}), external: true } };
    return;
  }
  const repoRelative = path.relative(repoRoot, resolved).split(path.sep).join('/');
  const kind = fs.statSync(resolved).isDirectory() ? 'tree' : 'blob';
  node.url = `${githubBase}/${kind}/main/${repoRelative}${suffix}`;
}

function mapImage(node, filePath) {
  if (isAbsolute(node.url)) return;
  const { repoRoot, resolved } = resolveTarget(node.url, filePath, 'image');
  const asset = assetPath(repoRoot, resolved);
  if (!asset) {
    throw new Error(
      `image "${node.url}" in ${path.relative(repoRoot, filePath)} must be a file under docs/ for the site to serve it`,
    );
  }
  node.url = asset;
}

export function remarkRepoLinks() {
  return (tree, file) => {
    // A definition that a reference-style image uses is that image's source.
    const imageDefinitions = new Set();
    visit(tree, 'imageReference', (node) => {
      imageDefinitions.add(node.identifier);
    });
    visit(tree, ['link', 'definition'], (node) => {
      if (node.type === 'definition' && imageDefinitions.has(node.identifier)) mapImage(node, file.path);
      else mapLink(node, file.path);
    });
    visit(tree, 'image', (node) => {
      mapImage(node, file.path);
    });
  };
}
