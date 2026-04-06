Add a tracked `Supabase.plist` to this directory to bake the production Supabase
URL, anon key, and optional redirect URL into every Teale app that links AuthKit.

`Supabase.plist` should contain:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_REDIRECT_URL` (optional)

The app-level `Supabase.plist` at the repository root and the corresponding
environment variables remain valid as local overrides.
