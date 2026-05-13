defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST client for issue-backed Symphony runs.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 100
  @workpad_marker "## Open Symphony Workpad"
  @state_marker_prefix "<!-- open-symphony:"
  @state_marker_suffix "-->"
  @completed_statuses MapSet.new(["done", "delivered", "blocked_review"])
  @claim_ttl_seconds 900

  @type comment :: %{id: String.t(), body: String.t(), url: String.t() | nil}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_config(tracker),
         {:ok, assignee} <- resolve_assignee(tracker) do
      fetch_issue_pages(tracker, assignee, 1, [])
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

      cond do
        paused_after_delivery?(existing, issue) ->
          {:skip, {:waiting_for_review_feedback, Map.get(existing, "pr_url")}}

        completed_workpad?(existing) ->
          {:skip, {:completed, Map.get(existing, "status")}}

        active_foreign_claim?(existing_claim, run_id, now) ->
          {:skip, {:claimed, existing_claim}}

        true ->
          state =
            existing
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
    tracker = Config.settings!().tracker

    case request(:post, comments_path(tracker, issue_id), %{"body" => body}) do
      {:ok, %{"id" => id, "body" => body} = response} ->
        {:ok, %{id: to_string(id), body: body, url: response["html_url"]}}

      {:ok, %{"id" => id} = response} ->
        {:ok, %{id: to_string(id), body: body, url: response["html_url"]}}

      {:ok, _response} ->
        {:error, :github_workpad_missing_comment_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_completed_workpad_issues(issues, "open") do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case workpad_state(issue.id) do
        {:ok, state} ->
          if completed_workpad?(state) or paused_after_delivery?(state, issue) do
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
    tracker = Config.settings!().tracker
    body = render_workpad(issue, state, metadata)

    case request(:patch, "/repos/#{tracker.owner}/#{tracker.repo}/issues/comments/#{comment.id}", %{"body" => body}) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp bot_login do
    case Application.get_env(:symphony_elixir, :github_viewer_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      _ -> resolve_viewer_login()
    end
  end

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
