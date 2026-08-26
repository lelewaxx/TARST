import readline from 'node:readline';
import { AgentRuntime } from './agent-runtime.mjs';
import { MiniMaxM3Provider } from './providers/minimax-m3-provider.mjs';
import { MiniMaxOpenAICompatibleProvider } from './providers/minimax-openai-compatible-provider.mjs';
import { OutputEventType } from './protocol.mjs';

const write = (event) => process.stdout.write(`${JSON.stringify(event)}\n`);
const runtime = new AgentRuntime({
  emit: write,
  providerFactory: ({ provider, apiKey }) => {
    if (provider === 'minimax_m3') { return new MiniMaxM3Provider({ apiKey }); }
    if (provider === 'minimax_m27_highspeed') {
      return new MiniMaxOpenAICompatibleProvider({ apiKey, model: 'MiniMax-M2.7-highspeed' });
    }
    if (provider === 'minimax_m25_highspeed') {
      return new MiniMaxOpenAICompatibleProvider({ apiKey, model: 'MiniMax-M2.5-highspeed' });
    }
    if (provider === 'minimax_m21_highspeed') {
      return new MiniMaxOpenAICompatibleProvider({ apiKey, model: 'MiniMax-M2.1-highspeed' });
    }
    if (provider === 'minimax_m2_her') {
      return new MiniMaxOpenAICompatibleProvider({ apiKey, model: 'M2-her' });
    }
    throw new Error('不支持的 Provider。');
  },
});
write({ type: OutputEventType.RUNTIME_READY, timestamp: new Date().toISOString() });

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  if (line.trim() === '') { continue; }
  try {
    await runtime.handle(JSON.parse(line));
  } catch {
    write({
      type: OutputEventType.FAILED,
      timestamp: new Date().toISOString(),
      code: 'invalid_json',
      safe_message: '输入不是有效 JSON。',
    });
  }
}
