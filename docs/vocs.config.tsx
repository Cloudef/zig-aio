import { defineConfig } from 'vocs'
import plainText from 'vite-plugin-virtual-plain-text';

export default defineConfig({
  basePath: '/zig-aio',
  baseUrl: 'https://cloudef.github.io/zig-aio',
  title: 'zig-aio',
  titleTemplate: '%s - zig-aio',
  description: 'IO-uring like asynchronous API and coroutine powered IO tasks for zig',
  editLink: {
    pattern: 'https://github.com/Cloudef/zig-aio/edit/master/docs/pages/:path',
    text: 'Suggest changes to this page',
  },
  rootDir: '.',
  socials: [
    {
      icon: "github",
      link: "https://github.com/Cloudef/zig-aio",
    },
  ],
  head: (
    <>
      <meta
        name="keywords"
        content="zig, aio, coroutines, async, io"
      />
      <meta property="og:url" content="https://cloudef.github.io/zig-aio" />
    </>
  ),
  topNav: [
    { text: "Docs", link: "/" },
    {
      text: "Examples",
      link: "https://github.com/Cloudef/zig-aio/tree/master/examples",
    },
  ],
  sidebar: [
    {
      text: 'Getting Started',
      items: [{text: 'Overview', link: '/'}],
    },
    {
      text: 'Integration',
      items: [{text: 'Integrating zig-aio', link: '/integration'}],
    },
    {
      text: 'AIO API',
      collapsed: false,
      items: [
        {
          text: 'Operations',
          link: '/aio-operations',
        },
        {
          text: 'Immediate',
          link: '/aio-immediate',
        },
        {
          text: 'Dynamic',
          link: '/aio-dynamic',
        },
      ],
    },
    {
      text: 'CORO API',
      collapsed: false,
      items: [
        {
          text: 'Scheduler',
          link: '/coro-scheduler',
        },
        {
          text: 'IO',
          link: '/coro-io',
        },
        {
          text: 'Context switches',
          link: '/coro-context-switches',
        },
        {
          text: 'Mixing blocking code',
          link: '/coro-blocking-code',
        },
      ],
    },
  ],
})
