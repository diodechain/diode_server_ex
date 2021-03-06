# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Block do
  alias Chain.{Block, BlockCache, State, Transaction, Header}

  @enforce_keys [:coinbase]
  defstruct transactions: [], header: %Chain.Header{}, receipts: [], coinbase: nil

  @type t :: %Chain.Block{
          transactions: [Chain.Transaction.t()],
          header: Chain.Header.t(),
          receipts: [Chain.TransactionReceipt.t()],
          coinbase: any()
        }

  @min_difficulty 65536
  @max_difficulty 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  def header(%Block{header: header}), do: header
  def txhash(%Block{header: header}), do: header.transaction_hash

  def parent(block, parent \\ nil)

  def parent(
        %Block{header: %Header{previous_block: hash}},
        %Block{header: %Header{block_hash: hash}} = parent
      ),
      do: parent

  def parent(%Block{} = block, nil), do: Chain.block_by_hash(parent_hash(block))
  def parent_hash(%Block{header: header}), do: header.previous_block
  def nonce(%Block{header: header}), do: header.nonce
  def state_hash(%Block{header: header}), do: Header.state_hash(header)
  @spec hash(Chain.Block.t()) :: binary() | nil
  # Fix for creating a signature of a non-exisiting block in registry_test.ex
  def hash(nil), do: nil
  def hash(%Block{header: header}), do: header.block_hash
  @spec transactions(Chain.Block.t()) :: [Chain.Transaction.t()]
  def transactions(%Block{transactions: transactions}), do: transactions
  @spec timestamp(Chain.Block.t()) :: non_neg_integer()
  def timestamp(%Block{header: header}), do: header.timestamp
  def receipts(%Block{receipts: receipts}), do: receipts

  def has_state?(%Block{header: %{state_hash: %Chain.State{}}}) do
    true
  end

  def has_state?(_block) do
    false
  end

  @spec state(Chain.Block.t()) :: Chain.State.t()
  def state(%Block{} = block) do
    if has_state?(block) do
      # This is actually a full %Chain.State{} object when has_state?() == true
      block.header.state_hash
    else
      Model.ChainSql.state(hash(block))
    end
  end

  @doc "For snapshot exporting ensure the block has a full state object"
  @spec with_state(Chain.Block.t()) :: Chain.Block.t()
  def with_state(%Block{} = block) do
    if has_state?(block) do
      block
    else
      with_state(block, state(block))
    end
  end

  @spec with_state(Chain.Block.t(), Chain.State.t()) :: Chain.Block.t()
  def with_state(%Block{} = block, %Chain.State{} = state) do
    %Block{block | header: %{block.header | state_hash: state}}
  end

  @spec valid?(Chain.Block.t()) :: boolean()
  def valid?(block) do
    case validate(block, parent(block)) do
      %Block{} -> true
      _ -> false
    end
  end

  defp test(test, fun) do
    {test, fun.()}
  end

  defp test_tc(test, fun) do
    {test, tc(test, fun)}
  end

  defp tc(test, fun) do
    Stats.tc(test, fun)
  end

  @blockquick_margin div(Chain.window_size(), 10)
  def in_final_window?(block), do: in_final_window?(block, parent(block))

  def in_final_window?(block, parent) do
    nr = number(block)

    if ChainDefinition.check_window(nr) do
      Block.number(last_final(block, parent)) + Chain.window_size() - @blockquick_margin >=
        Block.number(block)
    else
      true
    end
  end

  @spec validate(Chain.Block.t(), Chain.Block.t()) :: Chain.Block.t() | {non_neg_integer(), any()}
  def validate(%Block{} = block, %Block{} = parent) do
    # IO.puts("Block #{number(block)}.: #{length(transactions(block))}txs")
    BlockCache.cache(block)

    with {_, %Block{}} <- {:is_block, block},
         {_, true} <-
           test(:has_parent, fn -> parent_hash(block) == hash(parent) end),
         {_, true} <-
           test(:correct_number, fn -> number(block) == number(parent) + 1 end),
         {_, true} <-
           test_tc(:diverse, fn ->
             is_diverse?(ChainDefinition.min_diversity(number(block)), block, parent)
           end),
         {_, true} <-
           test_tc(:in_final_window, fn -> in_final_window?(block, parent) end),
         {_, true} <- test(:hash_valid, fn -> hash_valid?(block) end),
         {_, []} <-
           test_tc(:tx_valid, fn ->
             Enum.map(transactions(block), &Transaction.validate/1)
             |> Enum.reject(fn tx -> tx == true end)
           end),
         {_, true} <- test_tc(:min_tx_fee, fn -> conforms_min_tx_fee?(block, parent) end),
         {_, true} <-
           test(:tx_hash_valid, fn ->
             Diode.hash(encode_transactions(transactions(block))) == txhash(block)
           end),
         {_, sim_block} <- test_tc(:simulate, fn -> simulate(block) end),
         {_, true} <- test_tc(:registry_tx, fn -> has_registry_tx?(sim_block) end),
         {_, true} <- test_tc(:state_equal, fn -> state_equal(sim_block, block) end) do
      %{sim_block | header: %{block.header | state_hash: sim_block.header.state_hash}}
    else
      {nr, error} -> {nr, error}
    end
  end

  def validate(_block, nil) do
    {:has_parent, false}
  end

  defp conforms_min_tx_fee?(block, parent) do
    if ChainDefinition.min_transaction_fee(number(block)) do
      fee = Contract.Registry.min_transaction_fee(parent)
      # We're ignoring the last TX because that is by convention the Registry TX with
      # a gas price of 0
      txs = transactions(block)
      {_, txs} = List.pop_at(txs, length(txs) - 1)
      # :io.format("Min fee: ~p~n", [fee])
      Enum.all?(txs, fn tx ->
        # :io.format("TX fee: ~p~n", [Transaction.gas_price(tx)])
        Transaction.gas_price(tx) >= fee
      end)
    else
      true
    end
  end

  defp has_registry_tx?(block) do
    position = ChainDefinition.block_reward_position(number(block))
    has_registry_tx?(position, block)
  end

  defp has_registry_tx?(:first, block) do
    wallet = miner(block)
    tx = hd(transactions(block))

    Wallet.equal?(Transaction.origin(tx), wallet) and
      Transaction.gas_price(tx) == 0 and
      Transaction.gas_limit(tx) == 1_000_000_000 and
      Transaction.to(tx) == Diode.registry_address() and
      Transaction.data(tx) == ABI.encode_call("blockReward")
  end

  defp has_registry_tx?(:last, block) do
    wallet = miner(block)
    tx = List.last(transactions(block))
    rcpt = List.last(receipts(block))
    # This is are the input parameters for the last transaction
    # and should not include self
    used = gas_used(block) - rcpt.gas_used
    # - rcpt.gas_used * tx.gas_price (always 0)
    fees = gas_fees(block)

    Wallet.equal?(Transaction.origin(tx), wallet) and
      Transaction.gas_price(tx) == 0 and
      Transaction.gas_limit(tx) == 1_000_000_000 and
      Transaction.to(tx) == Diode.registry_address() and
      Transaction.data(tx) == ABI.encode_call("blockReward", ["uint256", "uint256"], [used, fees])
  end

  defp state_equal(sim_block, block) do
    if state_hash(sim_block) != state_hash(block) do
      # can inject code here to produce debug output
      # state_a = Block.state(sim_block)
      # state_b = Block.state(block)
      # diff = Chain.State.difference(state_a, state_b)
      # :io.format("State non equal:~p~n", [diff])
      false
    else
      true
    end
  end

  def hash_valid?(block) do
    with %Block{} <- block,
         header <- header(block),
         hash <- hash(block),
         ^hash <- Header.update_hash(header).block_hash,
         true <- hash_in_target?(block, hash) do
      true
    else
      _ -> false
    end
  end

  @spec hash_in_target?(Chain.Block.t(), binary) :: boolean
  def hash_in_target?(block, hash) do
    Hash.integer(hash) < hash_target(block)
  end

  @spec hash_target(Chain.Block.t()) :: integer
  def hash_target(block) do
    blockRef = parent(block)

    # Calculating stake weight as
    # ( stake / 1000 )²  but no less than 1
    #
    # For two decimal accuracy we calculcate in two steps:
    # (( stake / 100 )² * max_diff) / (10² * difficulty_block)
    #
    stake =
      if blockRef == nil do
        1
      else
        Contract.Registry.miner_value(0, BlockCache.coinbase(block), blockRef)
        |> div(Shell.ether(1000))
        |> max(1)
        |> min(50)
      end

    diff = BlockCache.difficulty(block)
    div(stake * stake * @max_difficulty, diff)
    # :io.format("hash_target(~p) = ~p (~p * ~p)~n", [Block.printable(block), ret, diff, stake])
    # ret
  end

  @doc "Creates a new block and stores the generated state in cache file"
  @spec create(
          Chain.Block.t(),
          [Chain.Transaction.t()],
          Wallet.t(),
          non_neg_integer(),
          true | false
        ) ::
          Chain.Block.t()
  def create(%Block{} = parent, transactions, miner, time, trace? \\ false) do
    block = create_empty(parent, miner, time)

    Stats.tc(:tx, fn ->
      Enum.reduce(transactions, block, fn %Transaction{} = tx, block ->
        case append_transaction(block, tx, trace?) do
          {:error, _err} -> block
          {:ok, block} -> block
        end
      end)
    end)
    |> finalize_header()
  end

  @doc "Creates a new block and stores the generated state in cache file"
  @spec create_empty(
          Chain.Block.t(),
          Wallet.t(),
          non_neg_integer()
        ) ::
          Chain.Block.t()
  def create_empty(%Block{} = parent, miner, time) do
    tc(:create_empty, fn ->
      %Block{
        header: %Header{
          previous_block: hash(parent),
          number: number(parent) + 1,
          timestamp: time,
          state_hash: state(parent)
        },
        coinbase: miner
      }
    end)
  end

  def append_transaction(%Block{transactions: txs, receipts: rcpts} = block, tx, trace? \\ false) do
    if not has_state?(block) do
      throw(:requires_embedded_state)
    end

    state = state(block)

    case Transaction.apply(tx, block, state, trace: trace?) do
      {:ok, state, rcpt} ->
        {:ok,
         %Block{
           block
           | transactions: txs ++ [tx],
             receipts: rcpts ++ [rcpt],
             header: %Header{
               block.header
               | state_hash: state
             }
         }}

      {:error, message} ->
        Transaction.print(tx)
        IO.puts("\tError:       #{inspect(message)}")
        {:error, message}
    end
  end

  def finalize_header(%Block{} = block) do
    block = ChainDefinition.hardforks(block)

    tc(:create_header, fn ->
      %Block{
        block
        | header: %Header{
            block.header
            | state_hash: tc(:normalize, fn -> State.normalize(state(block)) end),
              transaction_hash: Diode.hash(encode_transactions(transactions(block)))
          }
      }
    end)
  end

  @spec encode_transactions(any()) :: binary()
  def encode_transactions(transactions) do
    BertExt.encode!(Enum.map(transactions, &Transaction.to_rlp/1))
  end

  @spec simulate(Chain.Block.t()) :: Chain.Block.t()
  def simulate(%Block{} = block) do
    parent =
      if Block.number(block) >= 1 do
        %Block{} = parent(block)
      else
        Chain.GenesisFactory.testnet_parent()
      end

    create(parent, transactions(block), miner(block), timestamp(block), false)
  end

  @spec sign(Block.t(), Wallet.t()) :: Block.t()
  def sign(%Block{} = block, miner) do
    header =
      header(block)
      |> Header.sign(miner)
      |> Header.update_hash()

    %Block{block | header: header}
  end

  @spec transaction_index(Chain.Block.t(), Chain.Transaction.t()) ::
          nil | non_neg_integer()
  def transaction_index(%Block{} = block, %Transaction{} = tx) do
    Enum.find_index(transactions(block), fn elem ->
      elem == tx
    end)
  end

  def transaction(%Block{} = block, tx_hash) do
    Enum.find(transactions(block), fn tx -> Transaction.hash(tx) == tx_hash end)
  end

  # The second parameter is an optimizaton for cache bootstrap
  @spec difficulty(Block.t(), Block.t() | nil) :: non_neg_integer()
  def difficulty(%Block{} = block, parent \\ nil) do
    if Diode.dev_mode?() do
      1
    else
      do_difficulty(block, parent(block, parent))
    end
  end

  defp do_difficulty(%Block{} = block, parent) do
    if parent == nil do
      @min_difficulty
    else
      delta = timestamp(block) - timestamp(parent)
      diff = BlockCache.difficulty(parent)
      step = div(diff, 10)

      diff =
        if delta < Chain.blocktime_goal() do
          diff + step
        else
          diff - step
        end

      if diff < @min_difficulty do
        @min_difficulty
      else
        diff
      end
    end
  end

  # The second parameter is an optimizaton for cache bootstrap
  @spec total_difficulty(Block.t(), Block.t() | nil) :: non_neg_integer()
  def total_difficulty(%Block{} = block, parent \\ nil) do
    parent = parent(block, parent)

    # Explicit usage of Block and BlockCache cause otherwise cache filling
    # becomes self-recursive problem
    if parent == nil do
      Block.difficulty(block)
    else
      BlockCache.total_difficulty(parent) + Block.difficulty(block, parent)
    end
  end

  @spec number(Block.t()) :: non_neg_integer()
  def number(%Block{header: %Header{number: number}}) do
    number
  end

  @spec gas_price(Chain.Block.t()) :: non_neg_integer()
  def gas_price(%Block{} = block) do
    price =
      Enum.reduce(transactions(block), nil, fn tx, price ->
        if price == nil or price > Transaction.gas_price(tx) do
          Transaction.gas_price(tx)
        else
          price
        end
      end)

    case price do
      nil -> 0
      _ -> price
    end
  end

  def epoch(%Block{} = block) do
    div(number(block), Chain.epoch_length())
    # Contract.Registry.epoch(block)
  end

  @spec gas_used(Block.t()) :: non_neg_integer()
  def gas_used(%Block{} = block) do
    Enum.reduce(receipts(block), 0, fn receipt, acc -> acc + receipt.gas_used end)
  end

  @spec gas_fees(Block.t()) :: non_neg_integer()
  def gas_fees(%Block{} = block) do
    Enum.zip(transactions(block), receipts(block))
    |> Enum.map(fn {tx, rcpt} -> Transaction.gas_price(tx) * rcpt.gas_used end)
    |> Enum.sum()
  end

  @spec transaction_receipt(Chain.Block.t(), Chain.Transaction.t()) ::
          Chain.TransactionReceipt.t()
  def transaction_receipt(%Block{} = block, %Transaction{} = tx) do
    Enum.at(receipts(block), transaction_index(block, tx))
  end

  @spec transaction_gas(Chain.Block.t(), Chain.Transaction.t()) :: non_neg_integer()
  def transaction_gas(%Block{} = block, %Transaction{} = tx) do
    transaction_receipt(block, tx).gas_used
  end

  @spec transaction_status(Chain.Block.t(), Chain.Transaction.t()) :: 0 | 1
  def transaction_status(%Block{} = block, %Transaction{} = tx) do
    case transaction_receipt(block, tx).msg do
      :evmc_revert -> 0
      :ok -> 1
      _other -> 0
    end
  end

  @spec transaction_out(Chain.Block.t(), Chain.Transaction.t()) :: binary() | nil
  def transaction_out(%Block{} = block, %Transaction{} = tx) do
    transaction_receipt(block, tx).evmout
  end

  def logs(%Block{} = block) do
    List.zip([transactions(block), receipts(block)])
    |> Enum.map(fn {tx, rcpt} ->
      Enum.map(rcpt.logs, fn log ->
        {address, topics, data} = log

        # Note: truffle is picky on the size of the address, failed before 'Hash.to_address()' call.
        %{
          "transactionIndex" => Block.transaction_index(block, tx),
          "transactionHash" => Transaction.hash(tx),
          "blockHash" => Block.hash(block),
          "blockNumber" => Block.number(block),
          "address" => Hash.to_address(address),
          "data" => data,
          "topics" => topics,
          "type" => "mined"
        }
      end)
    end)
    |> List.flatten()
    |> Enum.with_index(0)
    |> Enum.map(fn {log, idx} ->
      Map.put(log, "logIndex", idx)
    end)
  end

  @spec increment_nonce(Chain.Block.t()) :: Chain.Block.t()
  def increment_nonce(%Block{header: header} = block) do
    %{block | header: %{header | nonce: nonce(block) + 1}}
  end

  @spec set_timestamp(Chain.Block.t(), integer()) :: Chain.Block.t()
  def set_timestamp(%Block{header: header} = block, timestamp) do
    %{block | header: %{header | timestamp: timestamp}}
  end

  @doc """
    export removes additional internal field in the block record
    and prepares it for export through public apis or to the disk
  """
  @spec export(Chain.Block.t()) :: Chain.Block.t()
  def export(block) do
    %{strip_state(block) | coinbase: nil, receipts: []}
  end

  @spec strip_state(Chain.Block.t()) :: Chain.Block.t()
  def strip_state(block) do
    %{block | header: Header.strip_state(block.header)}
  end

  def printable(nil) do
    "nil"
  end

  def printable(block) do
    author = Wallet.words(Block.miner(block))

    prefix =
      case Block.hash(block) do
        nil -> "nil"
        other -> binary_part(other, 0, 5) |> Base16.encode(false)
      end

    len = length(transactions(block))
    "##{Block.number(block)}[#{prefix}](#{len} TX) @#{author}"
  end

  def blockquick_window(block, parent \\ nil)

  def blockquick_window(%Block{header: %Header{number: num}}, _) when num <= 100 do
    [
      598_746_696_357_369_325_966_849_036_647_255_306_831_025_787_168,
      841_993_309_363_539_165_963_431_397_261_483_173_734_566_208_300,
      1_180_560_991_557_918_668_394_274_720_728_086_333_958_947_256_920
    ]
    |> List.duplicate(34)
    |> List.flatten()
    |> Enum.take(100)
  end

  def blockquick_window(%Block{} = block, parent) do
    [_ | window] = parent(block, parent) |> BlockCache.blockquick_window()
    window ++ [Block.coinbase(block)]
  end

  def blockquick_scores(%Block{} = block) do
    BlockCache.blockquick_window(block)
    |> Enum.reduce(%{}, fn coinbase, scores ->
      Map.update(scores, coinbase, 1, fn i -> i + 1 end)
    end)
  end

  @spec is_diverse?(non_neg_integer(), Chain.Block.t(), nil | Chain.Block.t()) :: boolean
  def is_diverse?(0, _block, _parent) do
    true
  end

  def is_diverse?(1, %Block{} = block, parent) do
    parent = parent(block, parent)

    miners =
      blockquick_window(block, parent)
      |> Enum.reverse()
      |> Enum.take(4)

    case miners do
      [a, a, a, a] -> false
      _other -> true
    end
  end

  # Hash of block 108
  # @anchor_hash <<0, 0, 98, 184, 252, 38, 6, 88, 88, 30, 209, 143, 24, 89, 71, 244, 92, 85, 98, 72,
  #                89, 223, 184, 74, 232, 251, 127, 33, 26, 134, 11, 117>>
  @spec last_final(Chain.Block.t(), Chain.Block.t() | nil) :: Chain.Block.t()
  def last_final(block, parent \\ nil)

  def last_final(%Block{header: %Header{number: number}} = block, _) when number < 1 do
    block
  end

  def last_final(%Block{} = block, parent) do
    parent = parent(block, parent)
    prev_final = BlockCache.last_final(parent)
    window = blockquick_scores(prev_final)

    threshold = div(Chain.window_size(), 2)

    gap = Block.number(block) - Block.number(prev_final)

    miners =
      blockquick_window(block, parent)
      |> Enum.reverse()
      |> Enum.take(gap)

    # Iterating in reverse to find the most recent match
    ret =
      Enum.reduce_while(miners, %{}, fn miner, scores ->
        if Map.values(scores) |> Enum.sum() > threshold do
          {:halt, block}
        else
          {:cont, Map.put(scores, miner, Map.get(window, miner, 0))}
        end
      end)

    case ret do
      new_final = %Block{} ->
        new_final

      _too_low_scores ->
        prev_final
    end
  end

  @spec miner(Chain.Block.t()) :: Wallet.t()
  def miner(%Block{coinbase: nil, header: header}) do
    Header.recover_miner(header)
  end

  def miner(%Block{coinbase: coinbase, header: header}) do
    case Wallet.pubkey(coinbase) do
      {:ok, _pub} -> coinbase
      {:error, nil} -> Header.recover_miner(header)
    end
  end

  @spec coinbase(Chain.Block.t()) :: non_neg_integer
  def coinbase(block = %Block{}) do
    miner(block) |> Wallet.address!() |> :binary.decode_unsigned()
  end

  @spec gas_limit(Block.t()) :: non_neg_integer()
  def gas_limit(%Block{} = _block) do
    Chain.gas_limit()
  end

  #########################################################
  ###### FUNCTIONS BELOW THIS LINE ARE STILL JUNK #########
  #########################################################

  @spec size(Block.t()) :: non_neg_integer()
  def size(%Block{} = block) do
    # TODO, needs fixed external format
    byte_size(:erlang.term_to_binary(export(block)))
  end

  @spec logs_bloom(Block.t()) :: <<_::528>>
  def logs_bloom(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  @spec extra_data(Block.t()) :: <<_::528>>
  def extra_data(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end

  @spec receipts_root(Block.t()) :: <<_::528>>
  def receipts_root(%Block{} = _block) do
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  end
end
