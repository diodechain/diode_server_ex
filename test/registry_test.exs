defmodule RegistryTest do
  alias Object.Ticket
  import Ticket
  alias Contract.Registry
  use ExUnit.Case, async: false
  import TestHelper

  setup_all do
    if Chain.peak() < 2 do
      Chain.Worker.work()
      Chain.Worker.work()
    end

    Chain.sync()
    :ok
  end

  test "future ticket" do
    tck =
      ticket(
        server_id: Wallet.address!(Store.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() + 1,
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    ret = Shell.call_tx(tx, "latest")
    {{:evmc_revert, "Ticket from the future?"}, _} = ret
    # if you get a  {{:evmc_revert, ""}, 85703} here it means for some reason the transaction
    # passed the initial test but failed on fleet_contract == 0
  end

  test "zero ticket" do
    tck =
      ticket(
        server_id: Wallet.address!(Store.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - 2,
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    {{:evmc_revert, ""}, _} = Shell.call_tx(tx, "latest")
  end

  test "unregistered device" do
    tck =
      ticket(
        server_id: Wallet.address!(Store.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - 2,
        fleet_contract: Diode.fleetAddress()
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    {{:evmc_revert, "Unregistered device"}, _} = Shell.call_tx(tx, "latest")
  end

  test "registered device" do
    # Registering the device:
    tx = Contract.Fleet.setDeviceWhiteListTx(clientid(1), true)
    Chain.Pool.add_transaction(tx)
    Chain.Worker.work()

    assert Contract.Fleet.deviceWhitelist(clientid(1)) == true

    tck =
      ticket(
        server_id: Wallet.address!(Store.wallet()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - 2,
        fleet_contract: Diode.fleetAddress()
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    {{:evmc_revert, "Unregistered device"}, _} = Shell.call_tx(tx, "latest")
  end

  # test "other ticket" do
  #   tck = {:ticket,<<200,130,148,47,90,222,116,155,125,206,154,221,127,149,167,136,113,162,63,46>>,1,<<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,0,6144,<<"spam">>,<<0,189,117,142,137,75,193,162,175,14,35,240,134,20,1,173,253,212,51,159,95,215,127,144,172,150,228,23,154,121,175,211,109,82,128,201,250,115,3,167,162,237,221,0,191,16,94,206,170,216,217,9,112,129,210,131,170,56,133,153,21,154,102,164,177>>,nil}

  #   raw = Ticket.raw(tck)
  #   tx  = Registry.submitTicketRawTx(raw)
  #   {:ok, :bla} = Shell.call_tx(tx, "latest")
  # end
end
