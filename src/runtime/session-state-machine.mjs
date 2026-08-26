export const SessionState = Object.freeze({
  IDLE: 'idle',
  AWAKE: 'awake',
  LISTENING: 'listening',
  RESPONDING: 'responding'
});

export const SessionKind = Object.freeze({
  NONE: 'none',
  ONE_SHOT: 'one-shot',
  COMPANION: 'companion'
});

export function createSessionMachine() {
  let state = SessionState.IDLE;
  let kind = SessionKind.NONE;

  function snapshot() { return { state, kind }; }
  function transition(nextState, nextKind = kind, action) {
    state = nextState;
    kind = nextKind;
    return { ...snapshot(), action };
  }

  return {
    snapshot,
    dispatch(event) {
      switch (event.type) {
        case 'WAKE_WORD_DETECTED':
          if (state !== SessionState.IDLE) return { ...snapshot(), action: 'ignore' };
          return transition(SessionState.AWAKE, SessionKind.NONE, 'acknowledge-wake');

        case 'SPEECH_STARTED':
          if (state === SessionState.AWAKE || state === SessionState.LISTENING) {
            return transition(SessionState.LISTENING, kind, 'keep-listening');
          }
          if (state === SessionState.RESPONDING) {
            return transition(SessionState.LISTENING, kind, 'interrupt-response');
          }
          return { ...snapshot(), action: 'ignore' };

        case 'INTENT_DETECTED':
          if (state !== SessionState.LISTENING) return { ...snapshot(), action: 'ignore' };
          return transition(state, event.kind, 'set-session-kind');

        case 'TURN_ENDED':
          if (state !== SessionState.LISTENING) return { ...snapshot(), action: 'ignore' };
          return transition(SessionState.RESPONDING, kind, 'prepare-response');

        case 'RESPONSE_FINISHED':
          if (state !== SessionState.RESPONDING) return { ...snapshot(), action: 'ignore' };
          return kind === SessionKind.COMPANION
            ? transition(SessionState.LISTENING, kind, 'continue-companion-session')
            : transition(SessionState.IDLE, SessionKind.NONE, 'return-to-idle');

        case 'END_SESSION':
        case 'SESSION_TIMED_OUT':
          if (state === SessionState.IDLE) return { ...snapshot(), action: 'ignore' };
          return transition(SessionState.IDLE, SessionKind.NONE, 'return-to-idle');

        default:
          throw new Error(`Unknown session event: ${event.type}`);
      }
    }
  };
}
