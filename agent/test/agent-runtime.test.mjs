import assert from 'node:assert/strict';
import test from 'node:test';
import { AgentRuntime } from '../src/agent-runtime.mjs';
import { FakeProvider } from '../src/providers/fake-provider.mjs';

const turn = (overrides = {}) => ({
  type: 'turn.start',
  session_id: 'session-1',
  turn_id: 'turn-1',
  generation_id: 'generation-1',
  text: '你好，TARST。',
  ...overrides,
});

test('streams text with a complete generation envelope', async () => {
  const events = [];
  const runtime = new AgentRuntime({
    provider: new FakeProvider({ chunks: ['你', '好'] }),
    emit: (event) => events.push(event),
  });

  await runtime.handle(turn());

  assert.deepEqual(events.map((event) => event.type), [
    'agent.text_delta', 'agent.text_delta', 'agent.text_completed', 'agent.completed',
  ]);
  assert.equal(events[2].text, '你好');
  assert.ok(events.every((event) => event.session_id === 'session-1'));
  assert.ok(events.every((event) => event.generation_id === 'generation-1'));
});

test('cancellation stops a delayed provider and emits no completion', async () => {
  const events = [];
  const runtime = new AgentRuntime({
    provider: new FakeProvider({ chunks: ['第一段', '第二段'], delayMs: 40 }),
    emit: (event) => events.push(event),
  });

  const pending = runtime.handle(turn());
  await new Promise((resolve) => setTimeout(resolve, 5));
  await runtime.handle({ type: 'generation.cancel', generation_id: 'generation-1' });
  await pending;

  assert.deepEqual(events.map((event) => event.type), ['agent.cancelled']);
});

test('invalid protocol returns a safe failure event', async () => {
  const events = [];
  const runtime = new AgentRuntime({ provider: new FakeProvider(), emit: (event) => events.push(event) });

  await runtime.handle({ type: 'turn.start', text: '' });

  assert.equal(events[0].type, 'agent.failed');
  assert.equal(events[0].code, 'invalid_protocol');
});

test('turn requires configuration when no provider was supplied', async () => {
  const events = [];
  const runtime = new AgentRuntime({ emit: (event) => events.push(event) });

  await runtime.handle(turn());

  assert.equal(events[0].code, 'runtime_not_configured');
});

test('runtime configures a provider without exposing the API key', async () => {
  const events = [];
  let received;
  const runtime = new AgentRuntime({
    emit: (event) => events.push(event),
    providerFactory: (configuration) => {
      received = configuration;
      return new FakeProvider({ chunks: ['已', '连接'] });
    },
  });

  await runtime.handle({ type: 'runtime.configure', provider: 'minimax_m3', api_key: 'secret-not-in-output' });
  await runtime.handle(turn());

  assert.equal(received.apiKey, 'secret-not-in-output');
  assert.deepEqual(events.map((event) => event.type), [
    'runtime.configured', 'agent.text_delta', 'agent.text_delta', 'agent.text_completed', 'agent.completed',
  ]);
  assert.equal(JSON.stringify(events).includes('secret-not-in-output'), false);
});

test('runtime accepts the low-latency MiniMax provider identifier', async () => {
  const events = [];
  let received;
  const runtime = new AgentRuntime({
    emit: (event) => events.push(event),
    providerFactory: (configuration) => {
      received = configuration;
      return new FakeProvider();
    },
  });

  await runtime.handle({ type: 'runtime.configure', provider: 'minimax_m27_highspeed', api_key: 'secret-not-in-output' });

  assert.equal(received.provider, 'minimax_m27_highspeed');
  assert.equal(events[0].provider, 'minimax_m27_highspeed');
  assert.equal(JSON.stringify(events).includes('secret-not-in-output'), false);
});

test('runtime accepts benchmarkable MiniMax highspeed provider identifiers', async () => {
  for (const provider of ['minimax_m25_highspeed', 'minimax_m21_highspeed', 'minimax_m2_her']) {
    const events = [];
    const runtime = new AgentRuntime({
      emit: (event) => events.push(event),
      providerFactory: ({ provider: configured }) => ({
        async *stream() {},
        configured,
      }),
    });
    await runtime.handle({ type: 'runtime.configure', provider, api_key: 'secret' });
    assert.equal(events[0].provider, provider);
  }
});

test('runtime completes provider preparation before reporting configured', async () => {
  const events = [];
  const order = [];
  const runtime = new AgentRuntime({
    emit: (event) => events.push(event),
    providerFactory: () => ({
      async prepare() { order.push('prepare'); },
      async *stream() {},
    }),
  });

  await runtime.handle({ type: 'runtime.configure', provider: 'minimax_m27_highspeed', api_key: 'secret' });
  order.push('configured');

  assert.deepEqual(order, ['prepare', 'configured']);
  assert.equal(events[0].type, 'runtime.configured');
});

test('passes safe provider stream metadata through without treating it as text', async () => {
  const events = [];
  const provider = {
    async *stream() {
      yield { type: 'stream_diagnostic', fields: { source: 'delta', candidate_length: 2, relation: 'divergent' } };
      yield { type: 'text_delta', text: '你好' };
    },
  };
  const runtime = new AgentRuntime({ provider, emit: (event) => events.push(event) });

  await runtime.handle(turn());

  assert.deepEqual(events.map((event) => event.type), [
    'agent.stream_diagnostic', 'agent.text_delta', 'agent.text_completed', 'agent.completed',
  ]);
  assert.equal(events[0].fields.candidate_length, 2);
  assert.equal(events[2].text, '你好');
});
