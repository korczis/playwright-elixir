defmodule Playwright.Client.Transport.WebSocket do
  @moduledoc false
  use GenServer
  alias Playwright.Connection
  require Logger

  # API
  # ---------------------------------------------------------------------------

  defstruct([
    :connection,
    :gun,
    :gun_process_monitor,
    :gun_stream_ref
  ])

  def start_link([ws_endpoint, connection]) do
    GenServer.start_link(__MODULE__, [ws_endpoint, connection])
  end

  def start_link!(args) do
    {:ok, pid} = start_link(args)
    pid
  end

  @impl GenServer
  def init([ws_endpoint, connection]) do
    uri = URI.parse(ws_endpoint)

    with {:ok, gun_pid} <- :gun.open(to_charlist(uri.host), port(uri), %{connect_timeout: 30_000}),
         {:ok, _protocol} <- :gun.await_up(gun_pid, :timer.seconds(5)),
         {:ok, stream_ref} <- ws_upgrade(gun_pid, uri.path),
         :ok <- wait_for_ws_upgrade() do
      ref = Process.monitor(gun_pid)

      {:ok,
       __struct__(
         connection: connection,
         gun: gun_pid,
         gun_process_monitor: ref,
         gun_stream_ref: stream_ref
       )}
    else
      error -> error
    end
  end

  @spec send_message(pid(), binary()) :: :ok
  def send_message(pid, message) do
    GenServer.cast(pid, {:send_message, message})
    :ok
  end

  # @impl
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:send_message, message}, state) do
    :gun.ws_send(state.gun, {:text, message})
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, _gun_pid, _stream_ref, frame}, state) do
    case frame do
      {:text, data} ->
        debug("frame: #{data}")
        Connection.recv(state.connection, frame)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    warn("Process went down: #{inspect(pid)}")
    {:stop, reason, state}
  end

  defp port(%{port: port}) when not is_nil(port), do: port
  defp port(%{scheme: "ws"}), do: 80
  defp port(%{scheme: "wss"}), do: 443

  defp wait_for_ws_upgrade do
    receive do
      {:gun_upgrade, _pid, _stream_ref, ["websocket"], _headers} ->
        :ok

      {:gun_response, _pid, _stream_ref, _, status, _headers} ->
        {:error, status}

      {:gun_error, _pid, _stream_ref, reason} ->
        {:error, reason}
    after
      1000 ->
        exit(:timeout)
    end
  end

  defp ws_upgrade(gun_pid, path), do: {:ok, :gun.ws_upgrade(gun_pid, path)}

  defp debug(msg), do: Logger.debug("[websocket@#{inspect(self())}] #{msg}")
  defp warn(msg), do: Logger.warn("[websocket@#{inspect(self())}] #{msg}")
end