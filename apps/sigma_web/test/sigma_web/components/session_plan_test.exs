defmodule Sigma.Web.SessionPlanTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Sigma.Web.SessionPlan

  test "absent plan renders no invented pending or completed state" do
    html = render_component(&SessionPlan.plan/1, %{id: "plan", snapshot: nil})
    assert Floki.parse_fragment!(html) |> Floki.find("section") == []
  end

  test "confirmed steps retain order, expose text statuses and count completion" do
    tree = render_plan(snapshot())
    assert [_] = Floki.find(tree, "section#plan[aria-label='Session plan']")

    assert Floki.find(tree, "ol > li") |> Floki.attribute("data-status") == [
             "completed",
             "in_progress",
             "pending"
           ]

    for label <- ["1 of 3 completed", "Completed", "In progress", "Pending", "Approved plan"] do
      assert Floki.text(tree) =~ label
    end

    assert Floki.find(tree, "[aria-current=step]") |> length() == 1

    assert Floki.find(tree, "ol > li [role=status]")
           |> Enum.map(&Floki.text/1)
           |> Enum.map(&String.trim/1) ==
             ["Completed", "In progress", "Pending"]

    assert Floki.find(tree, "button, input, a") == []
    refute Floki.text(tree) =~ "run-secret"
    refute Floki.text(tree) =~ "call-secret"
  end

  test "empty confirmed plan and escaped content remain truthful" do
    assert render_plan(%{snapshot() | "plan" => []}) |> Floki.text() =~ "No steps recorded."

    dangerous = %{
      snapshot()
      | "plan" => [%{"step" => "<script>alert(1)</script>", "status" => "pending"}],
        "explanation" => "<img src=x onerror=alert(1)>"
    }

    tree = render_plan(dangerous)
    assert Floki.find(tree, "script, img") == []
    assert Floki.text(tree) =~ "<script>alert(1)</script>"
    assert Floki.text(tree) =~ dangerous["explanation"]
  end

  defp render_plan(snapshot) do
    render_component(&SessionPlan.plan/1, %{id: "plan", snapshot: snapshot})
    |> Floki.parse_fragment!()
  end

  defp snapshot do
    %{
      "version" => 1,
      "run_id" => "run-secret",
      "incarnation" => 1,
      "tool_call_id" => "call-secret",
      "revision" => 2,
      "explanation" => "Approved plan",
      "plan" => [
        %{"step" => "Read", "status" => "completed"},
        %{"step" => "Implement", "status" => "in_progress"},
        %{"step" => "Verify", "status" => "pending"}
      ]
    }
  end
end
