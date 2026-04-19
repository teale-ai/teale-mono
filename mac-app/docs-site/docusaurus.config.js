// @ts-check

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Teale Docs',
  tagline: 'Decentralized AI inference network',
  favicon: 'img/favicon.ico',

  url: 'https://teale.com',
  baseUrl: '/docs/',

  onBrokenLinks: 'warn',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.js',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: {
        defaultMode: 'light',
        respectPrefersColorScheme: true,
      },
      navbar: {
        title: 'teale',
        items: [
          {
            to: '/getting-started/quickstart-chat',
            label: 'Quickstart',
            position: 'left',
          },
          {
            to: '/api/',
            label: 'API',
            position: 'left',
          },
          {
            to: '/cli/',
            label: 'CLI',
            position: 'left',
          },
          {
            to: '/guides/',
            label: 'Guides',
            position: 'left',
          },
          {
            to: '/protocol/',
            label: 'Protocol',
            position: 'left',
          },
          {
            href: 'https://teale.com',
            label: 'teale.com',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              { label: 'Getting Started', to: '/getting-started/' },
              { label: 'API Reference', to: '/api/' },
              { label: 'CLI Reference', to: '/cli/' },
            ],
          },
          {
            title: 'More',
            items: [
              { label: 'teale.com', href: 'https://teale.com' },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Teale.`,
      },
    }),
};

export default config;
