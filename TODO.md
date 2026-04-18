# FreeFlow Roadmap

## Phase 1 — LiteLLM compatibility

- [x] Support custom OpenAI-compatible API base URLs
- [x] Treat Phase 1 as complete for this branch/release plan

## Phase 2 — Agent conversations and meeting mode assessment

### Decision

Skip full Phase 2 implementation for now and move to Phase 3.

### Why

- Single-agent use is already plausible with the current push-to-talk flow, but it is still a single transcript pipeline aimed at the active app.
- Multi-agent meeting conversations are not a good fit for the current architecture because FreeFlow currently has:
  - one active microphone selection
  - one recording/transcription pipeline at a time
  - no speaker diarization
  - no structured agent output channel
  - no websocket transport for live downstream consumers
- A real meeting mode would need diarization, routing, structured events, and a dedicated transport layer before it would be reliable for agent orchestration.

### Revisit later if needed

- [ ] Revisit agent meeting mode after streaming transport exists
- [ ] Revisit once speaker diarization or per-speaker routing is available

## Phase 3 — Priority enhancements

### Agent/runtime integration

- [ ] Add a websocket streaming transport for live transcript and status events
- [ ] Make the websocket path work cleanly with LiteLLM
- [ ] Emit structured events for `recording_started`, `partial_transcript`, `final_transcript`, `post_processed_transcript`, and `error`
- [ ] Add a configurable local websocket endpoint in Settings
- [ ] Add an option to send transcripts to agents instead of pasting at the cursor
- [ ] Add a webhook or local HTTP fallback for non-websocket agent consumers

### Streaming and transcription

- [ ] Add real-time streaming transcription support
- [ ] Keep the existing file-upload transcription path as a fallback
- [ ] Add provider capability checks so provider-specific options are only sent when supported

### Future meeting support prerequisites

- [ ] Evaluate speaker diarization providers for shared-mic meeting mode
- [ ] Evaluate multi-microphone routing for per-agent/per-speaker capture
- [ ] Define a structured conversation session format for single-agent and multi-agent consumers
