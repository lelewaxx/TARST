import OpenAI from 'openai';
import { miniMaxChinaBaseURL } from './minimax-endpoints.mjs';

/**
 * Low-latency MiniMax fallback. This adapter owns only wire-format conversion;
 * session history, tool policy, and cancellation policy remain in TARST.
 */
export class MiniMaxOpenAICompatibleProvider {
  constructor({ apiKey, model = 'MiniMax-M2.7-highspeed', client, fetch: fetchImpl } = {}) {
    this.model = model;
    this.fetch = fetchImpl ?? globalThis.fetch;
    this.client = client ?? new OpenAI({
      apiKey,
      baseURL: miniMaxChinaBaseURL,
      fetch: this.fetch,
    });
  }

  async prepare() {
    // Pay DNS/TCP/TLS setup while TARST is starting, in parallel with the much
    // longer user speech path. OpenAI's client uses this same fetch dispatcher,
    // so a drained HEAD response leaves a reusable connection to the API host.
    try {
      const response = await this.fetch(miniMaxChinaBaseURL, {
        method: 'HEAD',
        signal: AbortSignal.timeout(2_500),
      });
      await response.arrayBuffer();
    } catch {
      // Preconnect is opportunistic. The real request still owns error handling.
    }
  }

  async *stream(request, signal) {
    const stream = await this.client.chat.completions.create({
      model: this.model,
      messages: toMessages(request),
      stream: true,
      // Keeps reasoning separate from visible text when the endpoint supports it.
      extra_body: { reasoning_split: true },
    }, { signal });

    for await (const chunk of stream) {
      if (signal.aborted) { return; }
      const text = chunk.choices?.[0]?.delta?.content;
      if (typeof text === 'string' && text.length > 0) {
        yield { type: 'text_delta', text };
      }
    }
  }
}

export function toMessages(request) {
  const history = request.history ?? [];
  return [
    {
      role: 'system',
      content: '你是 TARST。回答应简洁、自然、适合语音朗读。不要把不确定的声学线索当作用户情绪事实。',
    },
    ...history.map(({ role, text }) => ({ role, content: text })),
  ];
}
