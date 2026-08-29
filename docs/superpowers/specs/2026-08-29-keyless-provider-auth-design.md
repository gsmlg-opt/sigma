# Keyless Provider Authentication Design

## Problem

Sigma resolves an absent provider credential to an empty string. `Sigma.Ai.ProviderAuth.headers/3` currently converts that value into an authentication header, such as `Authorization: Bearer `. Keyless OpenAI-compatible endpoints reject that malformed header even though the same request succeeds when authentication is omitted.

## Decision

Treat nil, empty, and whitespace-only credentials as an instruction to omit authentication. Keep `ProviderAuth.headers/3` as the shared boundary so OpenAI and Anthropic transports follow one rule:

- blank credential: return no authentication headers;
- non-blank bearer credential: return `Authorization: Bearer <credential>`;
- non-blank x-api-key credential: return `x-api-key: <credential>`;
- non-blank custom credential: retain the configured header name and existing value.

Whitespace is used only to classify a credential as blank. Non-blank credential bytes are not trimmed or otherwise rewritten.

## Alternatives Considered

1. Add a new `none` authentication type to configuration and UI. This makes keyless operation explicit, but expands persistence, validation, and settings scope for behavior already implied by an absent credential.
2. Omit the header only in the OpenAI provider. This fixes the reported request, but duplicates shared authentication policy and leaves the same malformed-header behavior available to Anthropic-compatible endpoints.
3. Omit blank credentials centrally in `ProviderAuth.headers/3`. This is the selected approach because it is the smallest boundary-level correction and preserves every non-empty authentication mode.

## Testing

- Add direct `ProviderAuth` coverage for nil, empty, and whitespace-only credentials.
- Add an OpenAI request-capture regression proving an empty configured key produces no `authorization` header.
- Re-run existing OpenAI and Anthropic provider suites to protect non-empty bearer, x-api-key, and custom-header behavior.
- Re-probe the local DGX endpoint and the affected Sigma session after restart.

## Scope

No settings schema, provider records, credentials, session journal data, or UI behavior changes. No production credential is created or cleared.
