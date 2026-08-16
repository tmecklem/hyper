defmodule Hyper.Cfg.NetworkTest do
  use ExUnit.Case, async: false
  alias Hyper.Cfg.Network
  alias Hyper.Cfg.Toml

  describe "clone_pool/0" do
    test "defaults when unset" do
      # Mirrors default_clone_pool() in native/suidhelper/src/config.rs — the
      # two literals are safety-critical and must move together.
      assert Network.clone_pool() == "172.31.0.0/16"
    end
  end

  describe "docker_proxy_bind/0" do
    setup do
      on_exit(fn -> Application.delete_env(:hyper, Network) end)
    end

    test "is nil when unset" do
      assert Network.docker_proxy_bind() == nil
    end

    test "parses a configured IP string into an address tuple" do
      Application.put_env(:hyper, Network, docker_proxy_bind: "100.64.0.2")
      assert Network.docker_proxy_bind() == {100, 64, 0, 2}
    end

    test "raises a clear error on a non-IP value, rather than failing every VM launch" do
      Application.put_env(:hyper, Network, docker_proxy_bind: "not-an-ip")

      assert_raise ArgumentError, ~r/docker_proxy_bind/, fn ->
        Network.docker_proxy_bind()
      end
    end
  end

  describe "configured?/0" do
    test "false when no uplink configured" do
      # Base test config sets no [network] table. This is the predicate the
      # startup preflight uses to refuse booting a node without networking.
      refute Network.configured?()
    end
  end

  describe "uplink/0" do
    test "raises Hyper.Cfg.MissingError when network.uplink is unset" do
      # Pins the refusal contract: a [network] table present without `uplink`
      # must raise, not silently disable networking or crash uninformatively.
      on_exit(fn -> Toml.reload() end)
      Toml.put_cache(%{"network" => %{}})

      assert_raise Hyper.Cfg.MissingError, ~r/network\.uplink/, fn ->
        Network.uplink()
      end
    end

    test "raises ArgumentError when network.uplink is not a string" do
      # A non-string uplink must raise ArgumentError, not be silently coerced
      # or passed to the setuid helper which would then build a broken netns.
      on_exit(fn -> Toml.reload() end)
      Toml.put_cache(%{"network" => %{"uplink" => 123}})

      assert_raise ArgumentError, ~r/network\.uplink/, fn ->
        Network.uplink()
      end
    end
  end
end
