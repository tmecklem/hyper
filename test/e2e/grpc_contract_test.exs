defmodule Hyper.E2e.GrpcContractTest do
  @moduledoc """
  Live contract test of the public gRPC surface (`hyper.grpc.v1.Hyper`),
  exercised from outside the BEAM: starts the gRPC server against the running
  app tree, then drives it with the TypeScript suite in `test/grpc/`, which
  loads `proto/hyper/grpc/v1/hyper.proto` directly. Status codes and the full
  VM lifecycle are asserted over the real wire, catching proto/codec/server
  drift a BEAM-side client cannot produce (e.g. unrecognised enum integers).

  Also carries one BEAM-side test of `ForkVm`: it needs a real booted parent
  VM (Firecracker + device-mapper), which the TypeScript suite cannot boot,
  so it drives `Hyper.Grpc.V1.Hyper.Stub` directly over the same server
  instead.

  Runs only under `--only integration` on a provisioned host (CI: the
  `integration` job). Requires node/npm on PATH; installs the suite's npm
  deps on first run.
  """
  use ExUnit.Case, async: false

  alias Hyper.Grpc.V1.{
    CreateVmRequest,
    CreateVmResponse,
    ExecRequest,
    ExecResponse,
    ForkVmRequest,
    ForkVmResponse,
    GetHostAddressRequest,
    GetHostAddressResponse,
    GetVmRequest,
    GetVmResponse,
    StopVmRequest
  }

  alias Hyper.Grpc.V1.Hyper.Stub

  @moduletag :integration
  @moduletag timeout: :timer.minutes(25)

  @port 50_061
  @suite_dir Path.expand("../grpc", __DIR__)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  setup_all do
    config = %Hyper.Cfg.Grpc{enabled: true, port: @port}
    start_supervised!({GRPC.Server.Supervisor, Hyper.Cfg.Grpc.server_options(config)})
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{@port}", adapter: GRPC.Client.Adapters.Gun)
    {:ok, channel: channel}
  end

  test "TypeScript contract suite passes against the live server" do
    ensure_node_deps!()

    {_streamed, status} =
      System.cmd("npm", ["test"],
        cd: @suite_dir,
        env: [{"HYPER_GRPC_ADDR", "127.0.0.1:#{@port}"}],
        stderr_to_stdout: true,
        into: IO.stream()
      )

    assert status == 0, "TypeScript gRPC contract suite failed (exit #{status}); see output above"
  end

  test "ForkVm boots a distinct child from a running parent", %{channel: channel} do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    assert {:ok, parent} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(parent) end)

    parent_id = Hyper.id(parent)
    assert parent_id, "Hyper.id/1 returned nil for a freshly-created VM"

    assert {:ok, %ForkVmResponse{vm_id: child_id, node: child_node}} =
             Stub.fork_vm(channel, %ForkVmRequest{vm_id: parent_id})

    assert is_binary(child_id) and child_id != parent_id
    assert child_node != ""

    on_exit(fn -> Stub.stop_vm(channel, %StopVmRequest{vm_id: child_id}) end)
  end

  test "the addressing and exec RPCs answer for a running VM", %{channel: channel} do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

    vm_id = Hyper.id(vm)
    assert vm_id, "Hyper.id/1 returned nil for a freshly-created VM"

    # Gate on guest-agent readiness before driving Exec over the wire: a
    # just-booted VM's agent races the test, and await_exec/3 retries through
    # it. Allow a cold-boot budget matching the fork suite's first-exec wait.
    assert {:ok, _} = Hyper.E2e.await_exec(vm, ["/bin/true"], :timer.minutes(3))

    assert {:ok, %GetHostAddressResponse{address: host_addr}} =
             Stub.get_host_address(channel, %GetHostAddressRequest{vm_id: vm_id})

    assert host_addr =~ ~r/^\d{1,3}(\.\d{1,3}){3}$/

    assert {:ok, %ExecResponse{stdout: stdout, exit_code: 0}} =
             Stub.exec(channel, %ExecRequest{vm_id: vm_id, argv: ["/bin/echo", "hi"]})

    assert stdout == "hi\n"
  end

  test "CreateVm returns a proxy Docker endpoint whose token gate is live", %{channel: channel} do
    # Enable the per-VM Docker proxy on loopback for this VM's boot. Set before
    # create so fire_vmm picks up the bind; the alpine image has no in-guest
    # dockerd, so we assert the endpoint + the live token gate (a 401 rejection
    # never dials the upstream), not a full Docker round-trip.
    Application.put_env(:hyper, Hyper.Cfg.Network, docker_proxy_bind: "127.0.0.1")
    on_exit(fn -> Application.delete_env(:hyper, Hyper.Cfg.Network) end)

    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    assert {:ok, %CreateVmResponse{vm_id: vm_id, docker_endpoint: endpoint, docker_token: token}} =
             Stub.create_vm(channel, %CreateVmRequest{
               img_id: img_id,
               instance_type: :INSTANCE_TYPE_MICRO,
               arch: :ARCHITECTURE_X86_64
             })

    on_exit(fn -> Stub.stop_vm(channel, %StopVmRequest{vm_id: vm_id}) end)

    assert endpoint =~ ~r{^tcp://127\.0\.0\.1:\d+$}
    assert byte_size(token) >= 32

    # GetVm re-resolves the same coordinates from just the vm_id — a client that
    # lost the create response is not locked out for the VM's lifetime.
    assert {:ok, %GetVmResponse{docker_endpoint: ^endpoint, docker_token: ^token}} =
             Stub.get_vm(channel, %GetVmRequest{vm_id: vm_id})

    "tcp://127.0.0.1:" <> port = endpoint
    {:ok, c} = :gen_tcp.connect({127, 0, 0, 1}, String.to_integer(port), [:binary, active: false])
    :ok = :gen_tcp.send(c, "GET /_ping HTTP/1.1\r\nhost: d\r\n\r\n")
    assert {:ok, resp} = :gen_tcp.recv(c, 0, 5_000)
    assert resp =~ "401"
  end

  defp ensure_node_deps! do
    if not File.dir?(Path.join(@suite_dir, "node_modules")) do
      {out, status} = System.cmd("npm", ["ci"], cd: @suite_dir, stderr_to_stdout: true)
      assert status == 0, "npm ci failed in #{@suite_dir}:\n#{out}"
    end
  rescue
    e in ErlangError ->
      flunk("""
      npm is unavailable (#{inspect(e.original)}). The gRPC contract suite
      (test/grpc) needs Node.js and npm on PATH.
      """)
  end
end
