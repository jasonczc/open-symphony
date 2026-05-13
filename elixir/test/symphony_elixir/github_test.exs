defmodule SymphonyElixir.GitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Client, Delivery}

  test "github config resolves token and defaults endpoint" do
    previous_github_token = System.get_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_github_token) end)
    System.put_env("GITHUB_TOKEN", "github-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: nil,
      tracker_api_token: "$GITHUB_TOKEN",
      tracker_project_slug: nil,
      tracker_owner: "octo",
      tracker_repo: "repo",
      tracker_labels: ["open-symphony"],
      tracker_exclude_labels: ["blocked"]
    )

    config = Config.settings!()

    assert config.tracker.kind == "github"
    assert config.tracker.endpoint == "https://api.github.com"
    assert config.tracker.api_key == "github-token"
    assert config.tracker.owner == "octo"
    assert config.tracker.repo == "repo"
    assert config.tracker.active_states == ["open"]
    assert config.tracker.terminal_states == ["closed"]
    assert :ok = Config.validate!()
  end

  test "github issue normalization maps REST issue payload to normalized issue" do
    issue =
      Client.normalize_issue_for_test(%{
        "number" => 123,
        "title" => "Fix login",
        "body" => "Broken flow",
        "state" => "open",
        "html_url" => "https://github.com/acme/app/issues/123",
        "labels" => [%{"name" => "Open-Symphony"}, %{"name" => "Bug"}],
        "assignee" => %{"login" => "jason"},
        "created_at" => "2026-05-01T00:00:00Z",
        "updated_at" => "2026-05-02T00:00:00Z"
      })

    assert issue.id == "123"
    assert issue.identifier == "GH-123"
    assert issue.title == "Fix login"
    assert issue.description == "Broken flow"
    assert issue.state == "open"
    assert issue.url == "https://github.com/acme/app/issues/123"
    assert issue.labels == ["open-symphony", "bug"]
    assert issue.assignee_id == "jason"
    assert %DateTime{} = issue.created_at
  end

  test "workpad state decoder reads embedded open symphony state" do
    body = """
    ## Open Symphony Workpad

    <!-- open-symphony:{"status":"claimed","claim":{"run_id":"run-1"}} -->
    """

    assert %{"status" => "claimed", "claim" => %{"run_id" => "run-1"}} =
             Client.decode_workpad_state_for_test(body)
  end

  test "delivery branch names use configured prefix, issue id, and slug" do
    write_github_workflow!(git_branch_prefix: "open-symphony/")

    issue = %Issue{id: "77", identifier: "GH-77", title: "Fix Login Flow!"}

    assert Delivery.branch_name(issue) == "open-symphony/77-fix-login-flow"
  end

  test "candidate fetch pauses delivered issues until the issue changes again" do
    write_github_workflow!()
    delivered_at = "2026-05-10T00:00:00Z"

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues?" <> _query, nil ->
        {:ok,
         [
           github_issue(1, "Already delivered", "2026-05-09T00:00:00Z"),
           github_issue(2, "Ready to claim", "2026-05-11T00:00:00Z")
         ]}

      :get, "/repos/octo/repo/issues/1/comments", nil ->
        {:ok, [workpad_comment(101, %{"status" => "pr_open", "pr_url" => "https://github.com/octo/repo/pull/9", "delivered_at" => delivered_at})]}

      :get, "/repos/octo/repo/issues/2/comments", nil ->
        {:ok, [workpad_comment(102, %{"status" => "pr_open", "pr_url" => "https://github.com/octo/repo/pull/10", "delivered_at" => delivered_at})]}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "2"
  end

  test "candidate fetch ignores spoofed workpad comments from other users" do
    write_github_workflow!()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues?" <> _query, nil ->
        {:ok, [github_issue(4, "Spoof-resistant", "2026-05-09T00:00:00Z")]}

      :get, "/repos/octo/repo/issues/4/comments", nil ->
        {:ok, [workpad_comment(401, %{"status" => "pr_open", "pr_url" => "https://github.com/octo/repo/pull/9"}, "attacker")]}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "4"
  end

  test "claim verifies the workpad still contains its run id after writing" do
    write_github_workflow!()
    issue = %Issue{id: "3", identifier: "GH-3", title: "Race-safe claim"}

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/3/comments", nil ->
        {:ok, [workpad_comment(303, %{"status" => "created"})]}

      :patch, "/repos/octo/repo/issues/comments/303", %{"body" => body} when is_binary(body) ->
        assert body =~ ~s("run_id":"mine")
        {:ok, %{}}

      :get, "/repos/octo/repo/issues/comments/303", nil ->
        {:ok, workpad_comment(303, %{"status" => "claimed", "claim" => %{"run_id" => "other"}})}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert {:skip, {:claim_lost, %{"run_id" => "other"}}} = Client.claim_issue(issue, %{run_id: "mine"})
  end

  test "delivery failure messages redact tokens before writing workpad" do
    reason = {:git_push_failed, 128, "fatal https://x-access-token:ghp_secret123@github.com/octo/repo token=abc123"}

    sanitized = Delivery.sanitize_reason_for_test(reason)

    refute sanitized =~ "ghp_secret123"
    refute sanitized =~ "token=abc123"
    assert sanitized =~ "[REDACTED"
  end

  test "delivery creates commit, pushes branch, creates PR, labels it, and updates workpad" do
    write_github_workflow!(validation_commands: ["test -f feature.txt"], pr_labels: ["symphony"])
    workspace = temp_workspace!("github-delivery")
    remote = temp_workspace!("github-remote")
    issue = %Issue{id: "12", identifier: "GH-12", title: "Ship Feature", url: "https://github.com/octo/repo/issues/12"}

    git!(remote, ["init", "--bare"])
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "bot@example.com"])
    git!(workspace, ["config", "user.name", "Open Symphony Bot"])
    File.write!(Path.join(workspace, "README.md"), "# repo\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial"])
    git!(workspace, ["remote", "add", "origin", remote])
    git!(workspace, ["push", "-u", "origin", "main"])

    assert {:ok, "open-symphony/12-ship-feature"} = Delivery.prepare_workspace(workspace, issue)
    File.write!(Path.join(workspace, "feature.txt"), "done\n")

    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/pulls?" <> query, nil ->
        send(parent, {:list_prs, URI.decode_query(query)})
        {:ok, []}

      :post, "/repos/octo/repo/pulls", payload ->
        send(parent, {:create_pr, payload})
        {:ok, %{"number" => 44, "html_url" => "https://github.com/octo/repo/pull/44"}}

      :post, "/repos/octo/repo/issues/44/labels", %{"labels" => ["symphony"]} ->
        send(parent, :label_pr)
        {:ok, %{}}

      :get, "/repos/octo/repo/issues/12/comments", nil ->
        {:ok, [workpad_comment(1201, %{"status" => "claimed", "claim" => %{"run_id" => "run-12", "expires_at" => "2026-01-01T00:00:00Z"}})]}

      :patch, "/repos/octo/repo/issues/comments/1201", %{"body" => body} ->
        send(parent, {:workpad, body})
        {:ok, %{}}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert :delivered = Delivery.deliver(workspace, issue, run_id: "run-12")
    assert_receive {:list_prs, %{"head" => "octo:open-symphony/12-ship-feature", "state" => "open"}}
    assert_receive {:create_pr, %{"head" => "open-symphony/12-ship-feature", "base" => "main", "draft" => true}}
    assert_receive :label_pr
    assert_receive {:workpad, body}
    assert body =~ ~s("status":"pr_open")
    assert body =~ ~s("delivered_at")
    assert body =~ ~s("expires_at")

    assert {pushed, 0} = System.cmd("git", ["--git-dir", remote, "rev-parse", "--verify", "open-symphony/12-ship-feature"], stderr_to_stdout: true)
    assert String.trim(pushed) != ""
  end

  test "delivery refuses suspicious untracked secret files before auto-commit" do
    write_github_workflow!()
    workspace = temp_workspace!("github-secret")
    issue = %Issue{id: "13", identifier: "GH-13", title: "Avoid Secrets"}

    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "bot@example.com"])
    git!(workspace, ["config", "user.name", "Open Symphony Bot"])
    File.write!(Path.join(workspace, "README.md"), "# repo\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial"])
    File.write!(Path.join(workspace, ".env"), "TOKEN=secret\n")

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/13/comments", nil -> {:ok, [workpad_comment(1301, %{"status" => "claimed"})]}
      :patch, "/repos/octo/repo/issues/comments/1301", %{"body" => _body} -> {:ok, %{}}
      method, path, body -> flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert {:error, {:sensitive_untracked_files, [".env"]}} = Delivery.deliver(workspace, issue)
  end

  defp write_github_workflow!(overrides \\ []) do
    Application.put_env(:symphony_elixir, :github_viewer_login, "open-symphony-bot")

    write_workflow_file!(
      Workflow.workflow_file_path(),
      [
        tracker_kind: "github",
        tracker_api_token: "github-token",
        tracker_project_slug: nil,
        tracker_owner: "octo",
        tracker_repo: "repo",
        tracker_labels: ["open-symphony"]
      ] ++ overrides
    )
  end

  defp github_issue(number, title, updated_at) do
    %{
      "number" => number,
      "title" => title,
      "body" => "",
      "state" => "open",
      "labels" => [%{"name" => "open-symphony"}],
      "html_url" => "https://github.com/octo/repo/issues/#{number}",
      "updated_at" => updated_at
    }
  end

  defp workpad_comment(id, state, author \\ "open-symphony-bot") do
    %{
      "id" => id,
      "body" => workpad_body(state),
      "html_url" => "https://github.com/octo/repo/issues/1#issuecomment-#{id}",
      "user" => %{"login" => author}
    }
  end

  defp workpad_body(state) do
    """
    ## Open Symphony Workpad

    <!-- open-symphony:#{Jason.encode!(state)} -->
    """
  end

  defp temp_workspace!(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
