defmodule Sigma.Web.Flash do
  use Sigma.Web, :html

  alias Phoenix.LiveView.JS

  attr(:id, :string, default: "flash")
  attr(:flash, :map, default: %{})
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], required: true)
  attr(:autoshow, :boolean, default: true)
  attr(:close, :boolean, default: true)
  attr(:close_label, :string, default: "Close")
  attr(:rest, :global)

  slot(:inner_block)

  def sigma_flash(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-mounted={@autoshow && JS.add_class("toast-open", to: "##{@id}")}
      role="alert"
      aria-live={if(@kind == :error, do: "assertive", else: "polite")}
      aria-atomic="true"
      class={["toast", "toast-#{@kind}"]}
      {@rest}
    >
      <div :if={@title} class="toast-icon" aria-hidden="true">
        <.dm_bsi :if={@kind == :info} name="info-circle" class="w-5 h-5" />
        <.dm_bsi :if={@kind == :error} name="exclamation-circle" class="w-5 h-5" />
      </div>
      <div class="toast-content">
        <div :if={@title} class="toast-title">{@title}</div>
        <div class="toast-message">{msg}</div>
      </div>
      <button
        :if={@close}
        type="button"
        class="toast-close"
        aria-label={@close_label}
        phx-click={
          JS.push("lv:clear-flash", value: %{key: @kind})
          |> JS.remove_class("toast-open", to: "##{@id}")
        }
      >
        <.dm_mdi name="close" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr(:flash, :map, required: true)
  attr(:info_title, :string, default: "Success!")
  attr(:error_title, :string, default: "Error!")
  attr(:disconnected_title, :string, default: "We can't find the internet")
  attr(:reconnecting_text, :string, default: "Attempting to reconnect")

  def sigma_flash_group(assigns) do
    ~H"""
    <div class="toast-container toast-container-top-right">
      <.sigma_flash id="flash-info" kind={:info} title={@info_title} flash={@flash} />
      <.sigma_flash id="flash-error" kind={:error} title={@error_title} flash={@flash} />
      <.sigma_flash
        id="disconnected"
        kind={:error}
        title={@disconnected_title}
        close={false}
        autoshow={false}
        phx-disconnected={JS.add_class("toast-open", to: "#disconnected")}
        phx-connected={JS.remove_class("toast-open", to: "#disconnected")}
      >
        {@reconnecting_text} <.dm_bsi name="arrow-repeat" class="inline ml-1 w-3 h-3 animate-spin" aria-hidden="true" />
      </.sigma_flash>
    </div>
    """
  end
end
