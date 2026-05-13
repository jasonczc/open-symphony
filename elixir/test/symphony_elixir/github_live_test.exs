defmodule SymphonyElixir.GitHubLiveTest do
  use SymphonyElixir.TestSupport

  if System.get_env("OPEN_SYMPHONY_LIVE_GITHUB") == "1" do
    @tag :live_github
    test "live GitHub feedback delivery harness" do
      repo = System.fetch_env!("OPEN_SYMPHONY_LIVE_REPO")
      token = System.fetch_env!("GITHUB_TOKEN")
      [owner, name] = String.split(repo, "/", parts: 2)
      label = System.get_env("OPEN_SYMPHONY_LIVE_LABEL", "open-symphony")
      workspace = temp_workspace!("github-live")
      unique = System.unique_integer([:positive])

      issue_url =
        gh!(repo, [
          "issue",
          "create",
          "--repo",
          repo,
          "--title",
          "Open Symphony live feedback harness #{unique}",
          "--body",
          "Temporary live harness issue for GitHub feedback surfaces.",
          "--label",
          label
        ])
        |> String.trim()

      [_, number] = Regex.run(~r{/issues/(\d+)}, issue_url)
      issue = %SymphonyElixir.Linear.Issue{id: number, identifier: "GH-#{number}", title: "Open Symphony live feedback harness #{unique}", url: issue_url}

      gh!(repo, ["repo", "clone", repo, workspace, "--", "--quiet"])
      git!(workspace, ["config", "user.email", "open-symphony@example.invalid"])
      git!(workspace, ["config", "user.name", "Open Symphony Live Harness"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: token,
        tracker_project_slug: nil,
        tracker_owner: owner,
        tracker_repo: name,
        tracker_labels: [label],
        validation_commands: ["test -f open-symphony-live-#{unique}.txt"],
        github_feedback: %{pr_sticky_comment: true, trigger_reactions: true, commit_status: true}
      )

      assert {:ok, branch} = SymphonyElixir.GitHub.Delivery.prepare_workspace(workspace, issue)
      File.write!(Path.join(workspace, "open-symphony-live-#{unique}.txt"), "live feedback harness\n")
      assert :delivered = SymphonyElixir.GitHub.Delivery.deliver(workspace, issue, run_id: "live-#{unique}")

      pr_json = gh!(repo, ["pr", "list", "--repo", repo, "--head", branch, "--state", "open", "--json", "number,isDraft,headRefName"])
      [pr] = Jason.decode!(pr_json)
      assert pr["isDraft"] == true
      assert pr["headRefName"] == branch
    end

    @tag :live_github
    test "live GitHub direct reply harness" do
      repo = System.fetch_env!("OPEN_SYMPHONY_LIVE_REPO")
      token = System.fetch_env!("GITHUB_TOKEN")
      [owner, name] = String.split(repo, "/", parts: 2)
      label = System.get_env("OPEN_SYMPHONY_LIVE_LABEL", "open-symphony")
      workspace = temp_workspace!("github-live-reply")
      unique = System.unique_integer([:positive])

      issue_url =
        gh!(repo, [
          "issue",
          "create",
          "--repo",
          repo,
          "--title",
          "Open Symphony live direct reply harness #{unique}",
          "--body",
          "Temporary live harness issue for direct reply mode.",
          "--label",
          label
        ])
        |> String.trim()

      [_, number] = Regex.run(~r{/issues/(\d+)}, issue_url)
      issue = %SymphonyElixir.Linear.Issue{id: number, identifier: "GH-#{number}", title: "Open Symphony live direct reply harness #{unique}", url: issue_url}

      gh!(repo, ["repo", "clone", repo, workspace, "--", "--quiet"])
      git!(workspace, ["config", "user.email", "open-symphony@example.invalid"])
      git!(workspace, ["config", "user.name", "Open Symphony Live Harness"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: token,
        tracker_project_slug: nil,
        tracker_owner: owner,
        tracker_repo: name,
        tracker_labels: [label],
        github_feedback: %{pr_sticky_comment: true, trigger_reactions: true, commit_status: true}
      )

      assert {:ok, _branch} = SymphonyElixir.GitHub.Delivery.prepare_workspace(workspace, issue)
      File.mkdir_p!(Path.join(workspace, ".open-symphony"))
      reply = "Live direct reply #{unique}"
      File.write!(Path.join(workspace, ".open-symphony/reply.md"), reply <> "\n")

      assert :delivered = SymphonyElixir.GitHub.Delivery.deliver(workspace, issue, run_id: "live-reply-#{unique}")

      comments_json = gh!(repo, ["issue", "view", number, "--repo", repo, "--comments", "--json", "comments"])
      comments = Jason.decode!(comments_json)["comments"]
      assert Enum.any?(comments, &String.contains?(&1["body"] || "", reply))

      pr_json = gh!(repo, ["pr", "list", "--repo", repo, "--search", "GH-#{number} in:title", "--state", "open", "--json", "number"])
      assert Jason.decode!(pr_json) == []
    end

    defp gh!(repo, args) do
      case System.cmd("gh", args, stderr_to_stdout: true) do
        {output, 0} -> output
        {output, status} -> flunk("gh #{Enum.join(args, " ")} failed for #{repo} with #{status}: #{output}")
      end
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
  else
    @tag :skip
    test "live GitHub feedback delivery harness requires OPEN_SYMPHONY_LIVE_GITHUB=1" do
      :ok
    end
  end
end
