import {
  getPageImageUrl,
  getPageMarkdownUrl,
  pageDescription,
  pageTitle,
  source,
} from '@/lib/source';
import {
  DocsBody,
  DocsPage,
  MarkdownCopyButton,
  ViewOptionsPopover,
} from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { appName, basePath, gitConfig, siteUrl } from '@/lib/shared';

export default async function Page(props: PageProps<'/docs/[[...slug]]'>) {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  const MDX = page.data.body;
  const markdownUrl = getPageMarkdownUrl(page).url;
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'TechArticle',
    headline: pageTitle(page),
    description: await pageDescription(page),
    url: `${siteUrl}${page.url}`,
    isPartOf: {
      '@type': 'WebSite',
      name: `${appName} documentation`,
      url: `${siteUrl}/docs`,
    },
  };

  return (
    <DocsPage toc={page.data.toc} full={page.data.full}>
      {/* The Markdown carries its own H1 (docs/ stays GitHub Markdown), so there is no
          separate title. */}
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <div className="flex flex-row gap-2 items-center border-b pb-6">
        <MarkdownCopyButton markdownUrl={`${basePath}${markdownUrl}`} />
        <ViewOptionsPopover
          markdownUrl={`${siteUrl}${markdownUrl}`}
          githubUrl={`https://github.com/${gitConfig.user}/${gitConfig.repo}/blob/${gitConfig.branch}/docs/${page.path}`}
        />
      </div>
      <DocsBody>
        <MDX
          components={getMDXComponents({
            a: createRelativeLink(source, page),
          })}
        />
      </DocsBody>
    </DocsPage>
  );
}

export async function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata(props: PageProps<'/docs/[[...slug]]'>): Promise<Metadata> {
  const params = await props.params;
  const page = source.getPage(params.slug);
  if (!page) notFound();

  return {
    title: pageTitle(page),
    description: await pageDescription(page),
    alternates: { canonical: `${siteUrl}${page.url}/` },
    openGraph: {
      images: `${basePath}${getPageImageUrl(page).url}`,
    },
  };
}
