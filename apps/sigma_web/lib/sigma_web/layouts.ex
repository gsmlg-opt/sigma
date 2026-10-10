defmodule Sigma.Web.Layouts do
  use Sigma.Web, :html

  import Sigma.Web.Flash

  # Git metadata changes between commits; capture it without runtime config validation.
  @build_info :sigma_web
              |> Application.get_all_env()
              |> Keyword.fetch!(:build_info)
              |> Map.put(
                :built_at,
                DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
              )

  embed_templates("layouts/*")

  attr(:build_info, :map, default: @build_info)

  def version_badge(assigns) do
    info = assigns.build_info
    suffix = if info.environment == :dev, do: "-dev", else: ""

    details =
      Enum.join(
        [
          "Version: #{info.version}#{suffix}",
          "Environment: #{info.environment}",
          "Git ref: #{info.git_ref || "Unknown"}",
          "Commit: #{info.git_sha || "Unknown"}",
          "Release build time: #{info.released_at || if(info.environment == :dev, do: "Not released", else: "Not recorded")}",
          "Build time: #{info.built_at}"
        ],
        "\n"
      )

    assigns = assign(assigns, label: "v#{info.version}#{suffix}", details: details)

    ~H"""
    <.dm_tooltip
      id="app-version"
      content={@details}
      position="bottom"
      color="secondary"
      class="whitespace-pre-line break-all text-left max-w-[min(24rem,calc(100vw-2rem))]"
      :let={trigger_attrs}
    >
      <button
        id="app-version-trigger"
        type="button"
        aria-label="Version details"
        class="inline-flex shrink-0 rounded-full focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-secondary"
        {trigger_attrs}
      >
        <.dm_badge variant="secondary" size="lg" pill class="whitespace-nowrap">
          {@label}
        </.dm_badge>
      </button>
    </.dm_tooltip>
    """
  end

  @doc """
  Computes the `data-theme` attribute value for the root `<html>` element.

  Returns `nil` when the theme is `"default"` (auto) so the analyzer omits the
  `data-theme` attribute, letting DuskMoon's CSS auto-detect the OS color
  scheme via `:root:not([data-theme])`. Only explicit `"sunshine"` and
  `"moonlight"` values are rendered.
  """
  def theme_attr(theme) when theme in ["sunshine", "moonlight"], do: theme
  def theme_attr(_theme), do: nil
end
