# Sigma MCP OOM Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade Sigma to the upstream MCP client release that bounds cyclic tool-schema compilation and restore stable access on port 4580.

**Architecture:** Raise the `sigma_coding` dependency floor to `backplane_mcp_protocol ~> 0.6.2` and resolve the lock to 0.6.2. Keep MCP configuration and Agent Note enabled; rely on the package-owned supervised 500 ms validator timeout rather than a Sigma-specific workaround.

**Tech Stack:** Elixir 1.18, Mix/Hex, Phoenix LiveView, Backplane MCP Protocol, devenv

---

### Task 1: Consume the bounded validator release

**Files:**
- Modify: `apps/sigma_coding/mix.exs:28`
- Modify: `mix.lock:2`

- [ ] **Step 1: Preserve the RED runtime evidence**

Record the already-reproduced signal before editing:

```text
GET http://127.0.0.1:4580/ -> connection refused
devenv phase -> gave_up, restart count 5
release exit -> status 137
kernel OOM victim -> beam.smp at about 29 GiB anonymous RSS
locked dependency -> backplane_mcp_protocol 0.6.0
```

- [ ] **Step 2: Raise the dependency floor**

Change the dependency declaration to:

```elixir
{:backplane_mcp_protocol, "~> 0.6.2"}
```

- [ ] **Step 3: Resolve only the MCP dependency**

```bash
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps \
  devenv shell --no-tui -- mix deps.update backplane_mcp_protocol
```

Expected: `mix.lock` resolves `backplane_mcp_protocol` 0.6.2 without unrelated lock changes.

- [ ] **Step 4: Verify the focused MCP suite**

```bash
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps \
  devenv shell --no-tui -- mix test apps/sigma_coding/test/sigma_coding/mcp_test.exs
```

Expected: all focused MCP tests pass.

- [ ] **Step 5: Run quality gates**

```bash
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps \
  devenv shell --no-tui -- mix compile --warnings-as-errors
env MIX_DEPS_PATH=/home/gao/Workspace/gsmlg-opt/sigma/deps \
  devenv shell --no-tui -- mix format --check-formatted
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit the dependency repair**

```bash
git add apps/sigma_coding/mix.exs mix.lock
git commit -m "fix(mcp): bound tool schema compilation"
```

### Task 2: Integrate and prove stable access

**Files:**
- No source changes

- [ ] **Step 1: Fast-forward the completed branch into `main`**

```bash
git merge --ff-only codex/fix-sigma-access
```

- [ ] **Step 2: Stop the temporary verification service**

```bash
devenv processes stop sigma --no-tui
```

Run that command from `.trees/fix-sigma-runtime`. If port 4580 remains owned by its release BEAM, stop the exact release with:

```bash
.trees/fix-sigma-runtime/_build/dev/sigma_rel/rel/sigma/bin/sigma stop
```

- [ ] **Step 3: Start Sigma from `main`**

```bash
devenv up -d --strict-ports sigma
devenv processes status sigma --no-tui
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:4580/ >/dev/null
```

Expected: phase `ready`, restart count 0, and HTTP 200.

- [ ] **Step 4: Exercise the affected session**

Open:

```text
http://10.100.10.28:4580/repository/L2hvbWUvZ2FvL1dvcmtzcGFjZS9nc21sZy1kZXYvY2xvdWQtZGF0YS1zZXJ2aWNl/sessions/session_VDq8mkv2NTB6tGs7
```

Expected: the page loads, LiveSocket connects, Agent Note `tools/list` completes, and logs contain `schema_validation_disabled` with `reason: :compile_timeout` rather than status 137.

- [ ] **Step 5: Guard memory during the live probe**

Observe the port-owning BEAM for 20 seconds. Fail and stop Sigma if RSS exceeds 2 GiB.

Expected: RSS stays below 2 GiB and the endpoint remains HTTP 200.

- [ ] **Step 6: Record the required Agent Note**

Save a note titled `Sigma upgrades MCP client to bound cyclic schema validation` with the OOM root cause, dependency change, test results, and live browser/RSS evidence. Apply label `project: sigma`.
