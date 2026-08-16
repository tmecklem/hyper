defmodule Hyper.Node.FireVMM.Agent.DockerProxy do
  @moduledoc """
  Per-VM authenticating TCP proxy for a guest's Docker daemon.

  Unlike `Hyper.Node.FireVMM.Agent.Relay`, which serves the daemon on a
  host-local Unix socket, this proxy listens on TCP (bound to the node's tailnet
  address) so a remote control plane can reach it. It gates each connection on a
  per-VM bearer token before forwarding to the daemon over vsock — the tailnet
  (WireGuard + ACLs) is the outer boundary, the token the inner one.

  Docker hijacks connections for `exec`/`attach`/`logs -f`, so the proxy checks
  the token on the first request head and then byte-pipes the connection
  verbatim, rather than parsing every request.

  Process topology mirrors `Relay`: the GenServer owns the TCP listen socket and
  spawns a linked acceptor; each connection is handled in its own process, which
  reads the request head, gates on the token, dials the upstream, and then splices
  the two sockets byte-for-byte until either side closes.
  """

  use GenServer

  # Reject an oversized request head rather than buffer unboundedly while
  # hunting for the end-of-headers marker.
  @max_head_bytes 64 * 1024
  @listen_backlog 16

  @unauthorized "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"

  @typedoc "A thunk that dials the upstream Docker daemon, returning a connected socket."
  @type dialer :: (-> {:ok, :socket.socket()} | {:error, term()})

  @spec start_link(%{
          required(:listen_ip) => :inet.ip_address(),
          required(:token) => String.t(),
          required(:dial) => dialer(),
          optional(:listen_port) => :inet.port_number(),
          optional(:name) => GenServer.name()
        }) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if name = Map.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The TCP port the proxy is listening on (useful when started with port 0)."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc """
  Mint a fresh per-VM bearer token: 32 bytes of CSPRNG entropy, URL-safe so it
  drops straight into an `Authorization: Bearer` header.
  """
  @spec mint_token() :: String.t()
  def mint_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc """
  Resolve a VM's proxy port from its `uid` and the node's config — the single
  source both the supervisor (which binds the port) and `Hyper.docker_endpoint/1`
  (which advertises it) call, so the bound and advertised ports cannot drift.
  """
  @spec port_for(non_neg_integer()) :: non_neg_integer()
  def port_for(uid) do
    {floor, _ceiling} = Hyper.Cfg.Jails.uid_gid_range()
    port_for(uid, floor, Hyper.Cfg.Network.docker_proxy_base_port())
  end

  @doc """
  The deterministic listen port for a VM: `base` plus the VM's slot above the
  uid `floor`. Deterministic so a caller can compute a VM's Docker endpoint from
  its uid alone (via `State.describe/1`), never needing to find the proxy process.
  """
  # Dialyzer widens integer `+`/`-` to number() (folding in float()) even though
  # every operand here is an integer, so it flags the (correct) integer spec.
  @dialyzer {:nowarn_function, port_for: 3}
  @spec port_for(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def port_for(uid, floor, base), do: base + (uid - floor)

  @doc """
  Whether an inbound HTTP request `head` carries `Authorization: Bearer <token>`
  for `token`.

  The header name is matched case-insensitively, the scheme must be `Bearer`,
  and the presented credential is compared to `token` in constant time. A blank
  `token` fails closed — an unprovisioned proxy admits no one.
  """
  @spec authorized?(binary(), binary()) :: boolean()
  def authorized?(_head, token) when token in [nil, ""], do: false

  def authorized?(head, token) when is_binary(head) and is_binary(token) do
    case bearer_credential(head) do
      nil -> false
      presented -> constant_time_equal?(presented, token)
    end
  end

  @doc "The verbatim HTTP 401 response sent when the token gate rejects a connection."
  @spec unauthorized_response() :: binary()
  def unauthorized_response, do: @unauthorized

  # The credential from the first `Authorization: Bearer <token>` header, or nil.
  @spec bearer_credential(binary()) :: binary() | nil
  defp bearer_credential(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      with [name, value] <- String.split(line, ":", parts: 2),
           true <- String.downcase(String.trim(name)) == "authorization",
           ["Bearer", credential] <- String.split(String.trim(value), " ", parts: 2) do
        credential
      else
        _ -> nil
      end
    end)
  end

  # Length-checked constant-time comparison. Equal length is a precondition of
  # :crypto.hash_equals/2; a length mismatch is simply not a match.
  @spec constant_time_equal?(binary(), binary()) :: boolean()
  defp constant_time_equal?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp constant_time_equal?(_a, _b), do: false

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, sock} = :socket.open(:inet, :stream)
    :ok = :socket.setopt(sock, {:socket, :reuseaddr}, true)

    bind_addr = %{
      family: :inet,
      addr: Map.fetch!(opts, :listen_ip),
      port: Map.get(opts, :listen_port, 0)
    }

    :ok = :socket.bind(sock, bind_addr)
    :ok = :socket.listen(sock, @listen_backlog)
    %{port: port} = sockname(sock)

    {:ok,
     %{listen: sock, port: port, token: Map.fetch!(opts, :token), dial: Map.fetch!(opts, :dial)},
     {:continue, :start_acceptor}}
  end

  @impl GenServer
  def handle_continue(:start_acceptor, state) do
    _ = spawn_link(fn -> accept_loop(state.listen, state.token, state.dial) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = :socket.close(state.listen)
    :ok
  end

  @spec sockname(:socket.socket()) :: %{port: :inet.port_number()}
  defp sockname(sock) do
    {:ok, %{addr: {_a, _b, _c, _d}, port: port}} = :socket.sockname(sock)
    %{port: port}
  end

  defp accept_loop(listen, token, dial) do
    case :socket.accept(listen) do
      {:ok, client} ->
        _ = spawn(fn -> handle_connection(client, token, dial) end)
        accept_loop(listen, token, dial)

      # terminate/2 closes the listen socket; that unblocks accept as the
      # expected shutdown path, so exit normally rather than signalling the
      # linked GenServer.
      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_error, reason})
    end
  end

  defp handle_connection(client, token, dial) do
    with {:ok, head} <- read_head(client, ""),
         true <- authorized?(head, token),
         {:ok, upstream} <- dial.(),
         :ok <- send_all(upstream, head) do
      splice(client, upstream)
    else
      false ->
        _ = send_all(client, unauthorized_response())
        _ = :socket.close(client)

      _ ->
        _ = :socket.close(client)
    end
  end

  # Accumulate bytes until the end-of-headers marker, so the token gate sees the
  # whole header block. Anything read past it (pipelined body bytes) is carried
  # along and forwarded to the upstream verbatim.
  @spec read_head(:socket.socket(), binary()) :: {:ok, binary()} | {:error, term()}
  defp read_head(sock, acc) do
    cond do
      String.contains?(acc, "\r\n\r\n") -> {:ok, acc}
      byte_size(acc) > @max_head_bytes -> {:error, :head_too_large}
      true -> with {:ok, data} <- :socket.recv(sock), do: read_head(sock, acc <> data)
    end
  end

  # Bidirectional splice: one worker per direction, linked so a handler death
  # reaps both, monitored so a normal end of one closes both sockets cleanly.
  defp splice(client, upstream) do
    p1 = spawn_link(fn -> pipe(client, upstream) end)
    p2 = spawn_link(fn -> pipe(upstream, client) end)
    ref1 = Process.monitor(p1)
    ref2 = Process.monitor(p2)
    await_end(client, upstream, {p1, ref1}, {p2, ref2})
  end

  defp await_end(client, upstream, {p1, ref1}, {p2, ref2}) do
    receive do
      {:DOWN, ^ref1, :process, ^p1, _} -> tear_down(client, upstream, p2, ref2)
      {:DOWN, ^ref2, :process, ^p2, _} -> tear_down(client, upstream, p1, ref1)
    end
  end

  defp tear_down(client, upstream, sibling, sibling_ref) do
    _ = Process.demonitor(sibling_ref, [:flush])
    # Unlink before killing so the sibling's :killed exit does not propagate
    # back to this handler via the link.
    _ = Process.unlink(sibling)
    _ = Process.exit(sibling, :kill)
    _ = :socket.close(client)
    _ = :socket.close(upstream)
  end

  defp pipe(from, to) do
    case :socket.recv(from) do
      {:ok, data} ->
        case send_all(to, data) do
          :ok -> pipe(from, to)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  @spec send_all(:socket.socket(), binary()) :: :ok | {:error, term()}
  defp send_all(sock, data) do
    case :socket.send(sock, data) do
      :ok -> :ok
      {:ok, rest} -> send_all(sock, rest)
      {:error, _} = err -> err
    end
  end
end
