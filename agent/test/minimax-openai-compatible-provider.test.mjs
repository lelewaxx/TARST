import assert from 'node:assert/strict';
import test from 'node:test';
import { MiniMaxOpenAICompatibleProvider, toMessages } from '../src/providers/minimax-openai-compatible-provider.mjs';
import { miniMaxChinaBaseURL } from '../src/providers/minimax-endpoints.mjs';

test('maps MiniMax-compatible visible deltas without making a network request', async () => {
  const calls = [];
  const client = {
    chat: { completions: { create: async (request, options) => {
      calls.push({ request, options });
      return (async function* () {
        yield { choices: [{ delta: { reasoning_details: [{ text: 'internal' }] } }] };
        yield { choices: [{ delta: { content: '你好' } }] };
        yield { choices: [{ delta: { content: '。' } }] };
      }());
    } } },
  };
  const provider = new MiniMaxOpenAICompatibleProvider({ client });
  const controller = new AbortController();
  const chunks = [];
  for await (const event of provider.stream({ history: [{ role: 'user', text: '你好' }] }, controller.signal)) {
    chunks.push(event.text);
  }

  assert.deepEqual(chunks, ['你好', '。']);
  assert.equal(calls[0].request.model, 'MiniMax-M2.7-highspeed');
  assert.equal(calls[0].request.stream, true);
  assert.equal(calls[0].request.extra_body.reasoning_split, true);
  assert.equal(calls[0].options.signal, controller.signal);
});

test('constructs a bounded model message list from session history', () => {
  const messages = toMessages({ history: [
    { role: 'user', text: '第一句', acousticObservation: { confidence: 1 } },
    { role: 'assistant', text: '第二句' },
  ] });
  assert.equal(messages.length, 3);
  assert.equal(messages[1].content, '第一句');
  assert.deepEqual(Object.keys(messages[1]), ['role', 'content']);
});

test('defaults to the configured China endpoint', () => {
  const provider = new MiniMaxOpenAICompatibleProvider({ apiKey: 'test-key' });
  assert.equal(provider.client.baseURL, miniMaxChinaBaseURL);
});
