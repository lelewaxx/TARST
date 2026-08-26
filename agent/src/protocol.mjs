export const InputEventType = Object.freeze({
  RUNTIME_CONFIGURE: 'runtime.configure',
  TURN_START: 'turn.start',
  GENERATION_CANCEL: 'generation.cancel',
});

export const OutputEventType = Object.freeze({
  RUNTIME_READY: 'runtime.ready',
  RUNTIME_CONFIGURED: 'runtime.configured',
  TEXT_DELTA: 'agent.text_delta',
  STREAM_DIAGNOSTIC: 'agent.stream_diagnostic',
  TEXT_COMPLETED: 'agent.text_completed',
  COMPLETED: 'agent.completed',
  CANCELLED: 'agent.cancelled',
  FAILED: 'agent.failed',
});

export function validateInputEvent(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ProtocolError('输入必须是 JSON 对象。');
  }

  if (value.type === InputEventType.RUNTIME_CONFIGURE) {
    if (![
      'minimax_m3',
      'minimax_m27_highspeed',
      'minimax_m25_highspeed',
      'minimax_m21_highspeed',
      'minimax_m2_her',
    ].includes(value.provider)) {
      throw new ProtocolError('runtime.configure 需要受支持的 provider。');
    }
    if (typeof value.api_key !== 'string' || value.api_key.trim() === '') {
      throw new ProtocolError('runtime.configure 缺少非空字段：api_key');
    }
    return value;
  }

  if (value.type === InputEventType.TURN_START) {
    for (const field of ['session_id', 'turn_id', 'generation_id', 'text']) {
      if (typeof value[field] !== 'string' || value[field].trim() === '') {
        throw new ProtocolError(`turn.start 缺少非空字段：${field}`);
      }
    }
    return value;
  }

  if (value.type === InputEventType.GENERATION_CANCEL) {
    if (typeof value.generation_id !== 'string' || value.generation_id.trim() === '') {
      throw new ProtocolError('generation.cancel 缺少非空字段：generation_id');
    }
    return value;
  }

  throw new ProtocolError(`不支持的输入事件：${String(value.type)}`);
}

export class ProtocolError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProtocolError';
  }
}
