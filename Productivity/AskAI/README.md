# Ask AI

Ask an AI model from the palette with your own key. Type a question and press
**Tab** (Stackbar 0.36 and later; you can change what Tab does in Settings ›
Command Palette), or **Return** on **Ask AI** under the results for any text:
it is asked at once. Type again in the answer view and press Return to ask a
follow-up with the conversation so far, or ⌘Return to start a new one. Return
on an answer copies it and ⌘P pastes it into the app you were in.

- **Commands:**
  - **Ask AI:** a question, with follow-ups. Also offered under the
    palette's results for anything you type.
  - **Fix Spelling and Grammar**, **Improve Writing** and **Make Shorter**
    replace the selected text with the result (your clipboard comes back
    afterwards).
  - **Summarize Selection** and **Explain Selection** show the answer in the
    palette, with follow-ups.
  - The panel has a question box and the last answer.
- **Providers:** Anthropic is the default, with Claude Opus 5.5 at low effort
  for quick answers; name another model in Settings, such as
  `claude-haiku-5-5` for cheaper ones. OpenAI, OpenRouter (`openrouter/auto`
  picks a model per question), Ollama on your own Mac (no key, nothing sent
  anywhere) and your own LiteLLM proxy are the others. Answers arrive whole
  rather than word by word.
- **LiteLLM:** uses the same `LITELLM_PROXY_URL` and `LITELLM_API_KEY` as the
  LiteLLM plugin, so if that one is set up there is nothing to enter. Settings
  lists the models your key may use (from the proxy's `/v1/models`) to pick
  from, with a button to list them again; until you pick one, the first is
  used. The URL works with or without `/v1` at the end.
- **Needs:** the selection (`.context`), the clipboard (to paste results),
  `api.anthropic.com`, `api.openai.com`, `openrouter.ai` and `localhost`
  (Ollama), the LiteLLM proxy you enter as `LITELLM_PROXY_URL` and no other
  host, and one of the secrets `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `OPENROUTER_API_KEY` or `LITELLM_API_KEY`, asked for only for the provider
  you use. Your
  question, the conversation and, for the text commands, the selected text go
  to that provider.
- **Surfaces:** panel, settings. No menu-bar item.
- **Settings:** the provider and its model.

## What's new in 1.2.0

- Return on Ask AI under the palette's results asks what you typed, as Tab
  does, instead of leaving it in the answer view's field.
- One field: the question. The small "Ask anything" box beside it is gone,
  and with it a request sent for every letter typed there.
- One question at a time. Typing while an answer is on its way neither
  cancels it nor asks again; Return on the follow-up asks once it is in.
- Reopening the palette on the same question shows its answer again rather
  than asking it again.

## What's new in 1.1.0

- LiteLLM as a provider: ask your own proxy, with its models in a picker.
  Shares its URL and key with the LiteLLM plugin.

## What's new in 1.0.0

- First version: Ask AI with follow-ups and Tab from the palette, five
  commands on selected text, and Anthropic, OpenAI, OpenRouter or Ollama.
