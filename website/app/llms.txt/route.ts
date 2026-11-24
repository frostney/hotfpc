import type { Node, Root } from 'fumadocs-core/page-tree';
import { absoluteUrl, getPageMarkdownUrl, pageDescription, source } from '@/lib/source';
import { appName, description } from '@/lib/shared';

export const revalidate = false;

// llms.txt (https://llmstxt.org): the pages by section, each with the absolute URL of its
// Markdown copy and its first sentences. fumadocs' own index gives paths without the
// basePath, which lead nowhere on a GitHub Pages project site.
async function entry(node: Node): Promise<string | undefined> {
  if (node.type !== 'page') return undefined;
  const page = source.getPage(node.url.slice('/docs'.length).split('/').filter(Boolean));
  if (!page) return undefined;
  const summary = await pageDescription(page);
  const link = `- [${String(node.name)}](${absoluteUrl(getPageMarkdownUrl(page).url)})`;
  return summary ? `${link}: ${summary}` : link;
}

export async function GET() {
  const tree: Root = source.getPageTree();
  const top: string[] = [];
  const sections: string[] = [];
  for (const node of tree.children) {
    if (node.type === 'folder') {
      sections.push(`## ${String(node.name)}`, '');
      for (const child of node.children) {
        const line = await entry(child);
        if (line) sections.push(line);
      }
      sections.push('');
    } else {
      const line = await entry(node);
      if (line) top.push(line);
    }
  }
  const text = [
    `# ${appName}`,
    '',
    `> ${description}`,
    '',
    ...top,
    `- [All of the documentation in one file](${absoluteUrl('/llms-full.txt')})`,
    '',
    ...sections,
  ].join('\n');
  return new Response(text, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
}
