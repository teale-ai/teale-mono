# Teale Docs

Knowledge base for [teale.com/docs](https://teale.com/docs). Built with [Docusaurus 3](https://docusaurus.io/).

## Development

```bash
cd docs-site
npm install
npm start          # Dev server at localhost:3000/docs/
```

## Build for production

```bash
npm run build      # Output in build/
npm run serve      # Preview the production build locally
```

## Deploy to teale-www

The build output goes into a `docs/` directory in the teale-www repo:

```bash
# Build
npm run build

# Copy to teale-www
mkdir -p /path/to/teale-www/docs
cp -r build/* /path/to/teale-www/docs/

# Commit and push teale-www
cd /path/to/teale-www
git add docs/
git commit -m "Update docs"
git push
```

## Node version

Requires Node 18-22. Node 25 has a webpack compatibility issue — pin `webpack@5.97.1` if using Node 25 (already pinned in package.json).

## Structure

```
docs-site/
  docs/                     # Markdown content for the released apps
    index.md                # Landing page (teale.com/docs/)
    getting-started/        # Install + quickstart for macOS and Windows
    guides/                 # App behavior, models, wallet, account
    api/                    # Released local/app HTTP surfaces
    faq.md                  # FAQ
  docusaurus.config.js      # Site config (baseUrl: /docs/)
  sidebars.js               # Navigation sidebar
  src/css/custom.css        # Theme colors (teal)
```
