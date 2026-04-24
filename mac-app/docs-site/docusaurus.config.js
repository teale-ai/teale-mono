// @ts-check

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Teale Docs',
  tagline: 'Released macOS and Windows app documentation',
  favicon: 'img/favicon.ico',

  url: 'https://teale.com',
  baseUrl: '/docs/',

  onBrokenLinks: 'warn',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

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
            to: '/getting-started/install-mac',
            label: 'Install',
            position: 'left',
          },
          {
            to: '/guides/app-overview',
            label: 'App',
            position: 'left',
          },
          {
            to: '/api/',
            label: 'API',
            position: 'left',
          },
          {
            to: '/faq',
            label: 'FAQ',
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
              { label: 'Install on Mac', to: '/getting-started/install-mac' },
              { label: 'Install on Windows', to: '/getting-started/install-windows' },
              { label: 'App Overview', to: '/guides/app-overview' },
              { label: 'API Reference', to: '/api/' },
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
