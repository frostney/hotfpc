# hotfpc's website

The site at <https://frostney.github.io/hotfpc/>: a landing page and the documentation,
rendered from the repository's `docs/` as it is. It is a [Fumadocs](https://fumadocs.dev)
site, exported as static files by Next.js. Building hotfpc doesn't need any of this.

```sh
npm ci
npm run build      # the static export in out/; a broken link in docs/ fails it
npm run start      # out/ at http://localhost:3000/hotfpc/
npm run dev        # a development server with reloading
```

`docs/internals/tooling.md` describes how it is put together and deployed.
