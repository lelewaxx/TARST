import test from 'node:test';
import assert from 'node:assert/strict';
import { createSessionMachine, SessionKind, SessionState } from '../src/runtime/session-state-machine.mjs';

test('one-shot session returns to idle after a response', () => {
  const tarst = createSessionMachine();
  tarst.dispatch({ type: 'WAKE_WORD_DETECTED' });
  tarst.dispatch({ type: 'SPEECH_STARTED' });
  tarst.dispatch({ type: 'INTENT_DETECTED', kind: SessionKind.ONE_SHOT });
  tarst.dispatch({ type: 'TURN_ENDED' });
  const result = tarst.dispatch({ type: 'RESPONSE_FINISHED' });

  assert.deepEqual(result, { state: SessionState.IDLE, kind: SessionKind.NONE, action: 'return-to-idle' });
});

test('companion session returns to listening after a response', () => {
  const tarst = createSessionMachine();
  tarst.dispatch({ type: 'WAKE_WORD_DETECTED' });
  tarst.dispatch({ type: 'SPEECH_STARTED' });
  tarst.dispatch({ type: 'INTENT_DETECTED', kind: SessionKind.COMPANION });
  tarst.dispatch({ type: 'TURN_ENDED' });
  const result = tarst.dispatch({ type: 'RESPONSE_FINISHED' });

  assert.deepEqual(result, { state: SessionState.LISTENING, kind: SessionKind.COMPANION, action: 'continue-companion-session' });
});

test('user speech interrupts TARST while it is responding', () => {
  const tarst = createSessionMachine();
  tarst.dispatch({ type: 'WAKE_WORD_DETECTED' });
  tarst.dispatch({ type: 'SPEECH_STARTED' });
  tarst.dispatch({ type: 'TURN_ENDED' });
  const result = tarst.dispatch({ type: 'SPEECH_STARTED' });

  assert.equal(result.action, 'interrupt-response');
  assert.equal(result.state, SessionState.LISTENING);
});
