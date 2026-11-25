import { pageDescription, pageTitle, source } from '@/lib/source';
import { createFromSource } from 'fumadocs-core/search/server';

export const revalidate = false;

// The search structure is the one fumadocs' MDX preset exports for each page, made from the
// same headings the page renders, so a result's #anchor is the id of the heading it names.
// The title and the description are the ones the page's metadata and llms.txt give.
export const { staticGET: GET } = createFromSource(source, {
  // https://docs.orama.com/docs/orama-js/supported-languages
  language: 'english',
  buildIndex: async (page) => ({
    title: pageTitle(page),
    description: await pageDescription(page),
    url: page.url,
    id: page.url,
    structuredData: page.data.structuredData,
  }),
});
