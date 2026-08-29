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
