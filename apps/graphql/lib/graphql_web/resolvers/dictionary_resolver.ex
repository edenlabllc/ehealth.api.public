defmodule GraphQLWeb.Resolvers.DictionaryResolver do
  @moduledoc false

  import GraphQLWeb.Resolvers.Helpers.Search, only: [filter: 2]

  alias Absinthe.Relay.Connection
  alias Core.Dictionaries
  alias Core.Dictionaries.Dictionary
  alias Core.Repo

  def list_dictionaries(%{filter: filter} = args, _resolution) do
    filter = prepare_filter(filter)

    Dictionary
    |> filter(filter)
    |> Connection.from_query(&Repo.all/1, args)
  end

  defp prepare_filter([]), do: []

  defp prepare_filter([{:label, value} | tail]) do
    [{:label, {:fragment, {:contain, :labels, [value]}}} | prepare_filter(tail)]
  end

  defp prepare_filter([{:name, value} | tail]) do
    [{:name, {:ilike, "%#{value}%"}} | prepare_filter(tail)]
  end

  defp prepare_filter([head | tail]), do: [head | prepare_filter(tail)]

  def create_or_update(%{name: name} = args, _resolution) do
    with {:ok, %Dictionary{} = dictionary} <- Dictionaries.create_or_update_dictionary(name, args) do
      {:ok, %{dictionary: dictionary}}
    end
  end
end