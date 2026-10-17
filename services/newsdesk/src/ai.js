// ai.js
// One place to call Gemma: through the Gemini API (hosted by Google; the default) or a local
// model served by Ollama. Which one is a setting (config.ai); the Gemini API key stays in .env
// as GEMINI_API_KEY and is never returned by the API.

const config = require('./config');

const GEMINI = 'https://generativelanguage.googleapis.com/v1beta/models';
const TIMEOUT_MS = 180000; // local models on a CPU can be slow

function settings() {
  const ai = config.get().ai || {};
  return {
    provider: ai.provider === 'ollama' ? 'ollama' : 'gemini',
    gemini: { model: (ai.gemini && ai.gemini.model) || 'gemma-4-26b-a4b-it' },
    ollama: {
      url: ((ai.ollama && ai.ollama.url) || 'http://host.docker.internal:11434').replace(/\/+$/, ''),
      model: (ai.ollama && ai.ollama.model) || 'gemma4:12b',
    },
  };
}

const apiKey = () => (process.env.GEMINI_API_KEY || '').trim();

/** Which provider and model are active, and whether they're set up. No network call. */
function status() {
  const s = settings();
  if (s.provider === 'gemini') {
    return {
      provider: 'gemini',
      model: s.gemini.model,
      ready: !!apiKey(),
      problem: apiKey() ? null : 'Add GEMINI_API_KEY to .env, then run docker compose up -d.',
    };
  }
  return { provider: 'ollama', model: s.ollama.model, url: s.ollama.url, ready: true, problem: null };
}

/**
 * Asks Gemma for a reply.
 * @param {{ system?: string, prompt: string, json?: boolean, temperature?: number }} request
 * @returns {Promise<{ text: string, provider: string, model: string, ms: number }>}
 */
async function generate({ system, prompt, json = false, temperature = 0.3 }) {
  const s = settings();
  const started = Date.now();
  const text = s.provider === 'gemini'
    ? await viaGemini(s.gemini.model, system, prompt, temperature)
    : await viaOllama(s.ollama, system, prompt, json, temperature);
  const model = s.provider === 'gemini' ? s.gemini.model : s.ollama.model;
  return { text, provider: s.provider, model, ms: Date.now() - started };
}

/** Google's API occasionally returns "Internal error" / overloaded; one retry usually clears it. */
async function viaGemini(model, system, prompt, temperature) {
  try {
    return await callGemini(model, system, prompt, temperature);
  } catch (err) {
    if (!err.transient) throw err;
    await new Promise((r) => setTimeout(r, 1500));
    return callGemini(model, system, prompt, temperature);
  }
}

async function callGemini(model, system, prompt, temperature) {
  const key = apiKey();
  if (!key) throw new Error('No Gemini API key. Add GEMINI_API_KEY to .env, then run docker compose up -d.');
  // Gemma on the Gemini API doesn't take a separate system instruction, so it leads the prompt.
  const text = system ? `${system}\n\n${prompt}` : prompt;
  let res;
  try {
    res = await fetch(`${GEMINI}/${encodeURIComponent(model)}:generateContent`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text }] }],
        generationConfig: { temperature },
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    throw new Error(`Couldn't reach the Gemini API: ${err.message}`);
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`Gemini API: ${(data.error && data.error.message) || `HTTP ${res.status}`}`);
    err.transient = res.status >= 500;
    if (res.status === 429) err.message += ' (rate limit: wait a minute, or lower "App data sent per question" in Settings → AI)';
    throw err;
  }
  const parts = (((data.candidates || [])[0] || {}).content || {}).parts || [];
  // Leave out the model's reasoning if it's returned as separate "thought" parts.
  const reply = parts.filter((p) => !p.thought).map((p) => p.text || '').join('').trim();
  if (!reply) throw new Error('The Gemini API returned an empty reply.');
  return reply;
}

async function viaOllama({ url, model }, system, prompt, json, temperature) {
  let res;
  try {
    res = await fetch(`${url}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        stream: false,
        ...(json ? { format: 'json' } : {}),
        options: { temperature },
        messages: [...(system ? [{ role: 'system', content: system }] : []), { role: 'user', content: prompt }],
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    throw new Error(`Couldn't reach Ollama at ${url}. Is it running (ollama serve)? ${err.message}`);
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const hint = res.status === 404 ? ` Download the model with: ollama pull ${model}` : '';
    throw new Error(`Ollama: ${data.error || `HTTP ${res.status}`}.${hint}`);
  }
  return ((data.message && data.message.content) || '').trim();
}

/** Pulls the first JSON object or array out of a reply (models sometimes wrap it in prose or ```). */
function parseJSON(text) {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const body = fenced ? fenced[1] : text;
  const start = body.search(/[[{]/);
  const end = Math.max(body.lastIndexOf('}'), body.lastIndexOf(']'));
  if (start === -1 || end < start) throw new Error('The model didn’t return JSON.');
  return JSON.parse(body.slice(start, end + 1));
}

module.exports = { generate, status, parseJSON };
