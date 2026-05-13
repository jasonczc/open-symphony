defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST client for issue-backed Symphony runs.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.GitHub.Feedback

  @page_size 100
  @workpad_marker "## Open Symphony Workpad"
  @delivery_marker "## Open Symphony Delivery"
  @state_marker_prefix "<!-- open-symphony:"
  @state_marker_suffix "-->"
  @completed_statuses MapSet.new(["done", "delivered", "blocked_review"])
  @claim_ttl_seconds 900

  @type comment :: %{id: String.t(), body: String.t(), url: String.t() | nil, author_login: String.t() | nil}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_config(tracker),
         {:ok, assignee} <- resolve_assignee(tracker),
         {:ok, issues} <- fetch_issue_pages(tracker, assignee, 1, []),
         {:ok, pr_triggered_issues} <- fetch_pr_triggered_issues(tracker) do
      {:ok, unique_issues(issues ++ pr_triggered_issues)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    normalized = states |> Enum.map(&normalize_state/1) |> MapSet.new()

    cond do
      MapSet.member?(normalized, "open") -> fetch_candidate_issues()
      MapSet.member?(normalized, "closed") -> fetch_closed_issues()
      true -> {:ok, []}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with :ok <- validate_config(tracker) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case request(:get, issue_path(tracker, issue_id)) do
          {:ok, raw} -> {:cont, {:ok, [normalize_issue(raw) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(Enum.reject(issues, &is_nil/1))}
        error -> error
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    case request(:post, comments_path(tracker, issue_id), %{"body" => body}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_reply_comment(Issue.t(), String.t()) :: :ok | {:error, term()}
  def create_reply_comment(%Issue{} = issue, body) when is_binary(body) do
    with {:ok, state} <- workpad_state(issue.id) do
      target_id = reply_target_id(issue, state)

      case create_issue_comment(target_id, body) do
        {:ok, _comment} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec conversation_context(Issue.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def conversation_context(%Issue{} = issue, opts \\ []) do
    max_comments = Keyword.get(opts, :max_comments, 10)

    with {:ok, issue_comments} <- list_comments(issue.id) do
      workpad_state =
        issue_comments
        |> Enum.map(&decode_workpad_state(&1.body))
        |> Enum.find(%{}, &(&1 != %{}))

      pr_number = pr_number_from_url(Map.get(workpad_state, "pr_url"))

      with {:ok, pr_comments} <- context_pr_comments(pr_number) do
        {:ok, render_conversation_context(issue, workpad_state, issue_comments, pr_comments, max_comments)}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker
    state = if normalize_state(state_name) == "closed", do: "closed", else: "open"

    case request(:patch, issue_path(tracker, issue_id), %{"state" => state}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec claim_issue(Issue.t(), map()) :: :ok | {:skip, term()} | {:error, term()}
  def claim_issue(%Issue{} = issue, metadata) when is_map(metadata) do
    now = DateTime.utc_now()
    metadata = Map.put_new(metadata, :claimed_at, DateTime.to_iso8601(now))
    run_id = Map.get(metadata, :run_id)

    with {:ok, comments} <- list_comments(issue.id),
         {:ok, comment} <- find_or_create_workpad(issue, comments, metadata) do
      existing = decode_workpad_state(comment.body)
      existing_claim = get_in(existing, ["claim"])
      has_pending_pr_trigger? = pending_pr_trigger?(existing)

      cond do
        paused_after_delivery?(existing, issue) and not has_pending_pr_trigger? ->
          {:skip, {:waiting_for_review_feedback, Map.get(existing, "pr_url")}}

        paused_after_reply?(existing, issue) ->
          {:skip, {:waiting_for_reply_feedback, Map.get(existing, "replied_at")}}

        completed_workpad?(existing) ->
          {:skip, {:completed, Map.get(existing, "status")}}

        active_foreign_claim?(existing_claim, run_id, now) ->
          {:skip, {:claimed, existing_claim}}

        true ->
          state =
            existing
            |> maybe_mark_pending_pr_trigger()
            |> Map.put("claim", stringify_metadata(metadata))
            |> Map.put("status", "claimed")

          with :ok <- update_workpad_comment(issue, comment, state, metadata) do
            confirm_claim(issue.id, comment.id, run_id)
          end
      end
    end
  end

  @spec update_workpad(Issue.t(), map()) :: :ok | {:error, term()}
  def update_workpad(%Issue{} = issue, metadata) when is_map(metadata) do
    with {:ok, comments} <- list_comments(issue.id),
         {:ok, comment} <- find_or_create_workpad(issue, comments, metadata) do
      state =
        comment.body
        |> decode_workpad_state()
        |> Map.merge(stringify_metadata(Map.get(metadata, :state, %{})))
        |> maybe_put_status(metadata)
        |> maybe_renew_claim(metadata)

      update_workpad_comment(issue, comment, state, metadata)
    end
  end

  @spec create_pull_request(map()) :: {:ok, map()} | {:error, term()}
  def create_pull_request(params) when is_map(params) do
    tracker = Config.settings!().tracker
    request(:post, "/repos/#{tracker.owner}/#{tracker.repo}/pulls", params)
  end

  @spec list_pull_requests(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_pull_requests(opts) when is_list(opts) do
    tracker = Config.settings!().tracker

    query =
      opts
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> URI.encode_query()

    case request(:get, "/repos/#{tracker.owner}/#{tracker.repo}/pulls?#{query}") do
      {:ok, pulls} when is_list(pulls) -> {:ok, pulls}
      {:ok, _} -> {:error, :github_unknown_payload}
      error -> error
    end
  end

  @spec upsert_pr_delivery_comment(String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def upsert_pr_delivery_comment(pr_number, body) when is_binary(body) do
    with {:ok, comments} <- list_comments(to_string(pr_number)),
         {:ok, bot_login} <- bot_login() do
      case Enum.find(comments, &owned_delivery_comment?(&1, bot_login)) do
        nil -> create_issue_comment(to_string(pr_number), body) |> normalize_comment_write_result()
        comment -> update_issue_comment(comment.id, body)
      end
    end
  end

  @spec create_commit_status(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def create_commit_status(sha, state, attrs \\ %{}) when is_binary(sha) and is_binary(state) and is_map(attrs) do
    tracker = Config.settings!().tracker

    body =
      attrs
      |> stringify_metadata()
      |> Map.merge(%{"state" => state})

    case request(:post, "/repos/#{tracker.owner}/#{tracker.repo}/statuses/#{sha}", body) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec acknowledge_trigger_comment(String.t() | integer()) :: :ok | {:error, term()}
  def acknowledge_trigger_comment(comment_id) do
    if Config.settings!().github.feedback.trigger_reactions do
      create_comment_reaction(comment_id, "eyes")
    else
      :ok
    end
  end

  @spec create_comment_reaction(String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def create_comment_reaction(comment_id, content) when is_binary(content) do
    tracker = Config.settings!().tracker

    case request(:post, "/repos/#{tracker.owner}/#{tracker.repo}/issues/comments/#{comment_id}/reactions", %{"content" => content}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec add_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    labels = Enum.reject(labels, &(String.trim(to_string(&1)) == ""))

    if labels == [] do
      :ok
    else
      tracker = Config.settings!().tracker

      case request(:post, "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_id}/labels", %{"labels" => labels}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(raw), do: normalize_issue(raw)

  @doc false
  @spec decode_workpad_state_for_test(String.t()) :: map()
  def decode_workpad_state_for_test(body), do: decode_workpad_state(body)

  defp fetch_pr_triggered_issues(tracker) do
    if Config.settings!().github.feedback.pr_comment_triggers do
      do_fetch_pr_triggered_issues(tracker)
    else
      {:ok, []}
    end
  end

  defp do_fetch_pr_triggered_issues(tracker) do
    case list_pull_requests(state: "open", per_page: @page_size) do
      {:ok, pulls} ->
        pulls
        |> Enum.reduce_while({:ok, []}, fn pr, {:ok, acc} ->
          case issue_from_pr_trigger(tracker, pr) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, issues} -> {:ok, Enum.reverse(issues)}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_from_pr_trigger(tracker, pr) do
    with {:ok, issue_id} <- issue_id_from_pr_branch(pr),
         {:ok, state} <- workpad_state(issue_id),
         {:ok, _trigger_comment} <- latest_pending_pr_trigger(state) do
      case request(:get, issue_path(tracker, issue_id)) do
        {:ok, raw_issue} ->
          issue = normalize_issue(raw_issue)

          if candidate_issue_payload?(issue, tracker) do
            {:ok, issue}
          else
            {:ok, nil}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      :none -> {:ok, nil}
      {:error, :missing_pr_issue_id} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_id_from_pr_branch(pr) do
    prefix = Config.settings!().git.branch_prefix || "open-symphony/"
    branch = get_in(pr, ["head", "ref"]) || pr["headRefName"] || pr["head_ref"]

    with branch when is_binary(branch) <- branch,
         [_, issue_id] <- Regex.run(~r/^#{Regex.escape(prefix)}(\d+)(?:-|$)/, branch) do
      {:ok, issue_id}
    else
      _ -> {:error, :missing_pr_issue_id}
    end
  end

  defp candidate_issue_payload?(%Issue{state: "open"} = issue, tracker) do
    required_labels = tracker.labels |> Enum.map(&String.downcase/1) |> MapSet.new()
    issue_labels = MapSet.new(issue.labels || [])

    labels_match? = MapSet.size(required_labels) == 0 or MapSet.subset?(required_labels, issue_labels)

    labels_match? and not excluded_by_label?(issue, tracker.exclude_labels)
  end

  defp candidate_issue_payload?(_issue, _tracker), do: false

  defp unique_issues(issues) do
    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({MapSet.new(), []}, fn issue, {seen, acc} ->
      if MapSet.member?(seen, issue.id) do
        {seen, acc}
      else
        {MapSet.put(seen, issue.id), [issue | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp fetch_closed_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_config(tracker) do
      fetch_issue_pages(%{tracker | active_states: ["closed"]}, nil, 1, [], state: "closed")
    end
  end

  defp fetch_issue_pages(tracker, assignee, page, acc, opts \\ []) do
    state = Keyword.get(opts, :state, "open")

    query =
      %{
        "state" => state,
        "per_page" => @page_size,
        "page" => page
      }
      |> maybe_put_query("labels", labels_query(tracker.labels))
      |> maybe_put_query("assignee", assignee)
      |> URI.encode_query()

    case request(:get, "/repos/#{tracker.owner}/#{tracker.repo}/issues?#{query}") do
      {:ok, page_items} when is_list(page_items) ->
        issues =
          page_items
          |> Enum.reject(&Map.has_key?(&1, "pull_request"))
          |> Enum.map(&normalize_issue/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&excluded_by_label?(&1, tracker.exclude_labels))

        with {:ok, workable_issues} <- reject_completed_workpad_issues(issues, state) do
          updated_acc = acc ++ workable_issues

          if length(page_items) == @page_size do
            fetch_issue_pages(tracker, assignee, page + 1, updated_acc, opts)
          else
            {:ok, updated_acc}
          end
        end

      {:ok, _payload} ->
        {:error, :github_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_assignee(%{assignee: nil}), do: {:ok, nil}
  defp resolve_assignee(%{assignee: ""}), do: {:ok, nil}
  defp resolve_assignee(%{assignee: "@me"}), do: resolve_viewer_login()
  defp resolve_assignee(%{assignee: assignee}) when is_binary(assignee), do: {:ok, assignee}

  defp resolve_viewer_login do
    case request(:get, "/user") do
      {:ok, %{"login" => login}} when is_binary(login) -> {:ok, login}
      {:ok, _} -> {:error, :github_missing_viewer_login}
      error -> error
    end
  end

  defp labels_query([]), do: nil
  defp labels_query(labels), do: Enum.join(labels, ",")

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp excluded_by_label?(%Issue{labels: labels}, excluded) do
    excluded = excluded |> Enum.map(&String.downcase/1) |> MapSet.new()
    Enum.any?(labels, &MapSet.member?(excluded, &1))
  end

  defp normalize_issue(%{"number" => number, "title" => title} = raw) do
    number_string = to_string(number)

    %Issue{
      id: number_string,
      identifier: "GH-#{number_string}",
      title: title,
      description: raw["body"] || "",
      priority: nil,
      state: String.downcase(to_string(raw["state"] || "open")),
      branch_name: nil,
      url: raw["html_url"] || raw["url"],
      assignee_id: assignee_login(raw["assignee"]),
      labels: extract_labels(raw),
      blocked_by: [],
      assigned_to_worker: true,
      created_at: parse_datetime(raw["created_at"]),
      updated_at: parse_datetime(raw["updated_at"])
    }
  end

  defp normalize_issue(_), do: nil

  defp assignee_login(%{"login" => login}) when is_binary(login), do: login
  defp assignee_login(_), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.downcase(name)
      name when is_binary(name) -> String.downcase(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp validate_config(%{api_key: token, owner: owner, repo: repo})
       when is_binary(token) and is_binary(owner) and is_binary(repo),
       do: :ok

  defp validate_config(%{api_key: token}) when not is_binary(token), do: {:error, :missing_github_api_token}
  defp validate_config(%{owner: owner}) when not is_binary(owner), do: {:error, :missing_github_owner}
  defp validate_config(%{repo: repo}) when not is_binary(repo), do: {:error, :missing_github_repo}
  defp validate_config(_), do: {:error, :invalid_github_config}

  defp list_comments(issue_id) do
    case request(:get, comments_path(Config.settings!().tracker, issue_id)) do
      {:ok, comments} when is_list(comments) ->
        {:ok,
         Enum.map(comments, fn comment ->
           %{
             id: to_string(comment["id"]),
             body: comment["body"] || "",
             url: comment["html_url"],
             author_login: get_in(comment, ["user", "login"])
           }
         end)}

      {:ok, _} ->
        {:error, :github_unknown_payload}

      error ->
        error
    end
  end

  defp find_or_create_workpad(issue, comments, metadata) do
    with {:ok, bot_login} <- bot_login() do
      case Enum.find(comments, &owned_workpad?(&1, bot_login)) do
        nil -> create_workpad(issue, metadata)
        comment -> {:ok, comment}
      end
    end
  end

  defp create_workpad(%Issue{id: issue_id} = issue, metadata) do
    state = %{"status" => "created", "issue" => issue.identifier}
    body = render_workpad(issue, state, metadata)

    case create_issue_comment(issue_id, body) do
      {:ok, comment} -> {:ok, comment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_completed_workpad_issues(issues, "open") do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case workpad_state(issue.id) do
        {:ok, state} ->
          if completed_workpad?(state) or paused_after_delivery?(state, issue) or paused_after_reply?(state, issue) do
            {:cont, {:ok, acc}}
          else
            {:cont, {:ok, [issue | acc]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, filtered} -> {:ok, Enum.reverse(filtered)}
      error -> error
    end
  end

  defp reject_completed_workpad_issues(issues, _state), do: {:ok, issues}

  defp workpad_state(issue_id) do
    with {:ok, comments} <- list_comments(issue_id) do
      with {:ok, bot_login} <- bot_login() do
        comments
        |> Enum.find(&owned_workpad?(&1, bot_login))
        |> case do
          nil -> {:ok, %{}}
          comment -> {:ok, decode_workpad_state(comment.body)}
        end
      end
    end
  end

  defp confirm_claim(_issue_id, comment_id, run_id) do
    with {:ok, comment} <- fetch_comment(comment_id) do
      state = decode_workpad_state(comment.body)
      claim = get_in(state, ["claim"])

      if Map.get(claim || %{}, "run_id") == run_id do
        :ok
      else
        {:skip, {:claim_lost, claim || %{}}}
      end
    end
  end

  defp fetch_comment(comment_id) do
    tracker = Config.settings!().tracker

    case request(:get, "/repos/#{tracker.owner}/#{tracker.repo}/issues/comments/#{comment_id}") do
      {:ok, %{"id" => id, "body" => body} = response} ->
        with {:ok, bot_login} <- bot_login() do
          comment = %{id: to_string(id), body: body || "", url: response["html_url"], author_login: get_in(response, ["user", "login"])}

          if owned_workpad?(comment, bot_login) do
            {:ok, comment}
          else
            {:error, :github_workpad_not_owned_by_bot}
          end
        end

      {:ok, _} ->
        {:error, :github_unknown_payload}

      error ->
        error
    end
  end

  defp update_workpad_comment(issue, comment, state, metadata) do
    body = render_workpad(issue, state, metadata)
    update_issue_comment(comment.id, body)
  end

  defp create_issue_comment(issue_id, body) do
    tracker = Config.settings!().tracker

    case request(:post, comments_path(tracker, issue_id), %{"body" => body}) do
      {:ok, %{"id" => id, "body" => response_body} = response} ->
        {:ok, %{id: to_string(id), body: response_body, url: response["html_url"], author_login: get_in(response, ["user", "login"])}}

      {:ok, %{"id" => id} = response} ->
        {:ok, %{id: to_string(id), body: body, url: response["html_url"], author_login: get_in(response, ["user", "login"])}}

      {:ok, _response} ->
        {:error, :github_comment_missing_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_comment_write_result({:ok, _comment}), do: :ok
  defp normalize_comment_write_result(error), do: error

  defp update_issue_comment(comment_id, body) do
    tracker = Config.settings!().tracker

    case request(:patch, "/repos/#{tracker.owner}/#{tracker.repo}/issues/comments/#{comment_id}", %{"body" => body}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp context_pr_comments(nil), do: {:ok, []}
  defp context_pr_comments(pr_number), do: list_comments(pr_number)

  defp render_conversation_context(issue, workpad_state, issue_comments, pr_comments, max_comments) do
    parts = [
      "## Conversation Context",
      "### Issue",
      "- #{issue.identifier} — #{issue.title}",
      issue.url && "- URL: #{issue.url}",
      render_context_workpad(workpad_state),
      render_context_comments("Issue comments", issue_comments, max_comments),
      render_context_comments("PR comments", pr_comments, max_comments)
    ]

    parts
    |> Enum.reject(&blank_context_part?/1)
    |> Enum.join("\n\n")
    |> truncate_context()
  end

  defp render_context_workpad(state) when is_map(state) and map_size(state) > 0 do
    lines =
      [
        Map.get(state, "status") && "- Status: #{Map.get(state, "status")}",
        Map.get(state, "branch") && "- Branch: #{Map.get(state, "branch")}",
        Map.get(state, "pr_url") && "- PR: #{Map.get(state, "pr_url")}",
        Map.get(state, "delivered_at") && "- Delivered at: #{Map.get(state, "delivered_at")}",
        Map.get(state, "replied_at") && "- Replied at: #{Map.get(state, "replied_at")}"
      ]
      |> Enum.reject(&is_nil/1)

    if lines == [] do
      nil
    else
      Enum.join(["### Open Symphony workpad" | lines], "\n")
    end
  end

  defp render_context_workpad(_state), do: nil

  defp render_context_comments(_title, [], _max_comments), do: nil

  defp render_context_comments(title, comments, max_comments) do
    rendered =
      comments
      |> Enum.reject(&machine_only_comment?/1)
      |> Enum.take(-max_comments)
      |> Enum.map_join("\n\n", fn comment ->
        body =
          comment.body
          |> strip_machine_state_marker()
          |> redact()
          |> trim_context_comment()

        "- @#{comment.author_login || "unknown"}:\n\n  #{indent_context_body(body)}"
      end)

    if rendered == "", do: nil, else: "### #{title}\n#{rendered}"
  end

  defp machine_only_comment?(%{body: body}) do
    is_binary(body) and String.contains?(body, @workpad_marker) and String.trim(strip_machine_state_marker(body)) == @workpad_marker
  end

  defp strip_machine_state_marker(body) when is_binary(body) do
    Regex.replace(~r/\n?<!-- open-symphony:.*?-->\n?/s, body, "\n")
    |> String.trim()
  end

  defp trim_context_comment(body) when is_binary(body) do
    if String.length(body) > 1_500 do
      String.slice(body, 0, 1_500) <> "\n...<truncated>"
    else
      body
    end
  end

  defp indent_context_body(body) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n  ", &String.trim_trailing/1)
  end

  defp truncate_context(body) do
    if String.length(body) > 12_000 do
      String.slice(body, 0, 12_000) <> "\n...<context truncated>"
    else
      body
    end
  end

  defp blank_context_part?(nil), do: true
  defp blank_context_part?(false), do: true
  defp blank_context_part?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_context_part?(_value), do: false

  defp pr_number_from_url(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp pr_number_from_url(_), do: nil

  defp render_workpad(issue, state, metadata) do
    pretty_state = Jason.encode!(state)
    status = Map.get(state, "status", Map.get(metadata, :status, "running"))
    pr_url = Map.get(state, "pr_url", Map.get(metadata, :pr_url, ""))
    validation = Map.get(state, "validation", Map.get(metadata, :validation, []))

    """
    #{@workpad_marker}

    #{@state_marker_prefix}#{pretty_state}#{@state_marker_suffix}

    **Status:** #{status}
    **Issue:** #{issue.identifier} — #{issue.title}
    **PR:** #{blank(pr_url)}

    ### Validation

    #{format_validation(validation)}

    ### Recent Events

    #{Map.get(metadata, :event, "Updated by Open Symphony.")}
    """
    |> String.trim()
  end

  defp decode_workpad_state(body) when is_binary(body) do
    with [_, rest] <- String.split(body, @state_marker_prefix, parts: 2),
         [json, _] <- String.split(rest, @state_marker_suffix, parts: 2),
         {:ok, decoded} <- Jason.decode(String.trim(json)),
         true <- is_map(decoded) do
      decoded
    else
      _ -> %{}
    end
  end

  defp owned_workpad?(%{body: body, author_login: author_login}, bot_login) do
    author_login == bot_login and is_binary(body) and String.contains?(body, @workpad_marker)
  end

  defp owned_delivery_comment?(%{body: body, author_login: author_login}, bot_login) do
    author_login == bot_login and is_binary(body) and String.contains?(body, @delivery_marker)
  end

  defp bot_login do
    case Application.get_env(:symphony_elixir, :github_viewer_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      _ -> resolve_viewer_login()
    end
  end

  defp reply_target_id(%Issue{id: issue_id}, %{"last_trigger_source" => "pr_comment", "pr_url" => pr_url}) do
    pr_number_from_url(pr_url) || issue_id
  end

  defp reply_target_id(%Issue{id: issue_id}, _state), do: issue_id

  defp completed_workpad?(state) when is_map(state) do
    status = state |> Map.get("status", "") |> to_string() |> String.downcase()
    MapSet.member?(@completed_statuses, status)
  end

  defp completed_workpad?(_), do: false

  defp paused_after_delivery?(state, %Issue{updated_at: updated_at}) when is_map(state) do
    status = state |> Map.get("status", "") |> to_string() |> String.downcase()

    status == "pr_open" and
      not blank?(Map.get(state, "pr_url")) and
      not issue_updated_after_delivery?(updated_at, Map.get(state, "delivered_at"))
  end

  defp paused_after_delivery?(_, _), do: false

  defp paused_after_reply?(state, %Issue{updated_at: updated_at}) when is_map(state) do
    status = state |> Map.get("status", "") |> to_string() |> String.downcase()

    status == "reply_posted" and
      not issue_updated_after_delivery?(updated_at, Map.get(state, "replied_at"))
  end

  defp paused_after_reply?(_, _), do: false

  defp issue_updated_after_delivery?(%DateTime{} = updated_at, delivered_at) when is_binary(delivered_at) do
    case DateTime.from_iso8601(delivered_at) do
      {:ok, delivered_at, _} -> DateTime.compare(updated_at, delivered_at) == :gt
      _ -> true
    end
  end

  defp issue_updated_after_delivery?(_, _), do: false

  defp active_foreign_claim?(%{"expires_at" => expires_at, "run_id" => existing_run_id}, run_id, now) do
    existing_run_id != run_id and future_datetime?(expires_at, now)
  end

  defp active_foreign_claim?(_, _run_id, _now), do: false

  defp future_datetime?(raw, now) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _} -> DateTime.compare(datetime, now) == :gt
      _ -> false
    end
  end

  defp future_datetime?(_, _), do: false

  defp pending_pr_trigger?(state) when is_map(state) do
    match?({:ok, _comment}, latest_pending_pr_trigger(state))
  end

  defp pending_pr_trigger?(_state), do: false

  defp maybe_mark_pending_pr_trigger(state) when is_map(state) do
    case latest_pending_pr_trigger(state) do
      {:ok, comment} ->
        acknowledge_trigger_comment(comment.id)

        state
        |> Map.put("last_pr_trigger_comment_id", comment.id)
        |> Map.put("last_trigger_source", "pr_comment")
        |> Map.put("last_trigger_command", trigger_command(comment.body))

      _ ->
        state
    end
  end

  defp latest_pending_pr_trigger(state) when is_map(state) do
    with pr_url when is_binary(pr_url) <- Map.get(state, "pr_url"),
         pr_number when is_binary(pr_number) <- pr_number_from_url(pr_url),
         {:ok, comments} <- list_comments(pr_number),
         {:ok, bot_login} <- bot_login() do
      last_seen = Map.get(state, "last_pr_trigger_comment_id")

      comments
      |> Enum.reverse()
      |> Enum.find(fn comment -> pending_trigger_comment?(comment, bot_login, last_seen) end)
      |> case do
        nil -> :none
        comment -> {:ok, comment}
      end
    else
      nil -> :none
      {:error, reason} -> {:error, reason}
      _ -> :none
    end
  end

  defp latest_pending_pr_trigger(_state), do: :none

  defp pending_trigger_comment?(comment, bot_login, last_seen) do
    comment.author_login != bot_login and
      to_string(comment.id) != to_string(last_seen) and
      match?({:ok, _trigger, _command}, Feedback.normalize_trigger_command(comment.body, Config.settings!().github.feedback))
  end

  defp trigger_command(body) do
    case Feedback.normalize_trigger_command(body, Config.settings!().github.feedback) do
      {:ok, _trigger, command} -> trim_context_comment(redact(command))
      :ignore -> ""
    end
  end

  defp maybe_put_status(state, %{status: status}) when is_binary(status), do: Map.put(state, "status", status)
  defp maybe_put_status(state, _), do: state

  defp maybe_renew_claim(state, %{run_id: run_id}) when is_binary(run_id) do
    case get_in(state, ["claim", "run_id"]) do
      ^run_id -> put_in(state, ["claim", "expires_at"], renewed_claim_expiry())
      _ -> state
    end
  end

  defp maybe_renew_claim(state, _metadata), do: state

  defp renewed_claim_expiry do
    DateTime.utc_now()
    |> DateTime.add(@claim_ttl_seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(value) when is_map(value), do: stringify_metadata(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp blank(nil), do: "—"
  defp blank(""), do: "—"
  defp blank(value), do: value

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp format_validation([]), do: "No validation recorded yet."

  defp format_validation(validation) when is_list(validation) do
    Enum.map_join(validation, "\n", fn
      %{"command" => command, "exit_code" => 0} -> "- ✅ `#{command}`"
      %{"command" => command, "exit_code" => code} -> "- ❌ `#{command}` exited #{code}"
      %{command: command, exit_code: 0} -> "- ✅ `#{command}`"
      %{command: command, exit_code: code} -> "- ❌ `#{command}` exited #{code}"
      other -> "- #{inspect(other)}"
    end)
  end

  defp format_validation(other), do: inspect(other)

  defp redact(value) when is_binary(value) do
    value
    |> String.replace(~r/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/i, "\1[REDACTED]")
    |> String.replace(~r/\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]+/, "[REDACTED_GITHUB_TOKEN]")
    |> String.replace(~r/((?:token|password|secret|api[_-]?key)=)[^\s&]+/i, "\1[REDACTED]")
  end

  defp issue_path(tracker, issue_id), do: "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_id}"
  defp comments_path(tracker, issue_id), do: "/repos/#{tracker.owner}/#{tracker.repo}/issues/#{issue_id}/comments"

  defp request(method, path, body \\ nil) do
    if request_fun = Application.get_env(:symphony_elixir, :github_request_fun) do
      request_fun.(method, path, body)
    else
      tracker = Config.settings!().tracker
      url = String.trim_trailing(tracker.endpoint, "/") <> path

      opts = [headers: headers(tracker), connect_options: [timeout: 30_000], receive_timeout: 30_000]
      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      case Req.request([method: method, url: url] ++ opts) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: status, body: response_body}} ->
          Logger.error("GitHub API request failed status=#{status} body=#{inspect(response_body, limit: 20)}")
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp headers(tracker) do
    [
      {"Authorization", "Bearer #{tracker.api_key}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"},
      {"Content-Type", "application/json"}
    ]
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_), do: ""
end
