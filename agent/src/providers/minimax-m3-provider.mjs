import { miniMaxChinaBaseURL } from './minimax-endpoints.mjs';

/**
 * Native MiniMax M3 adapter. It converts provider SSE frames into TARST's small
 * LLM event vocabulary and deliberately exposes only visible text deltas.
 */
export class MiniMaxM3Provider {
  constructor({
    apiKey,
    model = 'MiniMax-M3',
    fetchImpl = fetch,
    firstTokenTimeoutMs = 15_000,
    idleTimeoutMs = 15_000,
    totalTimeoutMs = 90_000,
  } = {}) {
    if (!apiKey) { throw new ProviderError('missing_credentials', 'MiniMax API Key 未配置。'); }
    this.apiKey = apiKey;
    this.model = model;
    this.fetchImpl = fetchImpl;
    this.firstTokenTimeoutMs = firstTokenTimeoutMs;
    this.idleTimeoutMs = idleTimeoutMs;
    this.totalTimeoutMs = totalTimeoutMs;
  }

  async *stream(request, signal) {
    const startedAt = Date.now();
    const requestController = new AbortController();
    const abortRequest = () => requestController.abort(signal.reason);
    signal.addEventListener('abort', abortRequest, { once: true });
    let response;
    try {
      response = await withTimeout(this.fetchImpl(`${miniMaxChinaBaseURL}/text/chatcompletion_v2`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: this.model,
        messages: toMessages(request),
        max_completion_tokens: 512,
        stream: true,
      }),
        signal: requestController.signal,
      }), this.firstTokenTimeoutMs, () => {
        requestController.abort();
        return new ProviderError('response_timeout', 'MiniMax 在限定时间内没有开始响应。');
      });
    } finally {
      signal.removeEventListener('abort', abortRequest);
    }

    if (!response.ok) {
      throw new ProviderError('http_failure', `MiniMax 服务返回 HTTP ${response.status}。`);
    }
    if (!response.body) {
      throw new ProviderError('invalid_response', 'MiniMax 流式响应为空。');
    }

    // The native endpoint normally uses `delta.content`, but some responses
    // carry the accumulated answer in `message.content` (and gateways can do
    // the same for delta). Normalize both shapes to append-only fragments.
    // Passing cumulative snapshots through as deltas made the UI continually
    // rewrite itself and sent duplicated text into the TTS sentence queue.
    const visible = new VisibleTextAccumulator();
    let eventIndex = 0;
    for await (const frame of parseSSE(response.body, {
      signal,
      firstTokenTimeoutMs: this.firstTokenTimeoutMs,
      idleTimeoutMs: this.idleTimeoutMs,
      totalTimeoutMs: this.totalTimeoutMs,
      startedAt,
    })) {
      if (signal.aborted) { return; }
      eventIndex += 1;
      if (frame.kind === 'done') {
        yield diagnostic({ lifecycle: 'done', event_index: eventIndex });
        return;
      }
      const payload = frame.payload;
      assertServiceSuccess(payload);
      const choice = payload.choices?.[0];
      const source = typeof choice?.delta?.content === 'string' ? 'delta'
        : typeof choice?.message?.content === 'string' ? 'message' : 'none';
      const text = source === 'delta' ? choice.delta.content
        : source === 'message' ? choice.message.content : undefined;
      const result = visible.append(text);
      yield diagnostic({
        lifecycle: 'frame',
        event_index: eventIndex,
        choice_index: choice?.index ?? 0,
        source,
        candidate_length: typeof text === 'string' ? text.length : 0,
        emitted_length: result.emittedLength,
        relation: result.relation,
        finish_reason: typeof choice?.finish_reason === 'string' ? choice.finish_reason : 'none',
      });
      if (result.delta) {
        yield { type: 'text_delta', text: result.delta };
      }
    }
    yield diagnostic({ lifecycle: 'stream_closed', event_index: eventIndex });
  }
}

class VisibleTextAccumulator {
  #emitted = '';

