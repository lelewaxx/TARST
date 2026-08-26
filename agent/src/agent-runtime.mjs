import { AgentSession } from './agent-session.mjs';
import { InputEventType, OutputEventType, ProtocolError, validateInputEvent } from './protocol.mjs';

export class AgentRuntime {
  #sessions = new Map();
  #generations = new Map();

  constructor({ provider = null, providerFactory = null, emit }) {
    this.provider = provider;
    this.providerFactory = providerFactory;
    this.emit = emit;
  }

  async handle(input) {
    try {
      const event = validateInputEvent(input);
      if (event.type === InputEventType.RUNTIME_CONFIGURE) {
        await this.configure(event);
        return;
      }
      if (event.type === InputEventType.GENERATION_CANCEL) {
        this.cancel(event.generation_id);
        return;
      }
      await this.startTurn(event);
    } catch (error) {
      this.emit(failureEvent(input, error));
    }
  }

  async configure(input) {
    if (!this.providerFactory) {
      throw new ProtocolError('当前 Runtime 不支持动态 Provider 配置。');
    }
    this.provider = this.providerFactory({ provider: input.provider, apiKey: input.api_key });
    if (!this.provider || typeof this.provider.stream !== 'function') {
      throw new ProtocolError('Provider 配置无效。');
    }
    if (typeof this.provider.prepare === 'function') {
      await this.provider.prepare();
    }
    this.emit({
      type: OutputEventType.RUNTIME_CONFIGURED,
      provider: input.provider,
      timestamp: new Date().toISOString(),
    });
  }

  cancel(generationID) {
    const generation = this.#generations.get(generationID);
    if (!generation || generation.controller.signal.aborted) { return false; }
    generation.controller.abort();
    return true;
  }

  async startTurn(input) {
    if (!this.provider) {
      throw new RuntimeConfigurationError();
    }
    const session = this.getSession(input.session_id);
    const controller = new AbortController();
    this.#generations.set(input.generation_id, { controller });
    session.addUserTurn({
      turnID: input.turn_id,
      text: input.text,
      acousticObservation: input.acoustic_observation,
    });

    let responseText = '';
    try {
      for await (const event of this.provider.stream({
        sessionID: input.session_id,
        turnID: input.turn_id,
        text: input.text,
        history: session.history(),
      }, controller.signal)) {
        if (controller.signal.aborted) { break; }
        if (event.type === 'stream_diagnostic' && event.fields && typeof event.fields === 'object') {
          this.emit(envelope(OutputEventType.STREAM_DIAGNOSTIC, input, { fields: event.fields }));
          continue;
        }
        if (event.type !== 'text_delta' || typeof event.text !== 'string') {
          throw new ProtocolError('Provider 返回了无效事件。');
        }
        responseText += event.text;
        this.emit(envelope(OutputEventType.TEXT_DELTA, input, { text: event.text }));
      }

      if (controller.signal.aborted) {
        this.emit(envelope(OutputEventType.CANCELLED, input));
        return;
      }

      session.addAssistantTurn({ turnID: input.turn_id, text: responseText });
      this.emit(envelope(OutputEventType.TEXT_COMPLETED, input, { text: responseText }));
      this.emit(envelope(OutputEventType.COMPLETED, input));
    } catch (error) {
      if (controller.signal.aborted) {
        this.emit(envelope(OutputEventType.CANCELLED, input));
      } else {
        this.emit(failureEvent(input, error));
      }
    } finally {
      this.#generations.delete(input.generation_id);
    }
  }

  getSession(sessionID) {
    if (!this.#sessions.has(sessionID)) {
      this.#sessions.set(sessionID, new AgentSession(sessionID));
    }
    return this.#sessions.get(sessionID);
  }
}

export function envelope(type, input, fields = {}) {
  return {
    type,
    session_id: input.session_id,
    turn_id: input.turn_id,
    generation_id: input.generation_id,
    timestamp: new Date().toISOString(),
    ...fields,
  };
}

function failureEvent(input, error) {
  const safeProviderError = error?.name === 'ProviderError' && error?.safe === true;
  return {
    type: OutputEventType.FAILED,
    session_id: input?.session_id ?? null,
    turn_id: input?.turn_id ?? null,
    generation_id: input?.generation_id ?? null,
    timestamp: new Date().toISOString(),
    code: error instanceof ProtocolError ? 'invalid_protocol' : error instanceof RuntimeConfigurationError ? 'runtime_not_configured' : safeProviderError ? error.code : 'runtime_failure',
    safe_message: error instanceof ProtocolError || error instanceof RuntimeConfigurationError || safeProviderError ? error.message : 'Agent Runtime 无法完成本轮请求。',
  };
}

class RuntimeConfigurationError extends Error {
  constructor() {
    super('Agent Runtime 尚未完成 Provider 配置。');
  }
}
