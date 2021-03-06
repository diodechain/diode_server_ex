# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule KBuckets do
  @moduledoc """
  Provides 256 bits k-buckets for hashes
  """
  alias Object.Server, as: Server
  import Wallet

  defmodule Item do
    defstruct node_id: nil, last_seen: nil, object: nil, retries: 0

    def disabled?(item, now \\ System.os_time(:second)) do
      item.last_seen > now
    end
  end

  defimpl String.Chars, for: Item do
    def to_string(item) do
      String.Chars.to_string(Map.from_struct(item))
    end
  end

  @type item :: %Item{
          node_id: Wallet.t(),
          last_seen: integer,
          object: Server.server() | :self,
          retries: any()
        }

  @type item_id :: <<_::256>>
  @type node_id :: Wallet.t()
  @type tree :: {:leaf, any(), map()} | {:node, any(), tree(), tree()}
  @type kbuckets :: {:kbucket, any(), tree() | nil}

  @k 20
  @zero <<0::size(1)>>
  @one <<1::size(1)>>

  @spec new(node_id()) :: kbuckets()
  def new(self_id = wallet()) do
    {:kbucket, self_id,
     {:leaf, "",
      %{
        key(self_id) => self({:kbucket, self_id, nil})
      }}}
  end

  @spec self(kbuckets()) :: item()
  def self({:kbucket, self_id, _tree}) do
    %Item{node_id: self_id, last_seen: -1, object: :self}
  end

  def object(%Item{object: :self}) do
    Diode.self()
  end

  def object(%Item{object: server}) do
    server
  end

  @spec to_uri(item()) :: binary()
  def to_uri(item) do
    server = object(item)
    host = Server.host(server)
    port = Server.peer_port(server)
    "diode://#{item.node_id}@#{host}:#{port}"
  end

  @spec size(kbuckets()) :: non_neg_integer()
  def size({:kbucket, _self_id, tree}) do
    do_size(tree)
  end

  defp do_size({:leaf, _prefix, bucket}) do
    map_size(bucket)
  end

  defp do_size({:node, _prefix, zero, one}) do
    do_size(zero) + do_size(one)
  end

  @spec bucket_count(kbuckets()) :: pos_integer()
  def bucket_count({:kbucket, _self_id, tree}) do
    do_bucket_count(tree)
  end

  defp do_bucket_count({:leaf, _prefix, _bucket}) do
    1
  end

  defp do_bucket_count({:node, _prefix, zero, one}) do
    do_bucket_count(zero) + do_bucket_count(one)
  end

  @spec to_list(kbuckets() | [item()]) :: [item()]
  def to_list({:kbucket, _self_id, tree}) do
    do_to_list(tree)
  end

  def to_list(list) when is_list(list) do
    list
  end

  defp do_to_list({:leaf, _prefix, bucket}) do
    Map.values(bucket)
  end

  defp do_to_list({:node, _prefix, zero, one}) do
    do_to_list(zero) ++ do_to_list(one)
  end

  @doc """
    nearer_n finds the n nodes nearer or equal to the current node to the provided item.
  """
  @spec nearer_n(kbuckets() | [item()], item() | item_id(), pos_integer()) :: [item()]
  def nearer_n({:kbucket, self, _tree} = kbuckets, item, n) do
    min_dist = distance(self, item)

    nearest_n(kbuckets, item, n)
    |> Enum.filter(fn a -> distance(a, item) <= min_dist end)
  end

  @doc """
    nearest_n finds the n nodes nearer or equal to the current node to the provided item.
  """
  def nearest_n(kb, item, n) do
    to_list(kb)
    |> Enum.sort(fn a, b -> distance(item, a) < distance(item, b) end)
    |> Enum.take(n)
  end

  @doc """
    to_ring_list returns a list ordered in ring order, excluding the current element but
    starting at it's position, not at ring position 0.
  """
  def to_ring_list(kb = {:kbucket, self, _tree}, nil) do
    to_ring_list(kb, self)
  end

  def to_ring_list(kb, item) do
    key = integer(item)

    {pre, post} =
      to_list(kb)
      |> Enum.reject(fn a -> integer(a) == key end)
      |> Enum.sort(fn a, b -> integer(a) < integer(b) end)
      |> Enum.split_while(fn a -> integer(a) < key end)

    post ++ pre
  end

  @doc """
    next_n returns the n next nodes in clockwise order on the ring.
  """
  def next_n(kb, item \\ nil, n) do
    to_ring_list(kb, item)
    |> Enum.take(n)
  end

  @doc """
    prev_n returns the n previous nodes in counter-clockwise order on the ring.
  """
  def prev_n(kb, item \\ nil, n) do
    to_ring_list(kb, item)
    |> Enum.reverse()
    |> Enum.take(n)
  end

  def unique(list) when is_list(list) do
    Enum.reduce(list, %{}, fn node, acc ->
      Map.put(acc, key(node), node)
    end)
    |> Map.values()
  end

  @doc """
    Calculates the linear distance on a geometric ring from 0 to 2^256 any distance.
    Because it's a ring the maximal distance is two points being opposite of each
    other. In that case the distance is 2^255.

    2^256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    2^255 = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

  """
  def distance(a, b) do
    dist = abs(integer(a) - integer(b))

    if dist > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF do
      0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF - dist
    else
      dist
    end
  end

  defp hash(data) do
    Diode.hash(data)
  end

  @spec key(item_id() | node_id() | KBuckets.Item.t()) :: item_id()
  def key(wallet() = w) do
    hash(Wallet.address!(w))
  end

  def key(%Item{node_id: wallet() = w}) do
    key(w)
  end

  def key(<<key::bitstring-size(256)>>) do
    key
  end

  def do_nearest_n({:leaf, _prefix, bucket}, _key, _n) do
    now = System.os_time(:second)

    # Filtering items that had a connection failure through
    # Kademlia.cast. 'last_seen' in the future means "should
    # not be used again before"
    Map.values(bucket)
    |> Enum.reject(fn item -> KBuckets.Item.disabled?(item, now) end)
  end

  def do_nearest_n({:node, prefix, zero, one}, key, n) do
    x = bit_size(prefix)

    {far, near} =
      case key do
        <<^prefix::bitstring-size(x), @zero::bitstring, _::bitstring>> ->
          {one, zero}

        <<^prefix::bitstring-size(x), @one::bitstring, _::bitstring>> ->
          {zero, one}
      end

    result = do_nearest_n(near, key, n)

    if length(result) < n do
      result ++ Enum.take(do_to_list(far), n - length(result))
    else
      result
    end
  end

  @spec delete_item(kbuckets(), item() | item_id()) :: kbuckets()
  def delete_item({:kbucket, self_id, tree}, item) do
    key = key(item)

    tree =
      update_bucket(tree, key, fn {:leaf, prefix, bucket} ->
        {:leaf, prefix, Map.delete(bucket, key)}
      end)

    {:kbucket, self_id, tree}
  end

  @spec update_item(kbuckets(), item() | item_id()) :: kbuckets()
  def update_item({:kbucket, self_id, tree}, item) do
    key = key(item)

    tree =
      update_bucket(tree, key, fn {:leaf, prefix, bucket} ->
        if Map.has_key?(bucket, key) do
          {:leaf, prefix, Map.put(bucket, key, item)}
        else
          {:leaf, prefix, bucket}
        end
      end)

    {:kbucket, self_id, tree}
  end

  @spec member?(kbuckets(), item() | item_id()) :: boolean()
  def member?(kb, item_id) do
    item(kb, item_id) != nil
  end

  # Return an item for the given wallet address
  @spec item(kbuckets(), item() | item_id()) :: item() | nil
  def item(kb, item_id) do
    key = key(item_id)

    case nearest_n(kb, key, 1) do
      [ret] ->
        if key(ret) == key do
          ret
        else
          nil
        end

      [] ->
        nil
    end
  end

  @spec insert_item(kbuckets(), item() | item_id()) :: kbuckets()
  def insert_item({:kbucket, self_id, tree}, item) do
    {:kbucket, self_id, do_insert_item(tree, item)}
  end

  @spec insert_items(kbuckets(), [item()]) :: kbuckets()
  def insert_items({:kbucket, self_id, tree}, items) do
    tree =
      Enum.reduce(items, tree, fn item, acc ->
        do_insert_item(acc, item)
      end)

    {:kbucket, self_id, tree}
  end

  defp do_insert_item(tree, item) do
    key = key(item)

    update_bucket(tree, key, fn orig ->
      {:leaf, prefix, bucket} = orig
      bucket = Map.put(bucket, key, item)

      if map_size(bucket) < @k do
        {:leaf, prefix, bucket}
      else
        if is_self(bucket) do
          new_node =
            {:node, prefix, {:leaf, <<prefix::bitstring, @zero::bitstring>>, %{}},
             {:leaf, <<prefix::bitstring, @one::bitstring>>, %{}}}

          Enum.reduce(bucket, new_node, fn {_, node}, acc ->
            do_insert_item(acc, node)
          end)
        else
          # ignoring the item
          orig
        end
      end
    end)
  end

  defp update_bucket({:node, prefix, zero, one}, key, fun) do
    x = bit_size(prefix)

    case key do
      <<^prefix::bitstring-size(x), @zero::bitstring, _::bitstring>> ->
        {:node, prefix, update_bucket(zero, key, fun), one}

      <<^prefix::bitstring-size(x), @one::bitstring, _::bitstring>> ->
        {:node, prefix, zero, update_bucket(one, key, fun)}
    end
  end

  defp update_bucket({:leaf, prefix, bucket}, _key, fun) do
    fun.({:leaf, prefix, bucket})
  end

  @spec k() :: integer()
  def k() do
    @k
  end

  def is_self(%Item{object: :self}) do
    true
  end

  def is_self(%Item{node_id: node_id}) do
    Wallet.equal?(node_id, Diode.miner())
  end

  def is_self(bucket) do
    Enum.any?(bucket, fn {_, item} -> is_self(item) end)
  end

  def integer(<<x::integer-size(256)>>) do
    x
  end

  def integer(item) do
    integer(key(item))
  end
end
