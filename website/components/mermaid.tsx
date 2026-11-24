'use client';
// Renders the docs' ```mermaid blocks, which remarkMdxMermaid turns into <Mermaid chart />.
// GitHub renders the same blocks natively, so docs/ stays plain GitHub Markdown. Mermaid
// draws in the browser, in the site's light or dark theme.
import { use, useEffect, useId, useState } from 'react';
import { useTheme } from 'next-themes';

export function Mermaid({ chart }: { chart: string }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    setMounted(true);
  }, []);
  if (!mounted) return null;
  return <MermaidContent chart={chart} />;
}

const cache = new Map<string, Promise<unknown>>();

function cached<T>(key: string, make: () => Promise<T>): Promise<T> {
  let promise = cache.get(key) as Promise<T> | undefined;
  if (!promise) {
    promise = make();
    cache.set(key, promise);
  }
  return promise;
}

function MermaidContent({ chart }: { chart: string }) {
  // Mermaid uses the id in CSS selectors: keep it to letters, digits and dashes.
  const id = `mermaid-${useId().replace(/[^a-zA-Z0-9-]/g, '')}`;
  const { resolvedTheme } = useTheme();
  const { default: mermaid } = use(cached('mermaid', () => import('mermaid')));
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    fontFamily: 'inherit',
    theme: resolvedTheme === 'dark' ? 'dark' : 'default',
  });
  // A chart Mermaid can't parse shows as its source instead of breaking the page.
  const rendered = use(
    cached(`${chart}-${resolvedTheme}`, () =>
      mermaid.render(id, chart).catch((error: unknown) => ({ error: String(error) })),
    ),
  );
  if ('error' in rendered) {
    return (
      <pre className="my-6 overflow-x-auto rounded-lg border p-4 text-sm">
        <code>{chart}</code>
      </pre>
    );
  }
  const { svg, bindFunctions } = rendered;
  return (
    <div
      className="my-6 flex justify-center"
      ref={(container) => {
        if (container) bindFunctions?.(container);
      }}
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}
