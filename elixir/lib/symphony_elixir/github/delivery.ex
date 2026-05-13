defmodule SymphonyElixir.GitHub.Delivery do
  @moduledoc """
  Git branch, validation, push, and pull-request delivery for GitHub-backed issues.
  """

  alias SymphonyElixir.{Config, Linear.Issue, Tracker}
  alias SymphonyElixir.GitHub.Client

  @type delivery_result :: :delivered | :continue | {:error, term()}
  @command_timeout_ms 300_000

  @spec prepare_workspace(Path.t(), Issue.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare_workspace(workspace, %Issue{} = issue) when is_binary(workspace) do
    branch = branch_name(issue)

    with :ok <- ensure_git_repo(workspace),
         :ok <- maybe_fetch_origin(workspace),
         :ok <- checkout_branch(workspace, branch) do
      {:ok, branch}
    end
  end

  @spec deliver(Path.t(), Issue.t(), keyword()) :: delivery_result()
  def deliver(workspace, %Issue{} = issue, opts \\ []) when is_binary(workspace) do
    branch = Keyword.get(opts, :branch) || branch_name(issue)
    run_id = Keyword.get(opts, :run_id)
    metadata = metadata(run_id)

    with :ok <- ensure_git_repo(workspace),
         true <- has_deliverable_changes?(workspace),
         {:ok, validation} <- run_validation(workspace),
         :ok <- ensure_validation_passed(validation),
         :ok <- ensure_dirty_changes_committed(workspace, issue),
         :ok <- push_branch(workspace, branch),
         {:ok, pr} <- ensure_pull_request(issue, branch, validation),
         :ok <- update_delivered_workpad(issue, branch, pr, validation, metadata) do
      :delivered
    else
      false ->
        Tracker.update_workpad(issue, Map.merge(metadata, %{status: "coding", event: "No local commits or changes are ready for delivery."}))
        :continue

      {:validation_failed, validation} ->
        Tracker.update_workpad(
          issue,
          Map.merge(metadata, %{
            status: "validation_failed",
            event: "Validation failed; continuing agent run.",
            state: %{validation: public_validation(validation)}
          })
        )

        :continue

      {:error, reason} ->
        Tracker.update_workpad(issue, Map.merge(metadata, %{status: "delivery_failed", event: "Delivery failed: #{sanitize_reason(reason)}"}))
        {:error, reason}
    end
  end

  @spec branch_name(Issue.t()) :: String.t()
  def branch_name(%Issue{id: id, title: title}) do
    config = Config.settings!()
    prefix = config.git.branch_prefix || "open-symphony/"
    suffix = slug(title || "issue")
    prefix <> to_string(id || "issue") <> "-" <> suffix
  end

  @doc false
  @spec sanitize_reason_for_test(term()) :: String.t()
  def sanitize_reason_for_test(reason), do: sanitize_reason(reason)

  @spec run_validation(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def run_validation(workspace) when is_binary(workspace) do
    Config.settings!().validation.commands
    |> Enum.reduce_while({:ok, []}, fn command, {:ok, acc} ->
      result = run_shell(command, workspace)
      {:cont, {:ok, acc ++ [result]}}
    end)
  end

  defp ensure_git_repo(workspace) do
    if File.dir?(Path.join(workspace, ".git")) or git_success?(workspace, ["rev-parse", "--git-dir"]) do
      :ok
    else
      {:error, :workspace_not_git_repository}
    end
  end

  defp maybe_fetch_origin(workspace) do
    case run_git(workspace, ["remote", "get-url", "origin"]) do
      {:ok, _output} ->
        git_command(workspace, ["fetch", "origin"], :git_fetch_failed)

      _ ->
        :ok
    end
  end

  defp checkout_branch(workspace, branch) do
    case run_git(workspace, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]) do
      {:ok, _output} ->
        git_command(workspace, ["checkout", branch], :git_checkout_failed)

      _ ->
        base_ref = base_ref(workspace)
        git_command(workspace, ["checkout", "-B", branch, base_ref], :git_checkout_failed)
    end
  end

  defp base_ref(workspace) do
    base_branch = Config.settings!().git.base_branch || "main"

    if git_success?(workspace, ["rev-parse", "--verify", "origin/#{base_branch}"]) do
      "origin/#{base_branch}"
    else
      "HEAD"
    end
  end

  defp has_deliverable_changes?(workspace) do
    has_commits_ahead?(workspace) or dirty_worktree?(workspace)
  end

  defp has_commits_ahead?(workspace) do
    base = base_ref(workspace)

    case run_git(workspace, ["rev-list", "--count", "#{base}..HEAD"]) do
      {:ok, count} -> String.trim(count) != "0"
      _ -> false
    end
  end

  defp dirty_worktree?(workspace) do
    case run_git(workspace, ["status", "--porcelain"]) do
      {:ok, output} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp ensure_validation_passed(validation) do
    if Enum.all?(validation, &(Map.get(&1, :exit_code) == 0)) do
      :ok
    else
      {:validation_failed, Enum.map(validation, &stringify_result/1)}
    end
  end

  defp push_branch(workspace, branch) do
    git_command(workspace, ["push", "-u", "origin", branch], :git_push_failed)
  end

  defp ensure_dirty_changes_committed(workspace, issue) do
    if dirty_worktree?(workspace) do
      with :ok <- refuse_sensitive_untracked_files(workspace),
           :ok <- git_command(workspace, ["add", "-A"], :git_add_failed) do
        git_command(workspace, ["commit", "-m", "Implement #{issue.identifier}"], :git_commit_failed)
      end
    else
      :ok
    end
  end

  defp ensure_pull_request(issue, branch, validation) do
    with {:ok, existing} <- find_existing_pr(branch) do
      case existing do
        nil -> create_pr(issue, branch, validation)
        pr -> {:ok, pr}
      end
    end
  end

  defp find_existing_pr(branch) do
    head = "#{Config.settings!().tracker.owner}:#{branch}"

    case Client.list_pull_requests(state: "open", head: head) do
      {:ok, [pr | _]} -> {:ok, pr}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  defp create_pr(issue, branch, validation) do
    config = Config.settings!()

    payload = %{
      "title" => "#{issue.identifier}: #{issue.title}",
      "head" => branch,
      "base" => config.git.base_branch || "main",
      "body" => pr_body(issue, branch, validation),
      "draft" => config.pr.draft
    }

    with {:ok, pr} <- Client.create_pull_request(payload),
         :ok <- maybe_label_pr(pr) do
      {:ok, pr}
    end
  end

  defp maybe_label_pr(%{"number" => number}) do
    Client.add_labels(to_string(number), Config.settings!().pr.labels)
  end

  defp maybe_label_pr(_), do: :ok

  defp update_delivered_workpad(issue, branch, pr, validation, metadata) do
    Tracker.update_workpad(issue, %{
      status: "pr_open",
      run_id: metadata[:run_id],
      pr_url: pr["html_url"],
      event: "Draft PR is ready for review.",
      state: %{
        branch: branch,
        pr_url: pr["html_url"],
        delivered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        validation: public_validation(validation)
      }
    })
  end

  defp pr_body(issue, branch, validation) do
    """
    Implements #{issue.url || issue.identifier}.

    ## Summary

    Open Symphony generated this pull request from #{issue.identifier}: #{issue.title}.

    ## Branch

    `#{branch}`

    ## Validation

    #{format_validation(validation)}
    """
    |> String.trim()
  end

  defp run_shell(command, workspace) do
    {output, exit_code} =
      case run_cmd("bash", ["-lc", command], workspace) do
        {:ok, output} -> {output, 0}
        {:error, output, status} -> {output, status}
      end

    %{
      command: command,
      exit_code: exit_code,
      output: trim_output(output)
    }
  end

  defp git_command(workspace, args, error_tag) do
    case run_git(workspace, args) do
      {:ok, _output} -> :ok
      {:error, output, status} -> {:error, {error_tag, status, output}}
    end
  end

  defp git_success?(workspace, args) do
    case run_git(workspace, args) do
      {:ok, _output} -> true
      _ -> false
    end
  end

  defp run_git(workspace, args), do: run_cmd("git", args, workspace)

  defp run_cmd(command, args, workspace) do
    env = [{"GIT_TERMINAL_PROMPT", "0"}, {"GCM_INTERACTIVE", "never"}]
    timeout = Application.get_env(:symphony_elixir, :github_command_timeout_ms, @command_timeout_ms)

    task =
      Task.async(fn ->
        System.cmd(command, args,
          cd: workspace,
          stderr_to_stdout: true,
          env: env
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, redact(output)}
      {:ok, {output, status}} -> {:error, redact(output), status}
      nil -> {:error, "command timed out after #{timeout}ms", :timeout}
    end
  rescue
    error ->
      {:error, redact(Exception.message(error)), :exception}
  catch
    :exit, reason ->
      {:error, redact(inspect(reason)), :exit}
  end

  defp format_validation([]), do: "No validation commands configured."

  defp format_validation(validation) do
    Enum.map_join(validation, "\n", fn
      %{command: command, exit_code: 0} -> "- ✅ `#{command}`"
      %{command: command, exit_code: code, output: output} -> "- ❌ `#{command}` exited #{code}\n\n```\n#{output}\n```"
    end)
  end

  defp stringify_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {to_string(key), value} end)
  end

  defp public_validation(validation) when is_list(validation) do
    Enum.map(validation, fn result ->
      result
      |> stringify_result()
      |> Map.delete("output")
    end)
  end

  defp metadata(nil), do: %{}
  defp metadata(run_id) when is_binary(run_id), do: %{run_id: run_id}

  defp refuse_sensitive_untracked_files(workspace) do
    case run_git(workspace, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.filter(&sensitive_path?/1)

        if files == [] do
          :ok
        else
          {:error, {:sensitive_untracked_files, files}}
        end

      {:error, _output, _status} ->
        :ok
    end
  end

  defp sensitive_path?(path) do
    basename = path |> Path.basename() |> String.downcase()
    downcased = String.downcase(path)

    basename in [".env", ".env.local", ".envrc", "id_rsa", "id_dsa", "id_ed25519", "credentials", "credentials.json"] or
      String.ends_with?(basename, [".pem", ".key", ".p12", ".pfx"]) or
      String.contains?(downcased, ["secret", "token", "password"])
  end

  defp trim_output(output) when is_binary(output) do
    output
    |> redact()
    |> String.trim()
    |> then(fn trimmed ->
      if String.length(trimmed) > 4_000 do
        String.slice(trimmed, 0, 4_000) <> "\n...<truncated>"
      else
        trimmed
      end
    end)
  end

  defp sanitize_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> redact()
    |> trim_output()
  end

  defp redact(value) when is_binary(value) do
    value
    |> String.replace(~r/(https?:\/\/)([^\/\s:@]+:)?[^\/\s:@]+@/i, "\\1[REDACTED]@")
    |> String.replace(~r/(x-access-token:)[^@\s]+@/i, "\\1[REDACTED]@")
    |> String.replace(~r/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/i, "\\1[REDACTED]")
    |> String.replace(~r/\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]+/, "[REDACTED_GITHUB_TOKEN]")
    |> String.replace(~r/((?:token|password|secret|api[_-]?key)=)[^\s&]+/i, "\\1[REDACTED]")
  end

  defp slug(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> case do
      "" -> "issue"
      value -> value
    end
  end
end
