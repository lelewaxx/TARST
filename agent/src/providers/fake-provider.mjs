export class FakeProvider {
  constructor({ chunks = ['嗯，', '我收到你的话了。'], delayMs = 0 } = {}) {
    this.chunks = chunks;
    this.delayMs = delayMs;
  }

  async *stream(_request, signal) {
    for (const text of this.chunks) {
      if (signal.aborted) { return; }
      if (this.delayMs > 0) {
        await delay(this.delayMs, signal);
      }
      if (signal.aborted) { return; }
      yield { type: 'text_delta', text };
    }
  }
}

function delay(milliseconds, signal) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    signal.addEventListener('abort', () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
  });
}
