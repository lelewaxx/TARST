import assert from 'node:assert/strict';
import test from 'node:test';
import { MiniMaxM3Provider, ProviderError, toMessages } from '../src/providers/minimax-m3-provider.mjs';

function sseResponse(frames) {
  const bytes = new TextEncoder();
  return new Response(new ReadableStream({
    start(controller) {
      for (const frame of frames) { controller.enqueue(bytes.encode(frame)); }
      controller.close();
    },
  }), { headers: { 'content-type': 'text/event-stream' } });
}

test('maps fragmented native M3 SSE frames into visible text deltas', async () => {
  const requests = [];
  const provider = new MiniMaxM3Provider({
    apiKey: 'test-key',
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      return sseResponse([
        'data: {"choices":[{"delta":{"content":"你"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"好"}}]}\n\n',
        'data: [DONE]\n\n',
      ]);
    },
  });
  const controller = new AbortController();
  const received = [];
  for await (const event of provider.stream({ history: [{ role: 'user', text: '你好' }] }, controller.signal)) {
    if (event.type === 'text_delta') { received.push(event.text); }
  }

  assert.deepEqual(received, ['你', '好']);
  assert.match(requests[0].url, /api\.minimaxi\.com\/v1\/text\/chatcompletion_v2$/);
  assert.equal(JSON.parse(requests[0].options.body).stream, true);
});

test('normalizes cumulative M3 snapshots into append-only visible deltas', async () => {
  const provider = new MiniMaxM3Provider({
    apiKey: 'test-key',
    fetchImpl: async () => sseResponse([
      'data: {"choices":[{"message":{"content":"你"}}]}\n\n',
      'data: {"choices":[{"message":{"content":"你好"}}]}\n\n',
      'data: {"choices":[{"message":{"content":"你好！"}}]}\n\n',
      'data: [DONE]\n\n',
    ]),
  });
  const received = [];
  for await (const event of provider.stream({}, new AbortController().signal)) {
    if (event.type === 'text_delta') { received.push(event.text); }
  }
  assert.deepEqual(received, ['你', '好', '！']);
});

test('does not re-emit a repeated cumulative delta', async () => {
  const provider = new MiniMaxM3Provider({
    apiKey: 'test-key',
    fetchImpl: async () => sseResponse([
      'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n',
      'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n',
      'data: {"choices":[{"delta":{"content":"你好，TARST"}}]}\n\n',
      'data: [DONE]\n\n',
    ]),
  });
  const received = [];
  for await (const event of provider.stream({}, new AbortController().signal)) {
    if (event.type === 'text_delta') { received.push(event.text); }
  }
  assert.deepEqual(received, ['你好', '，TARST']);
});

test('turns a MiniMax business error into a safe provider error', async () => {
  const provider = new MiniMaxM3Provider({
    apiKey: 'test-key',
    fetchImpl: async () => sseResponse(['data: {"base_resp":{"status_code":2049}}\n\n']),
  });

  await assert.rejects(
    async () => { for await (const _ of provider.stream({}, new AbortController().signal)) {} },
    (error) => error instanceof ProviderError && error.code === 'provider_failure'
  );
});

test('requires a credential and does not expose acoustic observations in provider messages', () => {
  assert.throws(() => new MiniMaxM3Provider(), ProviderError);
  const messages = toMessages({ history: [{ role: 'user', text: '文本', acousticObservation: { confidence: 1 } }] });
  assert.deepEqual(Object.keys(messages[1]), ['role', 'name', 'content']);
});

test('emits content-free frame diagnostics and observes DONE', async () => {
  const provider = new MiniMaxM3Provider({
    apiKey: 'test-key',
    fetchImpl: async () => sseResponse([
      'data: {"choices":[{"index":0,"delta":{"content":"敏感正文"},"finish_reason":null}]}\n\n',
      'data: [DONE]\n\n',
    ]),
  });
  const diagnostics = [];
  for await (const event of provider.stream({}, new AbortController().signal)) {
    if (event.type === 'stream_diagnostic') { diagnostics.push(event.fields); }
  }

  assert.deepEqual(diagnostics.map((item) => item.lifecycle), ['frame', 'done']);
  assert.equal(diagnostics[0].source, 'delta');
  assert.equal(diagnostics[0].candidate_length, 4);
  assert.equal(JSON.stringify(diagnostics).includes('敏感正文'), false);
});

test('fails a stream that never produces its first data chunk', async () => {
  const provider = new MiniMaxM3Provider({
    apiKey: 'test-key',
    firstTokenTimeoutMs: 10,
    idleTimeoutMs: 50,
    totalTimeoutMs: 100,
    fetchImpl: async () => new Response(new ReadableStream({ start() {} })),
  });

  await assert.rejects(
    async () => { for await (const _ of provider.stream({}, new AbortController().signal)) {} },
    (error) => error instanceof ProviderError && error.code === 'first_token_timeout'
  );
});
