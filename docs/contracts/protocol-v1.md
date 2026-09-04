# Sigma Protocol V1

Sigma Protocol V1 is the stable command/event boundary for LiveView, direct
Elixir integrations, JSON Lines automation, and remote WebSocket clients. All
adapters call `Sigma.Agent.PublicRuntime`; transports do not own Agent lifecycle
rules. Synapsis / Samgita integration cookbook:
[public-runtime-integration.md](public-runtime-integration.md).

## Envelope

Every JSON envelope contains:

```json
{
  "version": 1,
  "id": "request-or-event-id",
  "sessionId": "session-id",
  "turnId": "optional-turn-id",
  "timestamp": 1788249600000,
  "kind": "command",
  "type": "prompt.submit",
  "payload": {},
  "error": null
}
```

`kind` is `command` or `event`. Unknown versions and types are rejected without
creating atoms. Encoded envelopes are limited to 64 KiB. Payloads never contain
PIDs, references, ports, functions, exception structs, or internal OTP names.

The initial command and event sets are available from
`Sigma.Protocol.Envelope.commands/0` and `events/0`.

## Direct Elixir API

Build a command with `Sigma.Protocol.Envelope.command/4` and pass it to
`Sigma.Agent.PublicRuntime.execute/2`. The trusted context supplies repository
paths and runtime provider configuration; those process-local values are never
serialized.

```elixir
{:ok, command} =
  Sigma.Protocol.Envelope.command(
    "prompt.submit",
    "session-id",
    %{"content" => "Inspect the repository"}
  )

Sigma.Agent.PublicRuntime.execute(command, %{
  repo_path: repo_path,
  sessions_dir: sessions_dir
})
```

Attach a subscriber with `subscription.attach`. Events arrive as
`{:sigma_protocol, subscription_id, envelope}`. A subscriber disconnect removes
only its relay and never cancels the active turn. Intermediate events may be
dropped for a lagging subscriber; ordered terminal events are retained.

## JSON Lines stdio

`Sigma.Agent.Stdio.run/3` reads one encoded command per line and writes encoded
response and subscription event envelopes. EOF disconnects the adapter without
cancelling a running turn. Callers embedding the adapter provide the same trusted
runtime context as the direct API.

## WebSocket

Phoenix exposes Protocol V1 at `/agent/websocket`. Connect with the Base64-URL
repository key as the `repository` parameter and a capability token as `token`,
then join `session:<session-id>`. The server token comes from
`SIGMA_PROTOCOL_TOKEN` (at least 32 bytes); when it is absent the Agent socket is
disabled. Only repositories already registered in Sigma are accepted.

Send channel event `command` with `%{"data" => encoded_envelope}`. Responses and
stream events use channel event `event` with the same shape. Reconnecting clients
can issue `session.status` for the current snapshot and then
`subscription.attach` to resume future event consumption.

Reconnect snapshots retain the latest five bounded messages and report
`messageCount` plus `messagesTruncated`; complete history remains available
through the session dump operation. Protocol dump/export paths are confined to
the registered repository (or a trusted adapter-supplied artifact root), and
replacement requires an explicit trusted adapter capability.

Interactive approval clients attach a subscription before prompting. They
receive `permission.required` and answer with `permission.resolve`. With no
resolver attached, an explicit `ask` policy produces a structured
`approval_required` error; allow-all remains the default.
