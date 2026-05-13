defmodule SymphonyElixir.GitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Client, Delivery, Feedback}

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

  test "github feedback config parses triggers and surfaces" do
    write_github_workflow!(
      github_feedback: %{
        pr_sticky_comment: true,
        trigger_reactions: true,
        pr_comment_triggers: true,
        commit_status: true,
        triggers: %{primary: "@open-symphony", aliases: ["@os"]}
      }
    )

    feedback = Config.settings!().github.feedback
    assert feedback.pr_sticky_comment == true
    assert feedback.trigger_reactions == true
    assert feedback.pr_comment_triggers == true
    assert feedback.commit_status == true
    assert feedback.triggers.primary == "@open-symphony"
    assert feedback.triggers.aliases == ["@os"]
  end

  test "feedback trigger normalization accepts canonical trigger and os alias" do
    write_github_workflow!()
    feedback = Config.settings!().github.feedback

    assert {:ok, "@open-symphony", "address review"} =
             Feedback.normalize_trigger_command("@open-symphony address review", feedback)

    assert {:ok, "@os", "fix tests"} = Feedback.normalize_trigger_command("  @os fix tests", feedback)
    assert :ignore = Feedback.normalize_trigger_command("@someone-else fix tests", feedback)
  end

  test "client updates existing sticky PR delivery comment instead of creating duplicates" do
    write_github_workflow!()
    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/44/comments", nil ->
        {:ok, [delivery_comment(4401, "old body")]}

      :patch, "/repos/octo/repo/issues/comments/4401", %{"body" => body} ->
        send(parent, {:sticky_update, body})
        {:ok, %{}}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert :ok = Client.upsert_pr_delivery_comment("44", "## Open Symphony Delivery\n\nnew body")
    assert_receive {:sticky_update, body}
    assert body =~ "new body"
  end

  test "candidate fetch includes issue when linked PR has unhandled os trigger comment" do
    write_github_workflow!(github_feedback: %{pr_comment_triggers: true, trigger_reactions: true})

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues?" <> _query, nil ->
        {:ok, [github_issue(8, "Already delivered", "2026-05-10T00:00:00Z")]}

      :get, "/repos/octo/repo/issues/8/comments", nil ->
        {:ok,
         [
           workpad_comment(801, %{
             "status" => "pr_open",
             "pr_url" => "https://github.com/octo/repo/pull/88",
             "delivered_at" => "2026-05-11T00:00:00Z"
           })
         ]}

      :get, "/repos/octo/repo/pulls?" <> _query, nil ->
        {:ok, [%{"number" => 88, "head" => %{"ref" => "open-symphony/8-already-delivered"}}]}

      :get, "/repos/octo/repo/issues/88/comments", nil ->
        {:ok,
         [
           delivery_comment(8801, "To request changes, comment with `@os ...`"),
           %{
             "id" => 8802,
             "body" => "@os address this feedback",
             "html_url" => "https://github.com/octo/repo/pull/88#issuecomment-8802",
             "user" => %{"login" => "alice"}
           }
         ]}

      :get, "/repos/octo/repo/issues/8", nil ->
        {:ok, github_issue(8, "Already delivered", "2026-05-10T00:00:00Z")}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.id == "8"
  end

  test "claim marks handled PR trigger comment and acknowledges it" do
    write_github_workflow!(github_feedback: %{pr_comment_triggers: true, trigger_reactions: true})
    parent = self()
    issue = %Issue{id: "9", identifier: "GH-9", title: "PR feedback"}

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/9/comments", nil ->
        {:ok, [workpad_comment(901, %{"status" => "pr_open", "pr_url" => "https://github.com/octo/repo/pull/99"})]}

      :get, "/repos/octo/repo/issues/99/comments", nil ->
        {:ok,
         [
           %{
             "id" => 9901,
             "body" => "@os please continue",
             "html_url" => "https://github.com/octo/repo/pull/99#issuecomment-9901",
             "user" => %{"login" => "alice"}
           }
         ]}

      :post, "/repos/octo/repo/issues/comments/9901/reactions", %{"content" => "eyes"} ->
        send(parent, :reaction_created)
        {:ok, %{}}

      :patch, "/repos/octo/repo/issues/comments/901", %{"body" => body} ->
        send(parent, {:claim_workpad, body})
        {:ok, %{}}

      :get, "/repos/octo/repo/issues/comments/901", nil ->
        {:ok, workpad_comment(901, %{"status" => "claimed", "claim" => %{"run_id" => "run-9"}, "last_pr_trigger_comment_id" => "9901"})}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert :ok = Client.claim_issue(issue, %{run_id: "run-9"})
    assert_receive :reaction_created
    assert_receive {:claim_workpad, body}
    assert body =~ ~s("last_pr_trigger_comment_id":"9901")
    assert body =~ ~s("last_trigger_source":"pr_comment")
    assert body =~ ~s("last_trigger_command":"please continue")
  end

  test "client builds conversation context from issue comments, workpad, and PR comments" do
    write_github_workflow!()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/5/comments", nil ->
        {:ok,
         [
           %{
             "id" => 501,
             "body" => "Please fix this",
             "html_url" => "https://github.com/octo/repo/issues/5#issuecomment-501",
             "user" => %{"login" => "alice"}
           },
           workpad_comment(502, %{
             "status" => "pr_open",
             "branch" => "open-symphony/5-fix-this",
             "pr_url" => "https://github.com/octo/repo/pull/55",
             "delivered_at" => "2026-05-13T04:00:00Z"
           })
         ]}

      :get, "/repos/octo/repo/issues/55/comments", nil ->
        {:ok,
         [
           delivery_comment(5501, "Delivered previous attempt"),
           %{
             "id" => 5502,
             "body" => "@os address review comments",
             "html_url" => "https://github.com/octo/repo/pull/55#issuecomment-5502",
             "user" => %{"login" => "bob"}
           }
         ]}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    issue = %Issue{id: "5", identifier: "GH-5", title: "Fix this", url: "https://github.com/octo/repo/issues/5"}

    assert {:ok, context} = Client.conversation_context(issue)
    assert context =~ "## Conversation Context"
    assert context =~ "Please fix this"
    assert context =~ "- Status: pr_open"
    assert context =~ "- PR: https://github.com/octo/repo/pull/55"
    assert context =~ "Delivered previous attempt"
    assert context =~ "@os address review comments"
    refute context =~ "<!-- open-symphony:"
  end

  test "client can acknowledge a trigger comment with a reaction" do
    write_github_workflow!(github_feedback: %{trigger_reactions: true})
    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :post, "/repos/octo/repo/issues/comments/987/reactions", %{"content" => "eyes"} ->
        send(parent, :reaction_created)
        {:ok, %{}}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert :ok = Client.acknowledge_trigger_comment("987")
    assert_receive :reaction_created
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

  test "delivery posts direct reply without opening PR when reply artifact is the only change" do
    write_github_workflow!()
    workspace = temp_workspace!("github-reply")
    issue = %Issue{id: "14", identifier: "GH-14", title: "Answer only"}

    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.email", "bot@example.com"])
    git!(workspace, ["config", "user.name", "Open Symphony Bot"])
    File.write!(Path.join(workspace, "README.md"), "# repo\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial"])
    File.mkdir_p!(Path.join(workspace, ".open-symphony"))
    File.write!(Path.join(workspace, ".open-symphony/reply.md"), "Here is the answer.\n")

    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/14/comments", nil ->
        {:ok, [workpad_comment(1401, %{"status" => "claimed"})]}

      :post, "/repos/octo/repo/issues/14/comments", %{"body" => "Here is the answer."} ->
        send(parent, :reply_posted)
        {:ok, %{"id" => 1402, "body" => "Here is the answer.", "user" => %{"login" => "open-symphony-bot"}}}

      :patch, "/repos/octo/repo/issues/comments/1401", %{"body" => body} ->
        send(parent, {:reply_workpad, body})
        {:ok, %{}}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert :delivered = Delivery.deliver(workspace, issue, run_id: "run-14")
    assert_receive :reply_posted
    assert_receive {:reply_workpad, body}
    assert body =~ ~s("status":"reply_posted")
    assert body =~ ~s("replied_at")
    refute File.exists?(Path.join(workspace, ".open-symphony/reply.md"))
  end

  test "reply comments route back to linked PR when trigger source is a PR comment" do
    write_github_workflow!()
    issue = %Issue{id: "15", identifier: "GH-15", title: "PR answer"}
    parent = self()

    Application.put_env(:symphony_elixir, :github_request_fun, fn
      :get, "/repos/octo/repo/issues/15/comments", nil ->
        {:ok, [workpad_comment(1501, %{"status" => "claimed", "last_trigger_source" => "pr_comment", "pr_url" => "https://github.com/octo/repo/pull/155"})]}

      :post, "/repos/octo/repo/issues/155/comments", %{"body" => "Reply on PR"} ->
        send(parent, :pr_reply_posted)
        {:ok, %{"id" => 15501, "body" => "Reply on PR", "user" => %{"login" => "open-symphony-bot"}}}

      method, path, body ->
        flunk("unexpected GitHub request #{inspect({method, path, body})}")
    end)

    assert :ok = Client.create_reply_comment(issue, "Reply on PR")
    assert_receive :pr_reply_posted
  end

  test "delivery creates commit, pushes branch, creates PR, labels it, and updates workpad" do
    write_github_workflow!(
      validation_commands: ["test -f feature.txt"],
      pr_labels: ["symphony"],
      github_feedback: %{pr_sticky_comment: true, commit_status: true}
    )

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

      :post,
      "/repos/octo/repo/statuses/" <> sha,
      %{"context" => "open-symphony/validation", "description" => description, "state" => "success", "target_url" => "https://github.com/octo/repo/pull/44"} ->
        send(parent, {:status, sha, description})
        {:ok, %{}}

      :get, "/repos/octo/repo/issues/44/comments", nil ->
        send(parent, :list_pr_comments)
        {:ok, []}

      :post, "/repos/octo/repo/issues/44/comments", %{"body" => body} ->
        send(parent, {:sticky_create, body})
        {:ok, %{"id" => 4401, "body" => body, "html_url" => "https://github.com/octo/repo/pull/44#issuecomment-4401", "user" => %{"login" => "open-symphony-bot"}}}

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
    assert_receive {:create_pr, %{"head" => "open-symphony/12-ship-feature", "base" => "main", "draft" => true, "body" => pr_body}}
    assert pr_body =~ "## What changed"
    assert_receive :label_pr
    assert_receive {:status, sha, "Open Symphony validation passed"}
    assert String.length(sha) == 40
    assert_receive :list_pr_comments
    assert_receive {:sticky_create, sticky_body}
    assert sticky_body =~ "## Open Symphony Delivery"
    assert sticky_body =~ "@os"
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

  defp delivery_comment(id, body, author \\ "open-symphony-bot") do
    %{
      "id" => id,
      "body" => "## Open Symphony Delivery\n\n#{body}",
      "html_url" => "https://github.com/octo/repo/pull/44#issuecomment-#{id}",
      "user" => %{"login" => author}
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
