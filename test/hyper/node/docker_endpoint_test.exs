defmodule Hyper.Node.DockerEndpointTest do
  use ExUnit.Case, async: true

  # With no `docker_proxy_bind` configured (the default), the resolver answers
  # before it ever needs a running VM — the branch the cluster-facing
  # Hyper.docker_endpoint/1 can't reach without booting one.
  test "docker_endpoint/1 reports :not_configured when the node runs no proxy" do
    assert {:error, :not_configured} = Hyper.Node.docker_endpoint("vm-nonexistent")
  end
end
