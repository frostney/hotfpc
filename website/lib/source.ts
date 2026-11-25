import { loader } from 'fumadocs-core/source';
import { basePath, docsContentRoute, docsImageRoute, docsRoute, siteUrl } from './shared';
import { defineDocs } from 'fumadocs-mdx/macro';
import { metaSchema, pageSchema } from 'fumadocs-core/source/schema';
import { z } from 'zod';
import { remarkMdxMermaid } from 'fumadocs-core/mdx-plugins';
import { applyMdxPreset } from 'fumadocs-mdx/config';
import { remarkRepoLinks } from './remark-repo-links.mjs';
import { remarkTermLinks } from './remark-term-links.mjs';

const docs = defineDocs({
  // The site renders the repository's docs/ as it is: no second copy, no frontmatter.
  // Only the landing page and glue live under website/.
  dir: '../docs',
  docs: {
    // docs/ is plain GitHub Markdown: a page's title is its H1, and the body keeps it.
    schema: pageSchema.extend({ title: z.string().optional() }),
    // the Markdown of each page, for llms.txt, the Markdown copies and the search index:
    // plain GitHub Markdown, so without the `[#id]` fumadocs puts after each heading by default
    postprocess: {
      includeProcessedMarkdown: { headingIds: false },
    },
    // fumadocs' own preset: GitHub Markdown (tables), heading ids and the table of contents,
    // the search structure, and syntax highlighting. The macro takes plain processor
    // options otherwise, which leaves all of that out.
    mdxOptions: applyMdxPreset({
      // ```mermaid blocks become <Mermaid chart />, which GitHub draws natively
      remarkPlugins: [remarkRepoLinks, remarkTermLinks, remarkMdxMermaid],
      // images are mapped to the site's copy of docs/ by remarkRepoLinks
      remarkImageOptions: false,
      rehypeCodeOptions: {
        themes: {
          light: 'github-light',
          dark: 'github-dark',
        },
        // the languages the docs' fences name
        langs: ['pascal', 'sh', 'bash', 'bat', 'powershell', 'python', 'toml', 'json', 'yaml'],
      },
    }),
  },
  meta: {
    schema: metaSchema,
  },
});

export const source = loader({
  baseUrl: docsRoute,
  source: docs.toFumadocsSource(),
  plugins: [],
});

export type DocsPage = (typeof source)['$inferPage'];

// The title of a page: its H1, which fumadocs-mdx's postprocess puts in page.data.title when
// there is no frontmatter, as for every page of docs/. A page without an H1 gets its file
// name ('quick-start' becomes 'Quick Start'), and the docs root 'Documentation'. The page's
// metadata, its structured data, its Open Graph image and the search index all use this.
export function pageTitle(page: DocsPage): string {
  if (page.data.title) return page.data.title;
  const slug = page.slugs.at(-1);
  if (!slug) return 'Documentation';
  return slug
    .split('-')
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

// The meta description of a page without frontmatter: its first paragraph of prose from
// the processed Markdown, without inline Markdown, cut at a word to 160 characters.
export async function pageDescription(page: DocsPage): Promise<string | undefined> {
  if (page.data.description) return page.data.description;
  const processed = await page.data.getText('processed');
  const firstParagraph = processed
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .find((block) => block.length > 0 && !/^(#|>|\||`|- |\* |\d+\. |!\[|<)/.test(block));
  if (!firstParagraph) return undefined;
  const text = firstParagraph
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[`*_]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (text.length <= 160) return text;
  return text.slice(0, 157).replace(/\s+\S*$/, '') + '…';
}

export function getPageImageUrl(page: DocsPage) {
  const segments = [...page.slugs, 'image.png'];
  return {
    segments,
    url: '/' + [page.locale, ...docsImageRoute.split('/'), ...segments].filter(Boolean).join('/'),
  };
}

export function getPageMarkdownUrl(page: DocsPage) {
  const segments = [...page.slugs, 'content.md'];
  return {
    segments,
    url: '/' + [page.locale, ...docsContentRoute.split('/'), ...segments].filter(Boolean).join('/'),
  };
}

// Absolute URLs: llms.txt and the Markdown copies are read outside the site, where a path
// without the basePath leads nowhere.
export function absoluteUrl(path: string): string {
  return `${siteUrl}${path}`;
}

// The links remark-repo-links writes are site paths: a page as /docs/..., which Next
// prefixes with the basePath in the HTML, and a file as /hotfpc/docs-assets/.... Read
// outside the site, both need the origin, and a page also the basePath. A link to a section
// of the same page (#section) needs the page's own URL. Code blocks are left as they are.
const siteOrigin = new URL(siteUrl).origin;

function absoluteSitePath(target: string, pageUrl: string): string {
  if (target.startsWith('#')) return `${pageUrl}${target}`;
  if (target.startsWith(`${basePath}/`)) return `${siteOrigin}${target}`;
  if (target === docsRoute || target.startsWith(`${docsRoute}/`) || target.startsWith(`${docsRoute}#`)) {
    return absoluteUrl(target);
  }
  return target;
}

export function absoluteLinks(markdown: string, pageUrl: string): string {
  const fence = /^ {0,3}(`{3,}|~{3,})/;
  let open: string | undefined;
  return markdown
    .split('\n')
    .map((line) => {
      const marker = fence.exec(line)?.[1];
      if (open) {
        if (marker && marker[0] === open[0] && marker.length >= open.length) open = undefined;
        return line;
      }
      if (marker) {
        open = marker;
        return line;
      }
      return line
        .replace(/(\]\(\s*<?)([/#][^\s)>]*)/g, (_, before: string, target: string) => before + absoluteSitePath(target, pageUrl))
        .replace(/^(\s*\[[^\]]+\]:\s*<?)([/#]\S*?)(>?)$/, (_, before: string, target: string, after: string) => before + absoluteSitePath(target, pageUrl) + after);
    })
    .join('\n');
}

// The canonical URL of a page, with the trailing slash its exported route has: the canonical
// link, the sitemap, the structured data and the Markdown copies all name it so.
export function canonicalUrl(page: DocsPage): string {
  return `${absoluteUrl(page.url)}/`;
}

export async function getLLMText(page: DocsPage) {
  const processed = await page.data.getText('processed');
  const url = canonicalUrl(page);
  return `URL: ${url}

${absoluteLinks(processed, url)}`;
}
