defmodule Sigma.Web.Layouts do
  use Sigma.Web, :html

  import Sigma.Web.Flash

  embed_templates "layouts/*"

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
