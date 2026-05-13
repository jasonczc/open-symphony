defmodule SymphonyElixir.GitHub.Feedback do
  @moduledoc """
  Helpers for GitHub-native feedback triggers.
  """

  @spec normalize_trigger_command(String.t(), term()) :: {:ok, String.t(), String.t()} | :ignore
  def normalize_trigger_command(body, feedback) when is_binary(body) do
    triggers(feedback)
    |> Enum.find_value(:ignore, fn trigger ->
      case consume_trigger(body, trigger) do
        {:ok, command} -> {:ok, trigger, command}
        :ignore -> false
      end
    end)
  end

  def normalize_trigger_command(_body, _feedback), do: :ignore

  defp consume_trigger(body, trigger) do
    trimmed = String.trim_leading(body)

    cond do
      not is_binary(trigger) or String.trim(trigger) == "" ->
        :ignore

      trimmed == trigger ->
        {:ok, ""}

      String.starts_with?(trimmed, trigger <> " ") ->
        {:ok, trimmed |> String.slice(String.length(trigger)..-1//1) |> String.trim()}

      String.starts_with?(trimmed, trigger <> "\n") ->
        {:ok, trimmed |> String.slice(String.length(trigger)..-1//1) |> String.trim()}

      true ->
        :ignore
    end
  end

  defp triggers(feedback) do
    trigger_config = Map.get(feedback || %{}, :triggers, %{})
    primary = Map.get(trigger_config || %{}, :primary, "@open-symphony")
    aliases = Map.get(trigger_config || %{}, :aliases, ["@os"])

    [primary | List.wrap(aliases)]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
