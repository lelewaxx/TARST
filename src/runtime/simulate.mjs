import { createSessionMachine, SessionKind } from './session-state-machine.mjs';

const tarst = createSessionMachine();
const events = [
  { type: 'WAKE_WORD_DETECTED' },
  { type: 'SPEECH_STARTED' },
  { type: 'INTENT_DETECTED', kind: SessionKind.COMPANION },
  { type: 'TURN_ENDED' },
  { type: 'RESPONSE_FINISHED' },
  { type: 'END_SESSION' }
];

for (const event of events) console.log(event.type, '→', tarst.dispatch(event));
