# Keyless Provider Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Sigma from sending authentication headers when a provider credential is nil, empty, or whitespace-only.

**Architecture:** Keep credential classification in `Sigma.Ai.ProviderAuth`, the shared header-construction boundary used by OpenAI and Anthropic transports. Return an empty header list for blank credentials and leave all existing non-blank header selection and formatting unchanged.

**Tech Stack:** Elixir, ExUnit, Req, Sigma provider streaming

---

### Task 1: Reproduce keyless authentication at the shared and transport seams

**Files:**
- Create: `apps/sigma_ai/test/sigma_ai/provider_auth_test.exs`
- Modify: `apps/sigma_ai/test/sigma_ai/providers/openai_test.exs:465`

- [ ] **Step 1: Add direct blank-credential coverage**

```elixir
defmodule Sigma.Ai.ProviderAuthTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.ProviderAuth

  test "omits authentication headers for blank credentials" do
    for credential <- [nil, "", " \t\n"],
        auth_type <- ["bearer", "x-api-key", "custom_header"] do
      options = [auth_type: auth_type, auth_header_name: "X-Provider-Key"]

      assert ProviderAuth.headers(credential, options, "bearer") == []
    end
  end
end
```

- [ ] **Step 2: Add the OpenAI request regression**

Insert before the existing `uses configured x-api-key auth header` test:

```elixir
test "omits authorization header when api key is blank" do
  sse = [
    ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
    "data: [DONE]\n\n"
  ]

  with_request_capture_server(sse, fn base_url, captured ->
    OpenAI.stream(%{
      model: %{id: "gpt-test", api: "openai", provider: "openai"},
      context: %{messages: [], system_prompt: nil, tools: []},
      options: [api_key: "", base_url: base_url, receive_timeout: 1_000]
    })
    |> Enum.to_list()

    assert %{headers: headers} = Agent.get(captured, & &1)
    refute Map.has_key?(headers, "authorization")
  end)
end
```

- [ ] **Step 3: Run the new tests and verify RED**

Run:

```bash
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps devenv shell --no-tui -- \
  mix test \
  apps/sigma_ai/test/sigma_ai/provider_auth_test.exs \
  apps/sigma_ai/test/sigma_ai/providers/openai_test.exs
```

Expected: failures showing `ProviderAuth.headers/3` returns an auth tuple for blank credentials and the captured OpenAI request contains `authorization`.

### Task 2: Omit authentication for blank credentials

**Files:**
- Modify: `apps/sigma_ai/lib/sigma_ai/provider_auth.ex:4-7`
- Test: `apps/sigma_ai/test/sigma_ai/provider_auth_test.exs`
- Test: `apps/sigma_ai/test/sigma_ai/providers/openai_test.exs`
- Test: `apps/sigma_ai/test/sigma_ai/providers/anthropic_test.exs`

- [ ] **Step 1: Implement blank-credential classification**

```elixir
def headers(api_key, options, default_type) do
  if blank_credential?(api_key) do
    []
  else
    auth_type = normalize_auth_type(options[:auth_type], default_type)
    [{header_name(auth_type, options, default_type), header_value(auth_type, api_key)}]
  end
end

defp blank_credential?(nil), do: true
defp blank_credential?(api_key) when is_binary(api_key), do: String.trim(api_key) == ""
defp blank_credential?(_api_key), do: false
```

- [ ] **Step 2: Run the affected provider suites and verify GREEN**

Run:

```bash
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps devenv shell --no-tui -- \
  mix test \
  apps/sigma_ai/test/sigma_ai/provider_auth_test.exs \
  apps/sigma_ai/test/sigma_ai/providers/openai_test.exs \
  apps/sigma_ai/test/sigma_ai/providers/anthropic_test.exs
```

Expected: 22 tests, 0 failures.

- [ ] **Step 3: Run focused quality gates**

```bash
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps devenv shell --no-tui -- mix compile --warnings-as-errors
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps devenv shell --no-tui -- mix format --check-formatted
git diff --check
```

Expected: every command exits 0 with no warnings or formatting errors.

- [ ] **Step 4: Commit the implementation**

```bash
git add \
  apps/sigma_ai/lib/sigma_ai/provider_auth.ex \
  apps/sigma_ai/test/sigma_ai/provider_auth_test.exs \
  apps/sigma_ai/test/sigma_ai/providers/openai_test.exs
git commit -m "fix(ai): omit auth for blank credentials"
```

### Task 3: Integrate and prove the live repair

**Files:**
- No source changes

- [ ] **Step 1: Fast-forward `main` to the completed worktree branch**

```bash
git merge --ff-only codex/fix-keyless-provider-auth
```

Expected: `main` advances without a merge commit.

- [ ] **Step 2: Restart only Sigma and verify HTTP readiness**

```bash
devenv processes restart sigma
devenv processes status sigma
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:4580/ >/dev/null
```

Expected: Sigma is running and the root endpoint returns HTTP 200.

- [ ] **Step 3: Verify the keyless DGX request through Sigma's provider module**

```bash
devenv shell --no-tui -- mix run -e '
params = %{
  model: %{id: "dgx-spark/qwen3.6-35b-a3b", api: "openai", provider: "dgx-spark"},
  context: %{messages: [], system_prompt: nil},
  options: [
    api_key: "",
    base_url: "http://localhost:4220/v1",
    auth_type: "bearer",
    receive_timeout: 120_000
  ]
}

events = Sigma.Ai.Providers.OpenAI.stream(params) |> Enum.to_list()
{:done, _reason, _message} = Enum.find(events, &match?({:done, _, _}, &1))
'
```

Expected: the stream completes without `AI provider error: "Unauthorized"`.

- [ ] **Step 4: Record the required agent note**

Call `mcp__agent_note__save_note` with:

```json
{
  "title": "Sigma omits auth for keyless AI providers",
  "content": "Document the empty-bearer root cause, the centralized ProviderAuth fix, focused regression coverage, and the live DGX verification evidence.",
  "labels": [["project", "sigma"]]
}
```
