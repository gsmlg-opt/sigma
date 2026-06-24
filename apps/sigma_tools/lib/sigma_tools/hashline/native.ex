defmodule Sigma.Tools.Hashline.Native do
  @moduledoc false

  use Rustler,
    otp_app: :sigma_tools,
    crate: "sigma_tools_hashline",
    path: "native/sigma_tools_hashline"

  def compute_file_hash(_text), do: :erlang.nif_error(:nif_not_loaded)
  def parse_sections_json(_input, _cwd), do: :erlang.nif_error(:nif_not_loaded)
  def apply_edits_json(_text, _diff), do: :erlang.nif_error(:nif_not_loaded)
end
