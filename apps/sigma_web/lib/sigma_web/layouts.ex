defmodule Sigma.Web.Layouts do
  use Sigma.Web, :html

  import Sigma.Web.Flash

  embed_templates "layouts/*"
end
