defmodule Sigma.Agent.Backplane.ChildPermission do
  @moduledoc """
  Strict JSON reply codec for the managed child's Sigma permission channel.

  Runtime approval and user-input answers use their own independent codecs.
  This envelope crosses the public manager boundary; trusted preparation decodes
  it back into the existing permission interceptor's allow/deny/map-edit reply.
  """

  alias Backplane.AgentRuntime.{Conversation, Error}

  @kind "sigma_tool_permission_reply"

  def encode(:allow), do: {:ok, %{"kind" => @kind, "decision" => "allow"}}

  def encode({:allow, patch}) when is_map(patch) do
    checked(%{"kind" => @kind, "decision" => "allow", "arguments_patch" => patch})
  end

  def encode({:deny, reason}) when is_atom(reason), do: encode({:deny, Atom.to_string(reason)})

  def encode({:deny, reason}) when is_binary(reason) do
    checked(%{"kind" => @kind, "decision" => "deny", "reason" => reason})
  end

  def encode(_), do: invalid()

  def decode(%{"kind" => @kind, "decision" => "allow"} = reply) when map_size(reply) == 2,
    do: {:ok, :allow}

  def decode(%{"kind" => @kind, "decision" => "allow", "arguments_patch" => patch} = reply)
      when map_size(reply) == 3 and is_map(patch) do
    if json?(reply), do: {:ok, {:allow, patch}}, else: invalid()
  end

  def decode(%{"kind" => @kind, "decision" => "deny", "reason" => reason} = reply)
      when map_size(reply) == 3 and is_binary(reason) do
    if json?(reply), do: {:ok, {:deny, reason}}, else: invalid()
  end

  def decode(_), do: invalid()

  # Require the public bounded JSON projection to preserve the value exactly;
  # coercing atom keys/values would silently change an edited tool input.
  defp json?(value), do: match?({:ok, ^value}, Conversation.public_interaction(value))

  defp checked(reply), do: if(json?(reply), do: {:ok, reply}, else: invalid())

  defp invalid, do: {:error, Error.new(:validation, "invalid child Sigma permission reply")}
end
