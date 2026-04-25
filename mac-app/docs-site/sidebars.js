/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
module.exports = {
  docs: [
    'index',
    {
      type: 'category',
      label: 'Getting Started',
      items: [
        'getting-started/install-mac',
        'getting-started/install-windows',
        'getting-started/quickstart-chat',
        'getting-started/quickstart-api',
        'getting-started/quickstart-earn',
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
        'guides/app-overview',
        'guides/manage-models',
        'guides/wallet-and-payments',
        'guides/account-and-sign-in',
      ],
    },
    {
      type: 'category',
      label: 'API Reference',
      items: [
        'api/index',
        'api/health',
        'api/models',
        'api/chat-completions',
        'api/app-snapshot',
        'api/app-models',
        'api/app-wallet',
      ],
    },
    'faq',
  ],
};
