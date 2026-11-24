import type { Metadata } from 'next';
import { Provider } from '@/components/provider';
import { appName, description } from '@/lib/shared';
import './global.css';

export const metadata: Metadata = {
  // The origin only: page URLs (canonical, Open Graph images) carry the basePath.
  metadataBase: new URL('https://frostney.github.io'),
  title: {
    template: `%s | ${appName}`,
    default: appName,
  },
  description,
  openGraph: {
    siteName: appName,
    type: 'website',
  },
  twitter: {
    card: 'summary_large_image',
  },
};

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
