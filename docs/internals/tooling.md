# Tooling

> **Audience: contributors.** The tools for working on hotfpc, the hook and CI.

| Tool | Version | Used for |
| --- | --- | --- |
| Free Pascal | 3.2.2 (the pinned compiler); also tested with fpc-toolchain's 3.2.4-rc and 3.3.1 | building hotfpc; the scenarios use it to build the test programs |
| fpcres | ships with fpc | turns the agent's source into a resource of hotfpc ([build system](build-system.md#the-embedded-agent)) |
| Python | 3.9 or later | the scenario tests in `tests/scenarios/` and the reference check |
| Lefthook | 1.5 or later | the pre-commit hook in [`lefthook.yml`](../../lefthook.yml) (`lefthook install` once per clone) |
| Node.js | 22 or later, with `npx`: `markdownlint-cli2` 0.24.0 and its `markdownlint` 0.42.0 require it | the Markdown lint (`markdownlint-cli2` 0.24.0, which `npx` fetches) and the website (`website/`) |
| tmux, vim, asciinema, agg, ffmpeg | any recent | recording the terminal demo with `scripts/record-demo.py`; only needed to re-record ([demos](demos.md)) |

Only fpc is needed to build hotfpc. Everything else is for working on it.

## The pre-commit hook

`lefthook.yml` runs `./build.sh hotfpc tests` before each commit that changes the source,
which builds hotfpc and runs the unit tests. Before each commit that changes the source or
`docs/reference/`, it also runs the reference check.

The scenarios take about two minutes, so CI runs them, not the hook. Don't bypass
the hook with `--no-verify` unless the maintainer agrees.

## The documentation checks

`docs/` is written for people who use hotfpc (guides and a reference) and for people who
change it (these pages). Two checks keep it honest, and CI's `docs` job runs both.

### The reference check

```sh
python3 scripts/check-reference-docs.py
```

`docs/reference/` is written by hand. The check reads `source/HotFPC.pas` and
`source/HotFPC.Agent.pas` and fails when the reference:

- doesn't quote the usage text exactly as hotfpc prints it;
- has no table row of its own for an option in the usage text, or names an option the
  usage text doesn't have;
- misses a `[hot]` line the driver prints, including the error it prints when a compile or
  link fails without an error from fpc, or a restart reason, note or error the agent sends
  back;
- has no table row for a `HOT_*` environment variable named in `source/`.

A line counts as documented when its fixed parts appear in order on one line of
`docs/reference/`; the parts filled in at run time can be written as `<unit>`, `<ms>` and
so on. So a new option or a new `[hot]` line fails CI until it is documented, usually in
[command line](../reference/cli.md) or [output](../reference/output.md).

### Markdown lint

```sh
npx --yes markdownlint-cli2@0.24.0
```

The rules are in `.markdownlint-cli2.jsonc`: ATX headings, two-space list indents, fenced
code blocks with a language; long lines and inline HTML are allowed. `CHANGELOG.md` is left
out.

## CI

`.github/workflows/ci.yml` runs on pull requests and on pushes to main. On Linux x86-64,
Linux arm64 (GitHub's `ubuntu-24.04-arm` runner) and macOS arm64 with fpc 3.2.2 it builds
hotfpc, runs the unit tests and runs the scenarios. On Windows it builds `hotfpc.exe` with `build.bat`,
runs the unit tests and runs the scenarios with `hotfpc.exe`. The `docs` job runs the
reference check and the Markdown lint.

`.github/workflows/release.yml` builds the release binaries for a version tag
([releasing](releasing.md)), and `.github/workflows/pages.yml` builds and deploys the
website (below).

## The website

<https://frostney.github.io/hotfpc/> is a landing page and `docs/` rendered as it is. It is
a [Fumadocs](https://fumadocs.dev) site in `website/`, exported as static files by Next.js
with the basePath `/hotfpc`. Only the landing page and the glue live in `website/`; every
documentation page is a file in `docs/`, ordered by the `meta.json` in each folder, with
its H1 as its title. Node and the site's packages are for the website only: building
hotfpc doesn't need them.

```sh
cd website
npm ci
npm run build      # the static export in website/out
npm run start      # website/out at http://localhost:3000/hotfpc/
```

- `lib/remark-repo-links.mjs` maps the links in `docs/`: a link to a page becomes the
  page's route, a link to a file under `docs/` that isn't a page (the demo recordings, an
  image) becomes the site's copy of it, which `scripts/sync-docs-assets.mjs` makes before
  each build, and any other link in the repository becomes its GitHub URL. A link or image
  whose target doesn't exist fails the build.
- `lib/remark-term-links.mjs` links the first mention of a few tools on each page (Free
  Pascal, raylib, lwpt, Wine).
- A ```` ```mermaid ```` block is drawn in the browser by `components/mermaid.tsx`; GitHub
  draws the same block natively.
- The site has a static search index, `llms.txt` and `llms-full.txt` with absolute URLs, a
  Markdown copy of every page, an Open Graph image per page and a sitemap.
- `package.json` pins every package to an exact version, and `package-lock.json` the rest.

`pages.yml` builds the site on every pull request that touches `docs/` or `website/`, so a
broken link fails the pull request, and deploys it from pushes to main.
