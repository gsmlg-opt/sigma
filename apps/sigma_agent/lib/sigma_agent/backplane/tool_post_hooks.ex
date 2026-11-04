defmodule Sigma.Agent.Backplane.ToolPostHooks do
  @moduledoc """
  Synchronous PostToolUse for explicitly selected native Runtime profiles.

  Call `decorate/2` before catalog admission. Descriptors retain their original
  schema, safety, binding and lifecycle context fields. Execution removes only
  this adapter's marker from the live backend context, preserving Runtime host
  callbacks, and invokes the original backend exactly once without the Sigma
  Dispatcher. Actual native settlements are retained separately from presentation.
  Native Code Mode retains Runtime's `register_code_mode` callback so its actual
  worker registers against the current invocation before execution or resumption.

  Trusted context supplies existing `:hook_specs` and hook runner fields. The live
  backend context supplies Runtime's `append_feedback/1` for correlated, fenced
  checkpointing and one-time projection at the next natural provider boundary.
  Acceptance is durable only with a durable Store. An optional explicit
  `on_hook_context.(operation, text)` is a compatibility observer after acceptance,
  or a fallback sink outside Runtime; it returns `:ok` or a typed Runtime error.
  Observer failure cannot undo an already accepted checkpoint.
  Block decisions become model and nested-consumer errors. Stopped-hook reasons
  replace model output while nested consumers retain the completed native value.
  Additional context is delivered independently. Async hooks require a separate
  owned integration.

  Failed native returns do not run success hooks. Hook, projection and sink
  failures after dispatch produce warnings while retaining the native result;
  they cannot truthfully turn a completed effect into a non-dispatch rejection.
  This adapter does not register tools. The pinned Codex hook catalog does not
  contain PostToolUseFailure.
  """

  require Logger

  alias Backplane.AgentRuntime.{Error, ToolEffects, ToolRegistry}
  alias Sigma.Agent.Backplane.{HookContext, HookDelivery}
  alias Sigma.Coding.Hooks
  alias Sigma.Coding.Hooks.{Outcome, Spec.Command}

  @max_response_bytes 1_000_000
  @max_depth 32

  @spec decorate(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def decorate(%{registry: %ToolRegistry{tools: tools}} = profile, context)
      when is_map(context) do
    specs = Map.get(context, :hook_specs, [])

    cond do
      not is_list(specs) ->
        {:error, Error.new(:validation, "native post hooks require a hook specification list")}

      Enum.any?(tools, fn {_name, descriptor} ->
        descriptor[:backend] == __MODULE__ or
            Map.has_key?(Map.get(descriptor, :backend_context, %{}), :sigma_post_hooks)
      end) ->
        {:error, Error.new(:validation, "native post hooks are already installed")}

      not Hooks.any_for_event?(specs, :post_tool_use) ->
        {:ok, profile}

      Enum.any?(specs, &match?(%{event: :post_tool_use, handler: %Command{async: true}}, &1)) and
          not owned_async?(context) ->
        {:error,
         Error.new(
           :unsupported_capability,
           "native async post hooks require owned feedback delivery"
         )}

      true ->
        wrapped =
          Map.new(tools, fn {name, descriptor} ->
            config = %{
              backend: descriptor.backend,
              context: context
            }

            backend_context = Map.put(descriptor.backend_context, :sigma_post_hooks, config)
            {name, %{descriptor | backend: __MODULE__, backend_context: backend_context}}
          end)

        {:ok, %{profile | registry: %{profile.registry | tools: wrapped}}}
    end
  end

  def decorate(_profile, _context),
    do:
      {:error,
       Error.new(:validation, "native post hooks require a Runtime profile and trusted context")}

  @spec execute(map()) :: Backplane.AgentRuntime.ToolEffects.result()
  def execute(%{backend_context: %{sigma_post_hooks: config}} = operation) do
    original = %{
      operation
      | backend_context: Map.delete(operation.backend_context, :sigma_post_hooks)
    }

    backend = config.backend
    result = backend.execute(original)

    case post_tool_use(original, result, config.context) do
      %{type: type, text: _} = decision when type in [:block, :stopped] ->
        {:ok, actual} = result

        case ToolEffects.present(original, actual, decision) do
          {:presented, _} = presented ->
            presented

          {:error, error} ->
            warning(
              "native PostToolUse presentation failed: #{error.message}; native result retained"
            )

            result
        end

      _ ->
        result
    end
  end

  defp post_tool_use(operation, {:ok, result}, context) when is_map(result) do
    if Map.get(result, :is_error, false) == false and not Map.has_key?(result, :error) do
      run_hooks(operation, result, context)
    end
  end

  defp post_tool_use(_operation, _result, _context), do: :ok

  defp run_hooks(operation, result, context) do
    with {:ok, response} <- hook_response(operation.tool_name, result) do
      context =
        case context[:native_async_hooks] do
          %{writer: writer} ->
            Map.put(
              context,
              :hook_async_callback_factory,
              HookDelivery.factory(writer, operation)
            )

          _ ->
            context
        end

      data = %{
        tool_name: operation.tool_name,
        tool_use_id: operation.tool_call_id,
        tool_input: operation.arguments,
        tool_response: response
      }

      {outcome, warnings} = Hooks.dispatch(:post_tool_use, context.hook_specs, context, data)
      Enum.each(warnings, &warning/1)

      feedback = Outcome.context(outcome)
      if feedback not in [nil, ""], do: deliver_context(context, operation, feedback)
      presentation(Outcome.control(outcome))
    else
      {:error, message} -> warning(message)
    end
  rescue
    _ -> warning("native PostToolUse processing failed after dispatch; native result retained")
  catch
    _kind, _reason ->
      warning("native PostToolUse processing exited after dispatch; native result retained")
  end

  defp presentation(:proceed), do: :ok

  defp presentation({:halt, text}) when is_binary(text),
    do: %{type: :stopped, text: text}

  defp presentation({:block, text}) when is_binary(text) and text != "",
    do: %{type: :block, text: text}

  defp presentation(_),
    do: warning("native PostToolUse control presentation is unsupported; native result retained")

  defp owned_async?(%{native_async_hooks: %{writer: writer}, hook_async_runtime: runtime})
       when is_pid(runtime) do
    is_pid(GenServer.whereis(writer)) and Process.alive?(runtime)
  end

  defp owned_async?(_), do: false

  defp deliver_context(context, operation, feedback) do
    context =
      case operation.backend_context[:append_feedback] do
        append when is_function(append, 1) -> Map.put(context, :append_feedback, append)
        _ -> context
      end

    case HookContext.deliver(context, operation, feedback, "PostToolUse") do
      :ok ->
        :ok

      {:error, %Error{message: message}} ->
        warning("native PostToolUse context sink failed: #{message}; native result retained")

      _ ->
        warning(
          "native PostToolUse context sink returned an invalid result; native result retained"
        )
    end
  end

  # Hook stdin is JSON, whereas Runtime's trusted sidecar can retain image bytes
  # and process-local state. Never inspect/stringify those values into payloads.
  defp hook_response("view_image", %{data: data, mime_type: mime, image_url: url} = result)
       when is_binary(data) and is_binary(mime) and is_binary(url) do
    if url == "data:#{mime};base64,#{Base.encode64(data)}" do
      json_response(Map.delete(result, :data))
    else
      {:error,
       "native PostToolUse image projection is invalid; hook skipped and native result retained"}
    end
  end

  defp hook_response(_name, result), do: json_response(result)

  defp json_response(result) do
    with true <- plain_json?(result, @max_depth),
         {:ok, json} <- Jason.encode(result),
         true <- byte_size(json) <= @max_response_bytes,
         {:ok, response} <- Jason.decode(json) do
      {:ok, response}
    else
      _ ->
        {:error,
         "native PostToolUse response is unsafe or exceeds 1 MB; hook skipped and native result retained"}
    end
  end

  defp plain_json?(_value, depth) when depth < 0, do: false
  defp plain_json?(%_{} = _value, _depth), do: false

  defp plain_json?(value, depth) when is_map(value),
    do:
      Enum.all?(value, fn {key, item} ->
        (is_atom(key) or is_binary(key)) and plain_json?(item, depth - 1)
      end)

  defp plain_json?(value, depth) when is_list(value),
    do: Enum.all?(value, &plain_json?(&1, depth - 1))

  defp plain_json?(value, _depth),
    do: is_binary(value) or is_number(value) or is_atom(value)

  defp warning(message), do: Logger.warning("[hooks] #{message}")
end
