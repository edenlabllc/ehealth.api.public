defmodule EHealth.Divisions.API do
  @moduledoc """
  The boundary for the Divisions system.
  """
  use JValid

  import Ecto.Changeset, warn: false

  alias EHealth.API.PRM
  alias EHealth.API.UAddress
  alias EHealth.Utils.ValidationSchemaMapper

  use_schema :division, "specs/json_schemas/division_schema.json"

  @default_mountain_group "0"

  def search(legal_entity_id, params \\ %{}, headers \\ []) do
    params
    |> Map.put("legal_entity_id", legal_entity_id)
    |> PRM.get_divisions(headers)
  end

  def get_by_id(legal_entity_id, id, headers) do
    id
    |> PRM.get_division_by_id(headers)
    |> validate_legal_entity(legal_entity_id)
  end

  def create(legal_entity_id, params, headers) do
    params
    |> prepare_division_data(legal_entity_id)
    |> create_division(headers)
  end

  def update(legal_entity_id, id, params, headers) do
    case prepare_division_data(params, legal_entity_id) do
      {:ok, data} ->
        legal_entity_id
        |> get_by_id(id, headers)
        |> update_division(data, headers)

      err -> err
    end
  end

  def prepare_division_data(params, legal_entity_id) do
    params
    |> Map.delete("id")
    |> Map.put("legal_entity_id", legal_entity_id)
    |> validate_division()
    |> put_mountain_group()
  end

  def update_status(legal_entity_id, id, status, headers) do
    legal_entity_id
    |> get_by_id(id, headers)
    |> update_division(%{"status" => status}, headers)
  end

  def create_division({:ok, data}, headers) do
    data
    |> Map.put("is_active", true)
    |> PRM.create_division(headers)
  end
  def create_division(err, _headers), do: err

  def update_division({:ok, %{"data" => division}}, data, headers) do
    data
    |> Map.put("is_active", true)
    |> PRM.update_division(Map.fetch!(division, "id"), headers)
  end
  def update_division(err, _data, _headers), do: err

  def validate_division(data) do
    schema =
      @schemas
      |> Keyword.get(:division)
      |> ValidationSchemaMapper.prepare_divisions_schema()

    case validate_schema(schema, data) do
      :ok -> {:ok, data}
      err -> err
    end
  end

  def put_mountain_group({:ok, %{"addresses" => addresses} = division}) do
    settlement_id =
      addresses
      |> List.first()
      |> Map.fetch!("settlement_id")

    %{"settlement_id" => settlement_id}
    |> UAddress.search_settlements()
    |> put_mountain_group(division)
  end

  def put_mountain_group(err), do: err

  def put_mountain_group({:ok, %{"data" => addresses}}, division) when length(addresses) > 0 do
    mountain_group =
      addresses
      |> List.first()
      |> Map.get("mountain_group", @default_mountain_group)

    {:ok, Map.put(division, "mountain_group", mountain_group)}
  end

  def put_mountain_group({:ok, _}, division) do
    {:ok, Map.put(division, "mountain_group", @default_mountain_group)}
  end

  def put_mountain_group(err, _division), do: err

  def validate_legal_entity({:ok, %{"data" => division}} = resp, legal_entity_id) do
    case legal_entity_id == Map.fetch!(division, "legal_entity_id") do
      true -> resp
      false -> {:error, :access_denied}
    end
  end
  def validate_legal_entity(err, _legal_entity_id), do: err
end
