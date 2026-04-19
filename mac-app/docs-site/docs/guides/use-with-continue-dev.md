# IDE Integration

Connect your code editor to Teale for AI-powered autocomplete, chat, and code generation --- all running locally on your Mac.

---

## Prerequisites

- Teale running with a model loaded (`teale up`)
- Your editor of choice installed

## Continue.dev (VS Code / JetBrains)

[Continue](https://continue.dev) is an open-source AI code assistant that supports custom backends.

1. Install the Continue extension from the VS Code marketplace (or JetBrains plugin marketplace).
2. Open Continue's configuration file. In VS Code, run the command **Continue: Open Config File** or edit `~/.continue/config.json` directly.
3. Add Teale as a model provider:

    ```json
    {
        "models": [
            {
                "title": "Teale Local",
                "provider": "openai",
                "model": "llama-3.1-8b-instruct-4bit",
                "apiBase": "http://localhost:11435/v1",
                "apiKey": "not-needed"
            }
        ]
    }
    ```

4. Save the file. Continue will reload automatically.
5. Open the Continue sidebar and select "Teale Local" from the model dropdown.

### Tab autocomplete

To use Teale for tab completions, add a `tabAutocompleteModel` entry:

```json
{
    "tabAutocompleteModel": {
        "title": "Teale Autocomplete",
        "provider": "openai",
        "model": "llama-3.1-8b-instruct-4bit",
        "apiBase": "http://localhost:11435/v1",
        "apiKey": "not-needed"
    }
}
```

## Cursor

[Cursor](https://cursor.com) supports custom OpenAI-compatible endpoints.

1. Open Cursor Settings (Cmd+,).
2. Navigate to **Models** > **Add Model**.
3. Select **OpenAI-compatible** as the provider type.
4. Set the base URL to `http://localhost:11435/v1`.
5. Leave the API key field empty or enter any placeholder value.
6. Select the model name from the dropdown (Cursor will query the `/v1/models` endpoint).
7. Save and start using Teale in Cursor's chat and inline edit features.

## Open WebUI

[Open WebUI](https://openwebui.com) is a self-hosted chat interface that supports OpenAI-compatible backends.

1. Open your Open WebUI instance in a browser.
2. Go to **Settings** > **Connections**.
3. Add a new OpenAI connection:
    - **URL:** `http://localhost:11435`
    - **API Key:** leave empty or enter any value
4. Save. Available models will appear in the model selector.

## Zed

[Zed](https://zed.dev) supports custom language model providers.

1. Open Zed settings (Cmd+,).
2. Add an OpenAI-compatible provider in your `settings.json`:

    ```json
    {
        "language_models": {
            "openai": {
                "api_url": "http://localhost:11435/v1",
                "available_models": [
                    {
                        "name": "llama-3.1-8b-instruct-4bit",
                        "display_name": "Teale Local",
                        "max_tokens": 8192
                    }
                ]
            }
        }
    }
    ```

3. Open the assistant panel and select "Teale Local" from the model picker.

## Any OpenAI-compatible tool

Any application that lets you configure a custom OpenAI API endpoint works with Teale. The pattern is always the same:

1. Set the base URL to `http://localhost:11435/v1`.
2. Set the API key to any non-empty string (or leave blank if the tool allows it).
3. Select the model name returned by the `/v1/models` endpoint.

If the tool requires a specific model name, run `teale models list` to see what is currently loaded.

---

## Next steps

- [Use Teale with OpenAI SDK](use-with-openai-sdk.md) --- programmatic access from Python and Node.js
- [Manage Models](manage-models.md) --- switch between models for different tasks
- [API Key Management](api-keys.md) --- secure access when sharing over the network
