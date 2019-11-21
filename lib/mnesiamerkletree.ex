# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule MnesiaMerkleTree do
  @moduledoc """
  1st Concept is to reuse same mnesia storage rows when keeping multiple trees.
  2nd Concept is to offer a O(1) lookup based on keys for the "top" tree.
  """
  # Key / Value Store
  @type key_type :: binary() | integer()
  @type value_type :: term()

  @type item :: {key_type(), value_type()}
  @type hash_type :: <<_::256>>

  @type proof_type :: {proof_type, proof_type} | [any()]

  @type mnesia_key :: binary()
  @type hash_count :: {[binary()], non_neg_integer()}
  @type tree_leaf :: {:leaf, hash_count() | nil, binary(), map()}
  @type tree_node :: {:node, hash_count() | nil, binary(), tree(), tree()}
  @type tree :: tree_leaf() | tree_node() | mnesia_key()
  @type merkle :: {__MODULE__, %{}, mnesia_key()}

  @spec new() :: merkle()
  def new() do
    {:atomic, ret} =
      :mnesia.transaction(fn ->
        tree = update_merkle_hash_count({:leaf, nil, "", %{}})
        {__MODULE__, %{}, to_key(tree)}
      end)

    ret
  end

  def restore(mnesia_key) do
    case :mnesia.dirty_read(:mtree, mnesia_key) do
      [{:mtree, ^mnesia_key, tree}] -> {:ok, {__MODULE__, %{}, tree}}
      [] -> {:error, :not_found}
    end
  end

  @spec root_hash(merkle()) :: hash_type()
  def root_hash(merkle) do
    root_hashes(merkle)
    |> signature()
  end

  @spec root_hashes(merkle()) :: [hash_type()]
  def root_hashes({__MODULE__, _options, tree}) do
    update_merkle_hash_count(tree)
    |> merkle_hashes()
  end

  @spec get_proofs(merkle(), key_type()) :: proof_type()
  def get_proofs({__MODULE__, _options, tree}, key) do
    bkey = to_binary(key)
    do_get_proofs(tree, bkey, hash(bkey))
  end

  @spec get(merkle(), key_type()) :: value_type()
  def get({__MODULE__, _options, tree}, key) do
    bkey = to_binary(key)
    do_get(tree, bkey, hash(bkey))
  end

  @spec size(merkle()) :: non_neg_integer()
  def size({__MODULE__, _options, tree}) do
    do_size(tree)
  end

  @spec bucket_count(merkle()) :: pos_integer()
  def bucket_count({__MODULE__, _options, tree}) do
    do_bucket_count(tree)
  end

  @spec to_list(merkle()) :: [item()]
  def to_list({__MODULE__, _options, tree}) do
    do_to_list(tree)
  end

  @spec delete(merkle(), key_type()) :: merkle()
  def delete({__MODULE__, options, tree}, key) do
    bkey = to_binary(key)

    {:atomic, tree} =
      :mnesia.transaction(fn ->
        update_bucket(tree, hash(bkey), fn {:leaf, _hash_count, prefix, bucket} ->
          {:leaf, nil, prefix, Map.delete(bucket, bkey)}
        end)
        |> update_merkle_hash_count()
        |> to_key()
      end)

    {__MODULE__, options, tree}
  end

  @spec member?(merkle(), key_type()) :: boolean()
  def member?(tree, key) do
    nil != get(tree, key)
  end

  @spec insert(merkle(), key_type(), value_type()) :: merkle()
  def insert(tree, key, value) do
    insert_items(tree, [{key, value}])
  end

  @spec insert_item(merkle(), item()) :: merkle()
  def insert_item(tree, item) do
    insert_items(tree, [item])
  end

  @spec insert_items(merkle(), [item()]) :: merkle()
  def insert_items({__MODULE__, options, tree}, items) do
    {:atomic, tree} =
      :mnesia.transaction(fn ->
        Enum.reduce(items, tree, fn {key, value}, acc ->
          bkey = to_binary(key)

          update_bucket(acc, hash(bkey), fn {:leaf, _hash_count, prefix, bucket} ->
            bucket =
              case to_binary(value) do
                <<0::unsigned-size(256)>> -> Map.delete(bucket, bkey)
                value -> Map.put(bucket, bkey, value)
              end

            {:leaf, nil, prefix, bucket}
          end)
        end)
        |> update_merkle_hash_count()
        |> to_key()
      end)

    {__MODULE__, options, tree}
  end

  # ========================================================
  # Internal Mnesia Specific
  # ========================================================

  def init() do
    Store.create_table!(:mtree, [:hash, :node])
    Store.create_table!(:mtree_ref_count, [:hash, :count])
  end

  defp to_key(tree) when is_tuple(tree) do
    tree = update_merkle_hash_count(tree)
    mnesia_key = signature(merkle_hashes(tree))

    :ok =
      case :mnesia.read(:mtree, mnesia_key) do
        [{:mtree, ^mnesia_key, ^tree}] -> :ok
        [] -> :mnesia.write({:mtree, mnesia_key, tree})
      end

    incr_key(mnesia_key)
    mnesia_key
  end

  defp from_key(mnesia_key) when is_binary(mnesia_key) do
    [{:mtree, ^mnesia_key, tree}] =
      if :mnesia.is_transaction() do
        :mnesia.read(:mtree, mnesia_key)
      else
        :mnesia.dirty_read(:mtree, mnesia_key)
      end

    tree
  end

  defp incr_key(_mnesia_key) do
    # :mnesia.dirty_update_counter(:mtree_ref_count, mnesia_key, 1)
  end

  defp decr_key(_mnesia_key) do
    # :mnesia.dirty_update_counter(:mtree_ref_count, mnesia_key, -1)
  end

  # ========================================================
  # Internal
  # ========================================================
  @leaf_size 16
  @left <<0::size(1)>>
  @right <<1::size(1)>>

  @spec do_get(tree(), binary(), binary()) :: any()
  defp do_get(mnesia_key, key, hash) when is_binary(mnesia_key) do
    do_get(from_key(mnesia_key), key, hash)
  end

  defp do_get({:node, _hash_count, prefix, left, right}, key, hash) do
    case decide(hash, prefix) do
      true -> do_get(left, key, hash)
      false -> do_get(right, key, hash)
    end
  end

  defp do_get({:leaf, _hash_count, _prefix, bucket}, key, _hash) do
    Map.get(bucket, key)
  end

  @spec do_get_proofs(tree(), binary(), binary()) :: any()
  defp do_get_proofs(mnesia_key, key, hash) when is_binary(mnesia_key) do
    do_get_proofs(from_key(mnesia_key), key, hash)
  end

  defp do_get_proofs({:node, _hash_count, prefix, left, right}, key, hash) do
    case decide(hash, prefix) do
      true -> {do_get_proofs(left, key, hash), merkle_hash(right, hash)}
      false -> {merkle_hash(left, hash), do_get_proofs(right, key, hash)}
    end
  end

  defp do_get_proofs({:leaf, _hash_count, prefix, bucket}, key, _hash) do
    bucket_to_leaf(bucket, prefix, key)
  end

  defp do_size(mnesia_key) when is_binary(mnesia_key) do
    do_size(from_key(mnesia_key))
  end

  defp do_size({:leaf, _hash_count, _prefix, bucket}) do
    map_size(bucket)
  end

  defp do_size({:node, _hash_count, _prefix, left, right}) do
    do_size(left) + do_size(right)
  end

  defp do_bucket_count(mnesia_key) when is_binary(mnesia_key) do
    do_bucket_count(from_key(mnesia_key))
  end

  defp do_bucket_count({:leaf, _hash_count, _prefix, _bucket}) do
    1
  end

  defp do_bucket_count({:node, _hash_count, _prefix, left, right}) do
    do_bucket_count(left) + do_bucket_count(right)
  end

  defp do_to_list(mnesia_key) when is_binary(mnesia_key) do
    do_to_list(from_key(mnesia_key))
  end

  defp do_to_list({:leaf, _hash_count, _prefix, bucket}) do
    Map.to_list(bucket)
  end

  defp do_to_list({:node, _hash_count, _prefix, left, right}) do
    do_to_list(left) ++ do_to_list(right)
  end

  defp hash(value) when is_binary(value) do
    Diode.hash(value)
  end

  @spec key(item()) :: binary()
  defp key({key, _value}) do
    hash(key)
  end

  defp decide(hash, prefix) do
    x = bit_size(prefix)

    case hash do
      <<^prefix::bitstring-size(x), @left::bitstring, _::bitstring>> ->
        true

      <<^prefix::bitstring-size(x), @right::bitstring, _::bitstring>> ->
        false
    end
  end

  @spec update_bucket(tree(), binary(), fun()) :: tree()
  defp update_bucket({:node, _hash_count, prefix, left, right}, key, fun) do
    case decide(key, prefix) do
      true ->
        {:node, nil, prefix, update_bucket(left, key, fun), right}

      false ->
        {:node, nil, prefix, left, update_bucket(right, key, fun)}
    end
  end

  defp update_bucket({:leaf, _hash_count, prefix, bucket}, _key, fun) do
    fun.({:leaf, nil, prefix, bucket})
  end

  defp update_bucket(mnesia_key, key, fun) when is_binary(mnesia_key) do
    decr_key(mnesia_key)
    update_bucket(from_key(mnesia_key), key, fun)
  end

  defp merkle_hash_count(tree) when is_tuple(tree) do
    :erlang.element(2, tree)
  end

  defp merkle_hash_count(mnesia_key) when is_binary(mnesia_key) do
    merkle_hash_count(from_key(mnesia_key))
  end

  defp merkle_hashes(tree) when is_tuple(tree) do
    {hashes, _count} = merkle_hash_count(tree)
    hashes
  end

  defp merkle_hashes(mnesia_key) when is_binary(mnesia_key) do
    merkle_hashes(from_key(mnesia_key))
  end

  defp merkle_hash(tree, hash) do
    hashes = merkle_hashes(tree)
    Enum.at(hashes, hash_to_leafindex(hash))
  end

  defp hash_to_leafindex(hash) do
    <<lastb::unsigned-size(8)>> = binary_part(hash, byte_size(hash), -1)
    rem(lastb, @leaf_size)
  end

  @spec update_merkle_hash_count(tree()) :: tree()
  defp update_merkle_hash_count({:node, nil, prefix, left, right}) do
    left = update_merkle_hash_count(left)
    {hashesl, countl} = merkle_hash_count(left)

    right = update_merkle_hash_count(right)
    {hashesr, countr} = merkle_hash_count(right)

    count = countl + countr
    # Need to merge
    if count <= @leaf_size do
      items = do_to_list({:node, nil, prefix, left, right})

      {:leaf, nil, prefix, Map.new(items)}
      |> update_merkle_hash_count()
    else
      hashes =
        :lists.zipwith(
          fn hashl, hashr ->
            signature([hashl, hashr])
          end,
          hashesl,
          hashesr
        )

      {:node, {hashes, count}, prefix, to_key(left), to_key(right)}
    end
  end

  defp update_merkle_hash_count({:leaf, nil, prefix, bucket}) do
    count = map_size(bucket)
    # Need to split
    if count > @leaf_size do
      {left, right} = Enum.split_with(bucket, fn item -> decide(key(item), prefix) end)

      {:node, nil, prefix, {:leaf, nil, <<prefix::bitstring, @left::bitstring>>, Map.new(left)},
       {:leaf, nil, <<prefix::bitstring, @right::bitstring>>, Map.new(right)}}
      |> update_merkle_hash_count()
    else
      hashes =
        bucket_to_leafes(bucket, prefix)
        |> Enum.map(&signature/1)

      {:leaf, {hashes, count}, prefix, bucket}
    end
  end

  defp update_merkle_hash_count(mnesia_key) when is_binary(mnesia_key) do
    update_merkle_hash_count(from_key(mnesia_key))
  end

  defp update_merkle_hash_count(tree) when is_tuple(tree) do
    tree
  end

  defp bucket_to_leafes(bucket, prefix) do
    l0 =
      Enum.map(1..@leaf_size, fn num ->
        [num - 1, prefix]
      end)

    Enum.reduce(bucket, l0, fn item, list ->
      pos = hash_to_leafindex(key(item))
      value = [item | Enum.at(list, pos)]
      List.replace_at(list, pos, value)
    end)
    |> Enum.map(&Enum.reverse/1)
  end

  defp bucket_to_leaf(bucket, prefix, key) do
    pos = hash_to_leafindex(hash(key))
    l0 = [pos, prefix]

    Enum.reduce(bucket, l0, fn item, list ->
      if hash_to_leafindex(key(item)) == pos do
        [item | list]
      else
        list
      end
    end)
    |> Enum.reverse()
  end

  defp signature(list) when is_list(list) do
    hash(BertExt.encode!(list))
  end

  defp to_binary(binary) when is_binary(binary) do
    binary
  end

  defp to_binary(int) when is_integer(int) do
    <<int::unsigned-size(256)>>
  end
end