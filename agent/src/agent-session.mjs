export class AgentSession {
  #history = [];

  constructor(sessionID) {
    this.sessionID = sessionID;
  }

  addUserTurn({ turnID, text, acousticObservation }) {
    this.#history.push({
      role: 'user',
      turnID,
      text,
      acousticObservation: acousticObservation ?? null,
    });
  }

  addAssistantTurn({ turnID, text }) {
    this.#history.push({ role: 'assistant', turnID, text });
  }

  history() {
    return this.#history.map((entry) => structuredClone(entry));
  }
}
