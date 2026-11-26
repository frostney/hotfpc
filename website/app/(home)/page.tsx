import Link from 'next/link';
import type { Metadata } from 'next';
import { codeToHtml } from 'shiki';
import { basePath, description, gitConfig, siteUrl } from '@/lib/shared';

export const metadata: Metadata = {
  title: { absolute: 'hotfpc: hot reloading for Free Pascal' },
  description:
    'Save a unit while your Free Pascal program runs, and it carries on with the new code and its variables, objects, files and threads. One binary, every fpc from 3.2.2 on.',
  alternates: { canonical: `${siteUrl}/` },
};

const INSTALL = 'brew install fpc frostney/tap/hotfpc';

const SESSION = `$ hotfpc demo.pas
[hot] v1: built in 228.0 ms, started in 5.0 ms, 2 units of its own, watching 2 files
score   19  ####################
[hot] v2 swapped: scene: 2 functions redirected (1 with other code, 0 new), ...
score   20  *
...
[hot] restart needed: scene.Score: the declaration changed its layout or type (...)
[hot] v5 restarted: the program starts over; 387.0 ms after the save was seen (...)`;

// One source for the visible questions and the FAQPage JSON-LD; answers are plain text.
const FAQ: { q: string; a: string }[] = [
  {
    q: 'What is hotfpc?',
    a: 'Hot reloading for Free Pascal. You run your program under hotfpc instead of building and starting it yourself. When you save a unit, hotfpc compiles it and the running program carries on with the new code and everything it had: its variables, objects, open files and threads.',
  },
  {
    q: 'Do I have to change my program?',
    a: 'No. hotfpc builds the program with your fpc and your options, and adds a small unit, the agent, with fpc’s -Fa option. Keep the code you want to change in units: the main program’s block is already running and keeps its old code.',
  },
  {
    q: 'What happens when an edit can’t be swapped in?',
    a: 'Some edits change what the running state is made of, such as a variable’s size, a record’s fields or a class’s virtual methods. hotfpc names the declaration in the way and starts the program over with the new code. With --no-restart, the program keeps running its old code instead.',
  },
  {
    q: 'Which systems and compilers does it support?',
    a: 'Programs for macOS on arm64 and x86-64, Linux on x86-64 and arm64, and Windows on x86-64, natively or under Wine, with Free Pascal 3.2.2 or later. hotfpc compiles its agent with your fpc, so one hotfpc works with every fpc from 3.2.2 on.',
  },
];

function jsonLd() {
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'SoftwareApplication',
        name: 'hotfpc',
        description,
        url: siteUrl,
        applicationCategory: 'DeveloperApplication',
        operatingSystem: 'macOS, Linux, Windows',
        license: 'https://opensource.org/license/mit',
        codeRepository: `https://github.com/${gitConfig.user}/${gitConfig.repo}`,
        programmingLanguage: 'Pascal',
        offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
      },
      {
        '@type': 'FAQPage',
        mainEntity: FAQ.map(({ q, a }) => ({
          '@type': 'Question',
          name: q,
          acceptedAnswer: { '@type': 'Answer', text: a },
        })),
      },
    ],
  };
}

export default async function HomePage() {
  const github = `https://github.com/${gitConfig.user}/${gitConfig.repo}`;
  const highlight = (code: string, lang: string) =>
    codeToHtml(code, {
      lang,
      themes: { light: 'github-light', dark: 'github-dark' },
      defaultColor: false,
    });
  const installHtml = await highlight(INSTALL, 'sh');
  const sessionHtml = await highlight(SESSION, 'text');
  const codeClass =
    'landing-code rounded-lg border text-left text-sm overflow-x-auto [&>pre]:p-4 [&>pre]:m-0 [&>pre]:bg-transparent';
  return (
    <main className="flex flex-col items-center px-4 py-16 gap-14">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd()) }}
      />
      <section className="flex flex-col items-center text-center gap-5 max-w-2xl">
        <h1 className="text-4xl font-bold">hotfpc</h1>
        <p className="text-lg text-fd-muted-foreground">
          Hot reloading for{' '}
          <a href="https://www.freepascal.org" className="underline">
            Free Pascal
          </a>
          . Save a unit while your program runs, and the program carries on with the new
          code and everything it had: its variables, objects, open files and threads. If an
          edit changes something the running program depends on, hotfpc names the
          declaration in the way and starts the program over.
        </p>
        <div className="flex flex-wrap justify-center gap-3">
          <Link
            href="/docs/guides/quick-start"
            className="rounded-full bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground"
          >
            Get started
          </Link>
          <Link href="/docs" className="rounded-full border px-5 py-2.5 font-medium">
            Documentation
          </Link>
          <a href={github} className="rounded-full border px-5 py-2.5 font-medium">
            GitHub
          </a>
        </div>
      </section>

      <section className="w-full max-w-4xl">
        {/* The raylib recording, docs/raylib-demo.mp4: it plays only when asked, with the
            browser's own controls, so nothing moves beside the text on its own. A new
            recording replaces that file and shows here as it is. */}
        <video
          controls
          playsInline
          preload="metadata"
          aria-label="hotfpc running examples/raylib: scene.pas is edited in vim on the left, and the game on the right takes four saves without losing its balls, then starts over by itself after a fifth"
          className="w-full h-auto rounded-lg border"
        >
          <source src={`${basePath}/docs-assets/raylib-demo.mp4`} type="video/mp4" />
          <a href={`${basePath}/docs-assets/raylib-demo.mp4`}>The recording of the raylib example</a>
        </video>
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          A real run of the raylib example on macOS: five saves to{' '}
          <code>scene.pas</code>. The first four are each swapped into the running game about
          100 ms after hotfpc sees the save; the fifth grows a variable, and the game starts over
          with it by itself.{' '}
          <Link href="/docs/guides/raylib" className="underline">
            With raylib →
          </Link>
        </p>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">Install</h2>
        <div className={codeClass} dangerouslySetInnerHTML={{ __html: installHtml }} />
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          That command is for macOS on Apple silicon and for Linux. On an Intel Mac,
          Homebrew installs hotfpc but has no prebuilt fpc: the platforms page gives the
          steps there, says which systems have a release archive, and from which release,
          and hotfpc builds from source with nothing but fpc.{' '}
          <Link href="/docs/reference/platforms" className="underline">
            Platforms →
          </Link>
        </p>
      </section>

      <section className="w-full max-w-4xl">
        <h2 className="text-xl font-semibold mb-3 text-center">Run, edit, save</h2>
        <div className={codeClass} dangerouslySetInnerHTML={{ __html: sessionHtml }} />
        <p className="mt-3 text-sm text-fd-muted-foreground text-center">
          Every save is swapped in, or restarts the program, or leaves it running with fpc’s
          errors.{' '}
          <Link href="/docs/guides/saves-and-restarts" className="underline">
            What a save does →
          </Link>
        </p>
      </section>

      <section className="w-full max-w-2xl">
        <h2 className="text-xl font-semibold mb-3 text-center">Questions</h2>
        <div className="flex flex-col gap-4">
          {FAQ.map(({ q, a }) => (
            <details key={q} className="rounded-lg border bg-fd-card p-4 text-sm">
              <summary className="font-medium cursor-pointer">{q}</summary>
              <p className="mt-2 text-fd-muted-foreground">{a}</p>
            </details>
          ))}
        </div>
      </section>
    </main>
  );
}
