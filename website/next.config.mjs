import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  // Served at https://frostney.github.io/hotfpc/ (lib/shared.ts mirrors it).
  basePath: '/hotfpc',
  trailingSlash: true,
  reactStrictMode: true,
  // A static export has no image optimiser: images, such as the demo GIFs, are served as
  // they are.
  images: { unoptimized: true },
  // The site renders the repository's docs/ directly, outside website/, so Turbopack's
  // root is the repository.
  turbopack: {
    root: '..',
  },
};

export default withMDX(config);
