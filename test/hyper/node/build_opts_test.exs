defmodule Hyper.Node.BuildOptsTest do
  use ExUnit.Case, async: true

  alias Hyper.Node
  alias Hyper.Vm.Spec

  # build_opts assembles the per-VM Opts. The Docker proxy needs a per-VM bearer
  # token minted once here, carried on Opts so State.describe/1 can hand it back
  # to whoever asks for the VM's Docker endpoint.
  test "mints a distinct, non-trivial docker token per VM" do
    spec = %Spec{img_id: "img", type: :micro, arch: :x86_64}
    one = Node.build_opts("vm-one", spec, 900_000, self(), "/vmlinux")
    two = Node.build_opts("vm-two", spec, 900_001, self(), "/vmlinux")

    assert is_binary(one.docker_token)
    # 32 random bytes url-encoded — long enough that guessing is hopeless.
    assert byte_size(one.docker_token) >= 32
    assert one.docker_token != two.docker_token
  end
end
