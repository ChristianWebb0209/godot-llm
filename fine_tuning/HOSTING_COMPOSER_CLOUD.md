# Hosting Godot Composer on paid GPU inference

Use a **paid cloud inference** provider so your fine-tuned model runs on their GPUs. The Godot RAG service calls an **OpenAI-compatible** chat completions API; most providers support this.

---

## 1. API contract (what the provider must support)

The RAG service uses the OpenAI Python client and expects:

- **Endpoint:** `POST {base_url}/chat/completions`  
  (e.g. `https://api.together.xyz/v1/chat/completions`)
- **Request body:**
  ```json
  {
    "model": "<your-model-name>",
    "messages": [
      { "role": "system", "content": "..." },
      { "role": "user", "content": "..." }
    ]
  }
  ```
- **Response:** Standard OpenAI shape:
  ```json
  {
    "choices": [{ "message": { "content": "<string>" } }],
    "usage": { "prompt_tokens": 0, "completion_tokens": 0 }
  }
  ```

No `tools` or `tool_calls` in the API. Tool calls are **inside the model’s text** (see below).

---

## 2. Model output format (so the plugin gets tool_calls)

The RAG service parses the **raw `content` string**. For tool use to work:

- The model can output optional **plain text** (shown in chat).
- If it wants to run tools, it must append a **single JSON array** at the end of the reply, with no extra text after it:
  ```text
  Here's what I'll do.

  [{"name": "read_file", "arguments": {"path": "res://player.gd"}}]
  ```
- Each element must have `"name"` (string) and `"arguments"` (object).  
  This matches the format you use in `train_lora_gemma_tools.py` (assistant message with `tool_calls`).

So: **train the model to emit that JSON array at the end of the turn.** The hosting provider just returns that text in `message.content`; no special “tool” API is required.

---

## 3. Paid GPU inference options (OpenAI-compatible)

| Provider | Base URL | Deploy custom / fine-tuned | Notes |
|----------|----------|----------------------------|--------|
| **Together** | `https://api.together.xyz/v1` | Yes – upload adapter or full model | Pay per token, OpenAI-compatible, simple. |
| **Replicate** | Use their API; can proxy to OpenAI format | Yes – push Docker image or use their model format | Per-second billing. |
| **Hugging Face Inference Endpoints** | `https://<endpoint>.aws.endpoints.huggingface.cloud` or similar | Yes – deploy from Hub (e.g. your LoRA + base) | OpenAI-compatible option on some endpoints. |
| **RunPod** | Your pod URL + `/v1` if using their OpenAI-compatible server | Yes – run vLLM/your server on a pod | You manage server; pay for pod time. |
| **Groq** | `https://api.groq.com/openai/v1` | Limited to their models today | Not for arbitrary fine-tunes. |
| **OpenAI** | `https://api.openai.com/v1` | Fine-tune via OpenAI; deploy as their model | Use if you fine-tune on OpenAI. |

Recommended for “upload my fine-tune and pay per use”: **Together** or **Hugging Face Inference Endpoints**.

### Together (example)

1. Create an account at [together.xyz](https://together.xyz).
2. Upload your model (or LoRA + base) and create a “model” that’s callable by name.
3. Get your API key from the dashboard.
4. **Base URL:** `https://api.together.xyz/v1`  
   **Model:** the exact name you gave the model (e.g. `your-username/godot-composer-7b`).

### Hugging Face Inference Endpoints (example)

1. Push your model (or adapter) to the Hub.
2. Create an **Inference Endpoint** (GPU), select “Serverless” or “Standard” and an OpenAI-compatible container if offered.
3. Use the endpoint URL as base (e.g. `https://xxx.aws.endpoints.huggingface.cloud`) and the **model name** as shown in the endpoint docs.
4. Use a Hugging Face token with “read” (or “inference”) as API key where the plugin asks for one.

---

## 4. Godot plugin settings

1. **Backend:** choose **Godot Composer** (not RAG).
2. **RAG service URL:** leave as your RAG server (e.g. `http://127.0.0.1:8000`). The plugin talks to RAG; RAG talks to the cloud API.
3. **Base URL (optional):** the provider’s API base, e.g.  
   `https://api.together.xyz/v1`  
   (no `/chat/completions` – the client adds that).
4. **OpenAI API key:** the provider’s API key (Together, HF token, etc.).
5. **Default model (Composer):** the **model name** the provider uses (e.g. `your-username/godot-composer-7b` on Together, or the endpoint model name on HF).

Save; then use the assistant with Godot Composer. Requests go: **Plugin → your RAG service → provider’s /chat/completions** with that base URL, key, and model. The RAG service parses `content` and extracts tool_calls from the trailing JSON array.

---

## 5. Quick checklist

- [ ] Model is trained to output tool_calls as a JSON array at the end of the assistant reply (as in your training data).
- [ ] Model is deployed on a provider that exposes an **OpenAI-compatible** `POST .../chat/completions` with `model` and `messages`.
- [ ] Plugin: Backend = **Godot Composer**, Base URL = provider base, API key = provider key, Model = deployed model name.
- [ ] RAG service is running and reachable from the Godot editor (so the plugin can send requests to it).
