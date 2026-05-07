defmodule SymphonyElixir.Resume.Sanitizer do
  @moduledoc """
  Sanitizes durable resume records before they are written to disk.

  Resume state is coordination metadata, not a transcript store. This module
  deliberately redacts raw prompts, tool output, request bodies, environment
  values, and secret-like fields before persistence.
  """

  @max_string_chars 1_000
  @redacted "[redacted]"
  @sensitive_key_pattern ~r/(api[_-]?key|authorization|body|cookie|dotenv|env|password|payload|private|prompt|raw|request|secret|token|tool[_-]?output|transcript)/i
  @secret_assignment_pattern ~r/(?i)\b([A-Z][A-Z0-9_]*(?:TOKEN|SECRET|KEY|PASSWORD|AUTH|COOKIE)[A-Z0-9_]*)\s*=\s*([^\s]+)/i
  @bearer_pattern ~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/=-]+/
  @key_value_secret_pattern ~r/(?i)\b(api[_-]?key|authorization|password|secret|token)\s*[:=]\s*([^\s,;]+)/i

  @spec sanitize(term()) :: term()
  def sanitize(value), do: sanitize_value(value, nil)

  @spec redacted_marker() :: String.t()
  def redacted_marker, do: @redacted

  defp sanitize_value(%DateTime{} = value, _key), do: DateTime.to_iso8601(value)

  defp sanitize_value(value, key) when is_map(value) do
    if sensitive_key?(key) do
      @redacted
    else
      value
      |> Enum.map(fn {nested_key, nested_value} ->
        normalized_key = normalize_key(nested_key)
        {normalized_key, sanitize_value(nested_value, normalized_key)}
      end)
      |> Map.new()
    end
  end

  defp sanitize_value(value, key) when is_list(value) do
    if sensitive_key?(key) do
      @redacted
    else
      Enum.map(value, &sanitize_value(&1, nil))
    end
  end

  defp sanitize_value(value, key) when is_binary(value) do
    if sensitive_key?(key) do
      @redacted
    else
      value
      |> redact_secret_strings()
      |> truncate_string()
    end
  end

  defp sanitize_value(value, _key) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value, _key) when is_pid(value), do: inspect(value)
  defp sanitize_value(value, _key) when is_reference(value), do: inspect(value)
  defp sanitize_value(value, _key) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize_value(value, _key), do: inspect(value, limit: 20, printable_limit: @max_string_chars)

  defp sensitive_key?(nil), do: false

  defp sensitive_key?(key) when is_binary(key) do
    String.match?(key, @sensitive_key_pattern)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp redact_secret_strings(value) do
    value
    |> String.replace(@secret_assignment_pattern, "\\1=#{@redacted}")
    |> String.replace(@bearer_pattern, "Bearer #{@redacted}")
    |> String.replace(@key_value_secret_pattern, "\\1=#{@redacted}")
  end

  defp truncate_string(value) do
    if String.length(value) <= @max_string_chars do
      value
    else
      String.slice(value, 0, @max_string_chars) <> "... [truncated]"
    end
  end
end