  append(value) {
    if (typeof value !== 'string' || value.length === 0) {
      return { delta: '', relation: 'empty', emittedLength: this.#emitted.length };
    }
    if (value === this.#emitted) {
      return { delta: '', relation: 'equal', emittedLength: this.#emitted.length };
    }
    if (this.#emitted.startsWith(value)) {
      return { delta: '', relation: 'shorter', emittedLength: this.#emitted.length };
    }
    if (value.startsWith(this.#emitted)) {
      const delta = value.slice(this.#emitted.length);
      this.#emitted = value;
      return { delta, relation: 'prefix', emittedLength: this.#emitted.length };
    }
    // This is a genuine fragment (the usual streaming form), rather than a
    // cumulative snapshot. Append it exactly once.
    this.#emitted += value;
    return { delta: value, relation: 'divergent', emittedLength: this.#emitted.length };
  }
}

export class ProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ProviderError';
    this.code = code;
    this.safe = true;
  }
}

export function toMessages(request) {
  return [
    {
      role: 'system',
      name: 'TARST',
      content: '你是 TARST。回答应简洁、自然、适合语音朗读。不要把不确定的声学线索当作用户情绪事实。',
    },
    ...(request.history ?? []).map(({ role, text }) => ({ role, name: role === 'assistant' ? 'TARST' : 'user', content: text })),
  ];
}

async function* parseSSE(body, { signal, firstTokenTimeoutMs, idleTimeoutMs, totalTimeoutMs, startedAt }) {
  const decoder = new TextDecoder();
  let pending = '';
  let receivedChunk = false;
  const reader = body.getReader();
  try {
    while (true) {
      if (signal.aborted) { return; }
      const totalRemaining = totalTimeoutMs - (Date.now() - startedAt);
      if (totalRemaining <= 0) {
        throw new ProviderError('stream_total_timeout', 'MiniMax 本轮响应超过最大时长。');
      }
      const phaseTimeout = receivedChunk ? idleTimeoutMs : firstTokenTimeoutMs;
      const timeoutMs = Math.min(phaseTimeout, totalRemaining);
      let result;
      try {
        result = await withAbortAndTimeout(reader.read(), signal, timeoutMs, () => new ProviderError(
          totalRemaining <= phaseTimeout ? 'stream_total_timeout' : receivedChunk ? 'stream_idle_timeout' : 'first_token_timeout',
          totalRemaining <= phaseTimeout ? 'MiniMax 本轮响应超过最大时长。' : receivedChunk ? 'MiniMax 流长时间没有新数据。' : 'MiniMax 在限定时间内没有返回首个数据块。'
        ));
      } catch (error) {
        if (signal.aborted) { return; }
        throw error;
      }
      if (result.done) { break; }
      receivedChunk = true;
      pending += decoder.decode(result.value, { stream: true });
      const split = splitEvents(pending);
      pending = split.pending;
      for (const event of split.events) {
        if (event === '[DONE]') { yield { kind: 'done' }; return; }
        yield { kind: 'payload', payload: JSON.parse(event) };
      }
    }
  } finally {
    if (signal.aborted) { try { await reader.cancel(); } catch {} }
    reader.releaseLock();
  }
  pending += decoder.decode();
  const finalEvent = eventData(pending);
  if (finalEvent === '[DONE]') { yield { kind: 'done' }; }
  else if (finalEvent) { yield { kind: 'payload', payload: JSON.parse(finalEvent) }; }
}

function diagnostic(fields) {
  return { type: 'stream_diagnostic', fields };
}

function withTimeout(promise, timeoutMs, makeError) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(makeError()), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function withAbortAndTimeout(promise, signal, timeoutMs, makeError) {
  let timer;
  let abort;
  const interruption = new Promise((_, reject) => {
    abort = () => reject(signal.reason ?? new DOMException('Aborted', 'AbortError'));
    signal.addEventListener('abort', abort, { once: true });
    timer = setTimeout(() => reject(makeError()), timeoutMs);
  });
  return Promise.race([promise, interruption]).finally(() => {
    clearTimeout(timer);
    signal.removeEventListener('abort', abort);
  });
}

function splitEvents(source) {
  const parts = source.split(/\r?\n\r?\n/);
  const pending = parts.pop() ?? '';
  return { pending, events: parts.map(eventData).filter(Boolean) };
}

function eventData(frame) {
  return frame
    .split(/\r?\n/)
    .filter((line) => line.startsWith('data:'))
    .map((line) => line.slice(5).trimStart())
    .join('\n');
}

function assertServiceSuccess(payload) {
  const code = payload.base_resp?.status_code;
  if (typeof code === 'number' && code !== 0) {
    throw new ProviderError('provider_failure', `MiniMax 服务返回业务错误 ${code}。`);
  }
}
