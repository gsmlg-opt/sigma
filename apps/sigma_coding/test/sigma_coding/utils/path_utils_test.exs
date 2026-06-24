defmodule Sigma.Coding.Utils.PathUtilsTest do
  use ExUnit.Case, async: true
  alias Sigma.Coding.Utils.PathUtils

  @cwd File.cwd!()

  describe "safe_resolve/2" do
    test "resolves relative path within cwd" do
      assert {:ok, resolved} = PathUtils.safe_resolve("mix.exs", @cwd)
      assert resolved == Path.expand("mix.exs", @cwd)
    end

    test "resolves absolute path within cwd" do
      abs_path = Path.expand("mix.exs", @cwd)
      assert {:ok, resolved} = PathUtils.safe_resolve(abs_path, @cwd)
      assert resolved == abs_path
    end

    test "rejects path outside cwd" do
      assert {:error, reason} = PathUtils.safe_resolve("/etc/passwd", @cwd)
      assert reason =~ "outside of the current working directory"
    end

    test "allows skill files outside cwd only when explicitly enabled" do
      tmp = System.tmp_dir!()
      cwd = Path.join(tmp, "pi_test_cwd_#{System.unique_integer([:positive])}")
      skill_dir = Path.join(tmp, "pi_test_skill_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      File.mkdir_p!(skill_dir)
      skill_path = Path.join(skill_dir, "SKILL.md")
      File.write!(skill_path, "skill")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(skill_dir)
      end)

      assert {:error, reason} = PathUtils.safe_resolve(skill_path, cwd)
      assert reason =~ "outside of the current working directory"
      assert {:ok, ^skill_path} = PathUtils.safe_resolve(skill_path, cwd, allow_skill_files?: true)
    end

    test "rejects relative path going out of cwd" do
      assert {:error, reason} = PathUtils.safe_resolve("../../../etc/passwd", @cwd)
      assert reason =~ "outside of the current working directory"
    end

    test "handles ~ expansion" do
      # We assume the home directory is outside the project directory for this test
      home = System.user_home!()

      if not String.starts_with?(@cwd, home) do
        assert {:error, reason} = PathUtils.safe_resolve("~/.ssh/id_rsa", @cwd)
        assert reason =~ "outside of the current working directory"
      end
    end

    test "rejects symlink pointing outside cwd" do
      tmp = System.tmp_dir!()
      cwd = Path.join(tmp, "pi_test_cwd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      link = Path.join(cwd, "evil_link")
      File.ln_s("/etc/passwd", link)

      on_exit(fn ->
        File.rm(link)
        File.rmdir(cwd)
      end)

      assert {:error, reason} = PathUtils.safe_resolve("evil_link", cwd)
      assert reason =~ "outside of the current working directory"
    end

    test "allows symlink pointing within cwd" do
      tmp = System.tmp_dir!()
      cwd = Path.join(tmp, "pi_test_cwd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      target = Path.join(cwd, "real_file.txt")
      File.write!(target, "content")
      link = Path.join(cwd, "safe_link")
      File.ln_s(target, link)

      on_exit(fn ->
        File.rm(link)
        File.rm(target)
        File.rmdir(cwd)
      end)

      assert {:ok, _resolved} = PathUtils.safe_resolve("safe_link", cwd)
    end
  end
end
