defmodule Hyper.Node.DockerEndpointTest do
  # Mutates the global docker_proxy_bind app-env, so it cannot run concurrently.
  use ExUnit.Case, async: false

  # With no `docker_proxy_bind` configured (the default), the resolver answers
  # before it ever needs a running VM.
  test "docker_endpoint/1 reports :not_configured when the node runs no proxy" do
    assert {:error, :not_configured} = Hyper.Node.docker_endpoint("vm-nonexistent")
  end

  # With a proxy configured but no such VM, State.describe/1 exits and only that
  # is translated to :not_found — no VM boot needed to reach this branch.
  test "docker_endpoint/1 reports :not_found for an unknown VM when a proxy is configured" do
    Application.put_env(:hyper, Hyper.Cfg.Network, docker_proxy_bind: "127.0.0.1")
    on_exit(fn -> Application.delete_env(:hyper, Hyper.Cfg.Network) end)

    assert {:error, :not_found} = Hyper.Node.docker_endpoint("vm-nonexistent")
  end
end
