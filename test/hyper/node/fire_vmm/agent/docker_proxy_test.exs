defmodule Hyper.Node.FireVMM.Agent.DockerProxyTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Agent.DockerProxy

  # The token gate is the security boundary: given the bytes of an inbound HTTP
  # request head, decide whether it carries `Authorization: Bearer <token>` for
  # the VM's minted token. It must reject anything else without ever reaching
  # the upstream daemon.
  describe "authorized?/2" do
    defp head(headers), do: "GET /_ping HTTP/1.1\r\n" <> headers <> "\r\n"

    test "accepts a request carrying the exact bearer token" do
      assert DockerProxy.authorized?(head("authorization: Bearer s3cret\r\n"), "s3cret")
    end

    test "the header name is matched case-insensitively" do
      assert DockerProxy.authorized?(head("Authorization: Bearer s3cret\r\n"), "s3cret")
      assert DockerProxy.authorized?(head("AUTHORIZATION: Bearer s3cret\r\n"), "s3cret")
    end

    test "rejects a wrong token" do
      refute DockerProxy.authorized?(head("authorization: Bearer nope\r\n"), "s3cret")
    end

    test "rejects a missing Authorization header" do
      refute DockerProxy.authorized?(head("host: docker\r\n"), "s3cret")
    end

    test "rejects a non-Bearer scheme even if the value matches" do
      refute DockerProxy.authorized?(head("authorization: Basic s3cret\r\n"), "s3cret")
    end

    test "rejects when the configured token is blank (fail closed)" do
      refute DockerProxy.authorized?(head("authorization: Bearer \r\n"), "")
      refute DockerProxy.authorized?(head("authorization: Bearer s3cret\r\n"), "")
    end
  end

  describe "port_for/3" do
    test "maps a VM's uid to the base port plus its slot above the floor" do
      # Deterministic so the endpoint can be computed from State.describe/1's uid
      # without a runtime lookup of the proxy process.
      assert DockerProxy.port_for(900_000, 900_000, 12_375) == 12_375
      assert DockerProxy.port_for(900_005, 900_000, 12_375) == 12_380
    end
  end

  describe "unauthorized_response/0" do
    test "is a well-formed HTTP 401 with no body" do
      resp = DockerProxy.unauthorized_response()
      assert resp =~ ~r{^HTTP/1\.1 401 }
      assert resp =~ ~r{content-length: 0}i
      assert String.ends_with?(resp, "\r\n\r\n")
    end
  end

  describe "the TCP proxy" do
    setup do
      # A fake upstream standing in for the guest dockerd behind the vsock relay:
      # accepts one connection, echoes what it received to the test, replies 200.
      {:ok, up} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, up_port} = :inet.port(up)
      test = self()

      spawn_link(fn ->
        {:ok, conn} = :gen_tcp.accept(up)
        {:ok, req} = :gen_tcp.recv(conn, 0)
        send(test, {:upstream_received, req})
        :gen_tcp.send(conn, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
        :gen_tcp.close(conn)
      end)

      # The proxy dials its upstream over vsock in production; here it connects to
      # the fake upstream over loopback. Either way it hands back a :socket socket.
      dial = fn ->
        {:ok, sock} = :socket.open(:inet, :stream)
        :ok = :socket.connect(sock, %{family: :inet, addr: {127, 0, 0, 1}, port: up_port})
        {:ok, sock}
      end

      pid =
        start_supervised!(
          {DockerProxy, %{listen_ip: {127, 0, 0, 1}, listen_port: 0, token: "s3cret", dial: dial}}
        )

      %{port: DockerProxy.port(pid)}
    end

    test "rejects a tokenless connection with 401 and never dials the upstream", %{port: port} do
      {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(c, "GET /_ping HTTP/1.1\r\nhost: d\r\n\r\n")

      assert {:ok, resp} = :gen_tcp.recv(c, 0, 2_000)
      assert resp =~ "401"
      refute_received {:upstream_received, _}
    end

    test "forwards an authenticated connection and pipes the reply back", %{port: port} do
      {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          c,
          "GET /_ping HTTP/1.1\r\nauthorization: Bearer s3cret\r\nhost: d\r\n\r\n"
        )

      assert {:ok, resp} = :gen_tcp.recv(c, 0, 2_000)
      assert resp =~ "200 OK"
      assert resp =~ "ok"
      assert_receive {:upstream_received, req}
      assert req =~ "GET /_ping"
    end
  end
end
