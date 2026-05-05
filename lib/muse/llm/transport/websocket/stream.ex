defmodule Muse.LLM.Transport.WebSocket.Stream do
  @moduledoc """
  Testable WebSocket streaming transport abstraction for LLM providers.

  This module owns the transport lifecycle only: connect, send the caller's
  `:create_frame` once, synchronously receive inbound frames, and forward
  binary payloads to the caller-provided callback. Provider-specific event
  decoding stays outside this module.

  ## Provider-facing API

      Stream.request(
        [
          url: "wss://api.example.test/v1/responses",
          headers: [{"Authorization", "Bearer ..."}],
          create_frame: fn -> Jason.encode!(%{"type" => "response.create"}) end,
          timeout_ms: 10_000,
          receive_timeout: 30_000,
          max_retries: 0,
          ws_stream_fn: &Stream.default_stream/3
        ],
        fn frame ->
          # Provider decoder handles the frame.
          :ok
        end
      )

  Tests can inject `:ws_stream_fn` with the canonical 3-arity shape:

      fn url, ws_options, on_frame ->
        on_frame.("raw provider frame")
        {:ok, %{close_code: 1000, close_reason: "done"}}
      end

  `default_stream/3` supports injectable low-level callbacks (`:connect_fn`,
  `:send_fn`, `:recv_fn`) or a `:websocket_client` module/map with equivalent
  callbacks. When no client is provided in options, it falls back to
  `Application.get_env(:muse, :websocket_client)`. If that is also unconfigured
  (the default in dev/test), it returns `{:error, {:transport_error,
  :websocket_client_not_configured}}` rather than attempting a real network
  connection.

  To enable the production WebSocket client, configure:

      config :muse, :websocket_client, Muse.LLM.Transport.WebSocket.MintAdapter

  The built-in `MintAdapter` is backed by `Mint.WebSocket` and requires the
  `:mint_web_socket` dependency.

  Low-level callbacks use `connect_fn.(url, opts)`,
  `send_fn.(conn, create_frame, opts)`, and `recv_fn.(conn, opts)`. Inbound
  binary/text events are forwarded; close events return status; other
  non-binary/control events are ignored. Error summaries use
  `Muse.EventPayloadRedactor.redact_string/1` and do not include headers,
  bodies, or create frames.
  """

  alias Muse.LLM.Transport.WebSocket.SafeError

  @private_option_keys [
    :connect_fn,
    :create_frame,
    :recv_fn,
    :send_fn,
    :stream_fn,
    :websocket_client,
    :ws_stream_fn
  ]

  @missing {:__muse_websocket_missing_option__, __MODULE__}

  @type frame :: binary()
  @type on_frame :: (frame() -> term())
  @type close_status :: %{close_code: integer() | nil, close_reason: binary() | nil}
  @type result :: {:ok, close_status()} | {:error, {:transport_error, term()}}
  @type stream_fn :: (String.t(), keyword(), on_frame() -> result())
  @type connect_fn :: (String.t(), keyword() -> {:ok, term()} | {:error, term()})
  @type send_fn :: (term(), term(), keyword() -> :ok | {:ok, term()} | {:error, term()})
  @type recv_fn ::
          (term(), keyword() -> {:ok, term()} | {:ok, term(), term()} | {:error, term()})

  @type option ::
          {:url, String.t()}
          | {:headers, [{String.t(), String.t()}] | map()}
          | {:create_frame, term() | (-> term())}
          | {:timeout_ms, pos_integer()}
          | {:receive_timeout, pos_integer()}
          | {:max_retries, non_neg_integer()}
          | {:ws_stream_fn, stream_fn()}
          | {:stream_fn, stream_fn()}
          | {:connect_fn, connect_fn()}
          | {:send_fn, send_fn()}
          | {:recv_fn, recv_fn()}
          | {:websocket_client, module() | map()}

  @doc """
  Execute a single WebSocket streaming request.

  Required options:

    * `:url` — full `ws://` or `wss://` URL.
    * `:create_frame` — frame term (often a binary) or a zero-arity function
      that produces the frame. `default_stream/3` evaluates/sends it only after
      a connection opens.

  Optional options:

    * `:headers` — caller-provided headers; forwarded to low-level opts.
    * `:timeout_ms` — connect timeout; forwarded as both `:timeout_ms` and
      `connect_options: [timeout: timeout_ms]`.
    * `:receive_timeout` — receive timeout forwarded to low-level opts.
    * `:max_retries` — retry count forwarded to low-level opts.
    * `:ws_stream_fn` / `:stream_fn` — injectable 3-arity managed stream fn.
    * `:connect_fn`, `:send_fn`, `:recv_fn`, or `:websocket_client` — callbacks
      used by `default_stream/3`.

  Returns `{:ok, %{close_code: integer | nil, close_reason: binary | nil}}` on
  WebSocket close, or `{:error, {:transport_error, redacted_reason}}` on
  connect/send/receive errors.
  """
  @spec request(keyword() | map(), on_frame()) :: result()
  def request(options, on_frame) when is_function(on_frame, 1) do
    with {:ok, url} <- fetch_required(options, :url),
         {:ok, url} <- validate_url(url),
         {:ok, create_frame} <- fetch_required(options, :create_frame),
         {:ok, ws_stream_fn} <- resolve_stream_fn(options) do
      ws_options = build_ws_options(options, create_frame)
      safe_on_frame = fn frame -> deliver_frame(frame, on_frame) end

      ws_stream_fn.(url, ws_options, safe_on_frame)
      |> normalize_result()
    else
      {:error, {:transport_error, reason}} ->
        {:error, {:transport_error, SafeError.normalize_reason(reason)}}

      {:error, reason} ->
        {:error, {:transport_error, SafeError.summary(reason)}}
    end
  rescue
    exception ->
      {:error, {:transport_error, SafeError.summary(exception)}}
  catch
    kind, reason ->
      {:error, {:transport_error, SafeError.summary({kind, reason})}}
  end

  @doc """
  Default dependency-free WebSocket stream runner.

  This function has the provider-test-friendly shape
  `(url, ws_options, on_frame)`. Without injected low-level callbacks it falls
  back to `Application.get_env(:muse, :websocket_client)`. If no client is
  configured (the default in dev/test), it returns
  `{:error, {:transport_error, :websocket_client_not_configured}}` and performs
  no network work.
  """
  @spec default_stream(String.t(), keyword(), on_frame()) :: result()
  def default_stream(url, ws_options, on_frame)
      when is_binary(url) and is_list(ws_options) and is_function(on_frame, 1) do
    client_options = client_options(ws_options)

    with {:ok, connect_fn} <- resolve_connect_fn(ws_options),
         {:ok, conn} <- call_connect(connect_fn, url, client_options),
         {:ok, create_frame} <- resolve_create_frame(ws_options),
         {:ok, send_fn} <- resolve_send_fn(ws_options),
         {:ok, conn} <- call_send(send_fn, conn, create_frame, client_options),
         {:ok, recv_fn} <- resolve_recv_fn(ws_options) do
      receive_loop(conn, recv_fn, client_options, on_frame)
    else
      {:error, {:transport_error, reason}} ->
        {:error, {:transport_error, SafeError.normalize_reason(reason)}}

      {:error, {phase, reason}}
      when phase in [:connect_failed, :create_frame_failed, :send_failed] ->
        {:error, {:transport_error, SafeError.phase_summary(phase, reason)}}

      {:error, reason} ->
        {:error, {:transport_error, SafeError.summary(reason)}}
    end
  rescue
    exception ->
      {:error, {:transport_error, SafeError.summary(exception)}}
  catch
    kind, reason ->
      {:error, {:transport_error, SafeError.summary({kind, reason})}}
  end

  # ---------------------------------------------------------------------------
  # Request option handling
  # ---------------------------------------------------------------------------

  defp resolve_stream_fn(options) do
    case option_value(options, :ws_stream_fn) || option_value(options, :stream_fn) do
      nil -> {:ok, &default_stream/3}
      fun when is_function(fun, 3) -> {:ok, fun}
      _other -> {:error, :invalid_ws_stream_fn}
    end
  end

  defp build_ws_options(options, create_frame) do
    opts = [
      headers: normalize_headers(option_value(options, :headers, [])),
      create_frame: create_frame
    ]

    opts = put_positive_integer(opts, options, :timeout_ms)
    opts = put_positive_integer(opts, options, :receive_timeout)
    opts = put_non_negative_integer(opts, options, :max_retries)
    opts = put_connect_options(opts, options)

    opts
    |> put_present(options, :connect_fn)
    |> put_present(options, :send_fn)
    |> put_present(options, :recv_fn)
    |> put_present(options, :websocket_client)
  end

  defp put_positive_integer(opts, options, key) do
    case option_value(options, key) do
      value when is_integer(value) and value > 0 -> Keyword.put(opts, key, value)
      _other -> opts
    end
  end

  defp put_non_negative_integer(opts, options, key) do
    case option_value(options, key) do
      value when is_integer(value) and value >= 0 -> Keyword.put(opts, key, value)
      _other -> opts
    end
  end

  defp put_connect_options(opts, options) do
    base_connect_options =
      case option_value(options, :connect_options, []) do
        value when is_list(value) -> value
        _other -> []
      end

    connect_options =
      case Keyword.fetch(opts, :timeout_ms) do
        {:ok, timeout_ms} -> Keyword.put(base_connect_options, :timeout, timeout_ms)
        :error -> base_connect_options
      end

    if connect_options == [] do
      opts
    else
      Keyword.put(opts, :connect_options, connect_options)
    end
  end

  defp put_present(opts, options, key) do
    case option_value(options, key, @missing) do
      @missing -> opts
      value -> Keyword.put(opts, key, value)
    end
  end

  defp client_options(ws_options) do
    Keyword.drop(ws_options, @private_option_keys)
  end

  defp fetch_required(options, key) do
    case option_value(options, key, @missing) do
      @missing -> {:error, missing_reason(key)}
      value -> {:ok, value}
    end
  end

  defp missing_reason(:url), do: :missing_url
  defp missing_reason(:create_frame), do: :missing_create_frame

  defp validate_url(url) when is_binary(url) do
    cond do
      contains_control_character?(url) ->
        {:error, :websocket_url_contains_control_characters}

      true ->
        validate_parsed_url(url)
    end
  end

  defp validate_url(_url), do: {:error, :invalid_websocket_url}

  defp validate_parsed_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["ws", "wss"] and is_binary(host) and host != "" ->
        cond do
          has_component?(uri.userinfo) -> {:error, :websocket_url_contains_userinfo}
          has_component?(uri.query) -> {:error, :websocket_url_contains_query}
          has_component?(uri.fragment) -> {:error, :websocket_url_contains_fragment}
          true -> {:ok, url}
        end

      _other ->
        {:error, :invalid_websocket_url}
    end
  end

  defp has_component?(nil), do: false
  defp has_component?(""), do: false
  defp has_component?(_component), do: true

  defp contains_control_character?(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte < 32 or byte == 127 end)
  end

  defp option_value(options, key, default \\ nil)

  defp option_value(options, key, default) when is_list(options) and is_atom(key) do
    string_key = Atom.to_string(key)

    case List.keyfind(options, key, 0) do
      {^key, value} ->
        value

      nil ->
        case List.keyfind(options, string_key, 0) do
          {^string_key, value} -> value
          nil -> default
        end
    end
  end

  defp option_value(options, key, default) when is_map(options) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(options, key) -> Map.get(options, key)
      Map.has_key?(options, string_key) -> Map.get(options, string_key)
      true -> default
    end
  end

  defp option_value(_options, _key, default), do: default

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _other -> []
    end)
    |> Enum.sort_by(fn {key, _value} -> String.downcase(key) end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      _other -> []
    end)
    |> Enum.sort_by(fn {key, _value} -> String.downcase(key) end)
  end

  defp normalize_headers(_headers), do: []

  # ---------------------------------------------------------------------------
  # Low-level client resolution
  # ---------------------------------------------------------------------------

  defp resolve_connect_fn(ws_options) do
    case Keyword.get(ws_options, :connect_fn) do
      fun when is_function(fun, 2) -> {:ok, fun}
      nil -> resolve_client_callback(ws_options, :connect, 2)
      _other -> {:error, {:transport_error, :invalid_connect_fn}}
    end
  end

  defp resolve_send_fn(ws_options) do
    case Keyword.get(ws_options, :send_fn) do
      fun when is_function(fun, 3) -> {:ok, fun}
      nil -> resolve_client_callback(ws_options, [:send_frame, :send], 3)
      _other -> {:error, {:transport_error, :invalid_send_fn}}
    end
  end

  defp resolve_recv_fn(ws_options) do
    case Keyword.get(ws_options, :recv_fn) do
      fun when is_function(fun, 2) -> {:ok, fun}
      nil -> resolve_client_callback(ws_options, :recv, 2)
      _other -> {:error, {:transport_error, :invalid_recv_fn}}
    end
  end

  defp resolve_client_callback(ws_options, names, arity) when is_list(names) do
    Enum.reduce_while(
      names,
      {:error, {:transport_error, :websocket_client_not_configured}},
      fn name, _acc ->
        case resolve_client_callback(ws_options, name, arity) do
          {:ok, fun} ->
            {:halt, {:ok, fun}}

          {:error, {:transport_error, :websocket_client_not_configured}} ->
            {:cont, {:error, {:transport_error, :websocket_client_not_configured}}}

          other ->
            {:halt, other}
        end
      end
    )
  end

  defp resolve_client_callback(ws_options, name, arity) do
    case Keyword.get(ws_options, :websocket_client) do
      nil ->
        case resolve_configured_client() do
          nil ->
            {:error, {:transport_error, :websocket_client_not_configured}}

          client ->
            resolve_client_callback(
              Keyword.put(ws_options, :websocket_client, client),
              name,
              arity
            )
        end

      module when is_atom(module) ->
        resolve_module_callback(module, name, arity)

      callbacks when is_map(callbacks) ->
        resolve_map_callback(callbacks, name, arity)

      _other ->
        {:error, {:transport_error, :invalid_websocket_client}}
    end
  end

  defp resolve_configured_client do
    Application.get_env(:muse, :websocket_client)
  end

  defp resolve_module_callback(module, name, arity) do
    if Code.ensure_loaded?(module) and function_exported?(module, name, arity) do
      {:ok, module_callback(module, name, arity)}
    else
      {:error, {:transport_error, :websocket_client_not_configured}}
    end
  end

  defp module_callback(module, name, 2) do
    fn arg1, arg2 -> apply(module, name, [arg1, arg2]) end
  end

  defp module_callback(module, name, 3) do
    fn arg1, arg2, arg3 -> apply(module, name, [arg1, arg2, arg3]) end
  end

  defp resolve_map_callback(callbacks, name, arity) do
    case Map.get(callbacks, name) || Map.get(callbacks, Atom.to_string(name)) do
      fun when is_function(fun, arity) -> {:ok, fun}
      nil -> {:error, {:transport_error, :websocket_client_not_configured}}
      _other -> {:error, {:transport_error, :invalid_websocket_client}}
    end
  end

  # ---------------------------------------------------------------------------
  # Connect/send/receive lifecycle
  # ---------------------------------------------------------------------------

  defp call_connect(connect_fn, url, client_options) do
    case safe_call(fn -> connect_fn.(url, client_options) end) do
      {:ok, {:ok, conn}} ->
        {:ok, conn}

      {:ok, {:error, reason}} ->
        {:error, {:connect_failed, reason}}

      {:ok, other} ->
        {:error, {:connect_failed, {:unexpected_connect_result, SafeError.result_shape(other)}}}

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp resolve_create_frame(ws_options) do
    case Keyword.fetch(ws_options, :create_frame) do
      {:ok, create_frame_fn} when is_function(create_frame_fn, 0) ->
        case safe_call(create_frame_fn) do
          {:ok, {:ok, frame}} -> {:ok, frame}
          {:ok, {:error, reason}} -> {:error, {:create_frame_failed, reason}}
          {:ok, frame} -> {:ok, frame}
          {:error, reason} -> {:error, {:create_frame_failed, reason}}
        end

      {:ok, create_frame} ->
        {:ok, create_frame}

      :error ->
        {:error, {:transport_error, :missing_create_frame}}
    end
  end

  defp call_send(send_fn, conn, create_frame, client_options) do
    case safe_call(fn -> send_fn.(conn, create_frame, client_options) end) do
      {:ok, :ok} ->
        {:ok, conn}

      {:ok, {:ok, new_conn}} ->
        {:ok, new_conn}

      {:ok, {:error, reason}} ->
        {:error, {:send_failed, reason}}

      {:ok, other} ->
        {:error, {:send_failed, {:unexpected_send_result, SafeError.result_shape(other)}}}

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  defp receive_loop(conn, recv_fn, client_options, on_frame) do
    case safe_call(fn -> recv_fn.(conn, client_options) end) do
      {:ok, {:ok, event, new_conn}} ->
        handle_event(event, new_conn, recv_fn, client_options, on_frame)

      {:ok, {:ok, event}} ->
        handle_event(event, conn, recv_fn, client_options, on_frame)

      {:ok, {:error, reason}} ->
        {:error, {:transport_error, SafeError.phase_summary(:receive_failed, reason)}}

      {:ok, other} ->
        {:error,
         {:transport_error,
          SafeError.phase_summary(
            :receive_failed,
            {:unexpected_receive_result, SafeError.result_shape(other)}
          )}}

      {:error, reason} ->
        {:error, {:transport_error, SafeError.phase_summary(:receive_failed, reason)}}
    end
  end

  defp handle_event(event, conn, recv_fn, client_options, on_frame) do
    case close_status_from_event(event) do
      {:ok, close_status} ->
        {:ok, close_status}

      :not_close ->
        deliver_frame(event, on_frame)
        receive_loop(conn, recv_fn, client_options, on_frame)
    end
  end

  defp close_status_from_event(:close), do: {:ok, %{close_code: nil, close_reason: nil}}
  defp close_status_from_event(:closed), do: {:ok, %{close_code: nil, close_reason: nil}}

  defp close_status_from_event({event, code, reason}) when event in [:close, :closed] do
    {:ok, %{close_code: normalize_close_code(code), close_reason: normalize_close_reason(reason)}}
  end

  defp close_status_from_event({event, code}) when event in [:close, :closed] do
    {:ok, %{close_code: normalize_close_code(code), close_reason: nil}}
  end

  defp close_status_from_event({event, status})
       when event in [:close, :closed] and is_map(status) do
    {:ok, normalize_close_status(status)}
  end

  defp close_status_from_event(_event), do: :not_close

  defp deliver_frame(frame, on_frame) when is_binary(frame) do
    on_frame.(frame)
    :ok
  end

  defp deliver_frame({event, frame}, on_frame)
       when event in [:text, :binary, :frame, :data, :message] and is_binary(frame) do
    on_frame.(frame)
    :ok
  end

  defp deliver_frame(_frame, _on_frame), do: :ok

  # ---------------------------------------------------------------------------
  # Result normalization
  # ---------------------------------------------------------------------------

  defp normalize_result({:ok, close_status}), do: {:ok, normalize_close_status(close_status)}

  defp normalize_result({:error, {:transport_error, reason}}) do
    {:error, {:transport_error, SafeError.normalize_reason(reason)}}
  end

  defp normalize_result({:error, reason}),
    do: {:error, {:transport_error, SafeError.summary(reason)}}

  defp normalize_result(other) do
    {:error,
     {:transport_error,
      SafeError.summary({:unexpected_stream_result, SafeError.result_shape(other)})}}
  end

  defp normalize_close_status(%{} = status) do
    close_code =
      status
      |> first_present([:close_code, "close_code", :code, "code"])
      |> normalize_close_code()

    close_reason =
      status
      |> first_present([:close_reason, "close_reason", :reason, "reason"])
      |> normalize_close_reason()

    %{close_code: close_code, close_reason: close_reason}
  end

  defp normalize_close_status({code, reason}) do
    %{close_code: normalize_close_code(code), close_reason: normalize_close_reason(reason)}
  end

  defp normalize_close_status(_status), do: %{close_code: nil, close_reason: nil}

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp normalize_close_code(code) when is_integer(code), do: code
  defp normalize_close_code(_code), do: nil

  defp normalize_close_reason(reason) when is_binary(reason), do: reason
  defp normalize_close_reason(_reason), do: nil

  defp safe_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
