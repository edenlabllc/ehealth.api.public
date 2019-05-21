defmodule Core.LegalEntities.V2.LegalEntityCreator do
  @moduledoc false

  alias Core.Employees
  alias Core.Employees.Employee
  alias Core.LegalEntities
  alias Core.LegalEntities.EdrData
  alias Core.LegalEntities.LegalEntity
  alias Core.LegalEntities.LegalEntityCreator
  alias Core.LegalEntities.License
  alias Core.PRMRepo
  alias Core.V2.LegalEntities, as: V2LegalEntities
  alias Core.ValidationError
  alias Core.Validators.Error
  alias Ecto.UUID
  alias Scrivener.Page
  import Core.API.Helpers.Connection, only: [get_consumer_id: 1, get_client_id: 1, get_header: 2]
  import Ecto.Query

  @status_active LegalEntity.status(:active)

  @type_primary_care LegalEntity.type(:primary_care)
  @type_msp LegalEntity.type(:msp)

  @read_prm_repo Application.get_env(:core, :repos)[:read_prm_repo]
  @rpc_edr_worker Application.get_env(:core, :rpc_edr_worker)

  def get_or_create(params, legal_entity_code, headers) do
    params = Map.put(params, "addresses", [params["residence_address"]])
    consumer_id = get_consumer_id(headers)
    client_id = get_client_id(headers)
    edrpou = Map.fetch!(params, "edrpou")
    type = Map.fetch!(params, "type")
    edr_data_header = get_header(headers, "edr-data")

    case get_legal_entities(type, edrpou, @status_active) do
      %Page{entries: []} ->
        new_legal_entity(legal_entity_code, params, consumer_id, client_id, edr_data_header)

      %Page{entries: [%LegalEntity{edr_data: %EdrData{} = edr_data} = legal_entity]} ->
        with :ok <- validate_employee_owner(legal_entity.id, params),
             {:ok, response} <- get_legal_entity_from_edr(edr_data.edr_id) do
          data = %{
            "name" => response["names"]["name"],
            "short_name" => response["names"]["short"],
            "public_name" => response["names"]["display"],
            "legal_form" => response["olf_code"],
            "kveds" => response["activity_kinds"],
            "registration_address" => response["address"],
            "state" => response["state"],
            "updated_by" => consumer_id
          }

          state = suspend_legal_entities(%LegalEntityCreator{}, response, edr_data, consumer_id)

          state = %{
            state
            | updates: [
                fn ->
                  edr_data
                  |> EdrData.changeset(data)
                  |> PRMRepo.update()
                end
              ]
          }

          update_changeset(
            %{state | legal_entity: %{legal_entity | edr_data_id: edr_data.id}},
            params,
            consumer_id
          )
        end

      _ ->
        new_legal_entity(legal_entity_code, params, consumer_id, client_id, edr_data_header)
    end
  end

  defp validate_employee_owner(legal_entity_id, params) do
    case params["owner"]["employee_id"] do
      nil ->
        :ok

      employee_id ->
        with %Employee{} = employee <- Employees.get_by_id(employee_id),
             {_, true} <- {:legal_entity, employee.legal_entity_id == legal_entity_id},
             {_, true} <- {:type, employee.employee_type in [Employee.type(:owner), Employee.type(:pharmacy_owner)]},
             {_, true} <- {:status, employee.status == Employee.status(:approved) && employee.is_active} do
          :ok
        else
          {:status, _} ->
            {:error, {:conflict, "Invalid employee status"}}

          {:type, _} ->
            {:error, {:conflict, "Invalid employee type"}}

          {:legal_entity, _} ->
            {:error, {:conflict, "Employee doesn't belong to your legal entity"}}

          nil ->
            Error.dump(%ValidationError{
              description: "Employee not found",
              path: "$.owner.employee_id"
            })
        end
    end
  end

  defp get_legal_entities(@type_primary_care, edrpou, status) do
    LegalEntity
    |> where([le], le.type in [@type_primary_care, @type_msp])
    |> where([le], le.edrpou == ^edrpou)
    |> where([le], le.status == ^status)
    |> limit(2)
    |> @read_prm_repo.all
  end

  defp get_legal_entities(type, edrpou, status) do
    LegalEntity
    |> where([le], le.type == ^type)
    |> where([le], le.edrpou == ^edrpou)
    |> where([le], le.status == ^status)
    |> limit(2)
    |> @read_prm_repo.all
  end

  defp new_changeset(
         %LegalEntityCreator{legal_entity: legal_entity} = state,
         attrs,
         consumer_id,
         client_id
       ) do
    creation_data =
      attrs
      |> Map.merge(%{
        "status" => @status_active,
        "is_active" => true,
        "inserted_by" => consumer_id,
        "updated_by" => consumer_id,
        "created_by_mis_client_id" => client_id,
        "nhs_verified" => false,
        "nhs_reviewed" => false,
        "edr_verified" => nil
      })

    %{
      state
      | inserts:
          state.inserts ++
            [
              fn -> V2LegalEntities.create(legal_entity, creation_data, consumer_id) end,
              fn ->
                %License{}
                |> License.changeset(
                  Map.merge(attrs["license"], %{
                    "inserted_by" => consumer_id,
                    "updated_by" => consumer_id,
                    "type" => creation_data["type"]
                  })
                )
                |> PRMRepo.insert_and_log(consumer_id)
              end
            ]
    }
  end

  def update_changeset(
        %LegalEntityCreator{legal_entity: legal_entity} = state,
        attrs,
        consumer_id
      ) do
    update_data =
      attrs
      |> Map.delete("edrpou")
      |> Map.merge(%{
        "updated_by" => consumer_id,
        "is_active" => true,
        "nhs_verified" => false,
        "nhs_reviewed" => false,
        "edr_verified" => nil
      })

    state =
      case legal_entity.license do
        %License{} = license ->
          %{
            state
            | updates: [
                fn ->
                  license
                  |> License.changeset(Map.merge(attrs["license"], %{"updated_by" => consumer_id}))
                  |> PRMRepo.update_and_log(consumer_id)
                end
                | state.updates
              ]
          }

        _ ->
          %{
            state
            | inserts:
                state.inserts ++
                  [
                    fn ->
                      %License{}
                      |> License.changeset(
                        Map.merge(attrs["license"], %{
                          "type" => legal_entity.type,
                          "inserted_by" => consumer_id,
                          "updated_by" => consumer_id
                        })
                      )
                      |> PRMRepo.insert_and_log(consumer_id)
                    end
                  ]
          }
      end

    changes = V2LegalEntities.changeset(legal_entity, update_data)
    %{state | updates: [fn -> PRMRepo.update_and_log(changes, consumer_id) end | state.updates]}
  end

  def suspend_legal_entities(%LegalEntityCreator{} = state, edr_response, edr_data, consumer_id) do
    if edr_data.state == 1 && edr_response["state"] != 1 do
      %{
        state
        | update_all: [
            fn ->
              edr_data_id = edr_data.id

              LegalEntity
              |> where([le], le.edr_data_id == ^edr_data_id)
              |> PRMRepo.update_all(
                set: [status: LegalEntity.status(:suspended), updated_by: consumer_id, updated_at: DateTime.utc_now()]
              )
            end
          ]
      }
    else
      state
    end
  end

  defp new_legal_entity(legal_entity_code, params, consumer_id, client_id, edr_data_header) do
    state = %LegalEntityCreator{legal_entity: %LegalEntity{id: UUID.generate()}}

    with %LegalEntityCreator{} = state <- upsert_edr_data(state, legal_entity_code, consumer_id, edr_data_header) do
      new_changeset(
        state,
        params,
        consumer_id,
        client_id
      )
    end
  end

  def upsert_edr_data(%LegalEntityCreator{} = state, %{edrpou: value}, consumer_id, edr_data_header) do
    do_upsert_edr_data(state, value, consumer_id, edr_data_header)
  end

  def upsert_edr_data(%LegalEntityCreator{} = state, %{drfo: value}, consumer_id, edr_data_header) do
    do_upsert_edr_data(state, value, consumer_id, edr_data_header)
  end

  def do_upsert_edr_data(state, value, consumer_id, edr_data_header) do
    with {:ok, items} <- search_edr_legal_entities(value, edr_data_header) do
      active_items =
        Enum.reduce(items, 0, fn item, acc ->
          if item["state"] == 1 do
            acc + 1
          else
            acc
          end
        end)

      cond do
        active_items > 1 ->
          Error.dump(%ValidationError{
            description: "More than 1 active entities in EDR",
            path: "$.data.edrpou"
          })

        active_items == 1 ->
          case validate_inactive_edr_data(items) do
            :ok ->
              item = Enum.find(items, &(Map.get(&1, "state") == 1))

              with {:ok, response} <- get_legal_entity_from_edr(item["id"]) do
                data = %{
                  "edrpou" => value,
                  "edr_id" => response["id"],
                  "name" => response["names"]["name"],
                  "short_name" => response["names"]["short"],
                  "public_name" => response["names"]["display"],
                  "legal_form" => response["olf_code"],
                  "kveds" => response["activity_kinds"],
                  "registration_address" => response["address"],
                  "state" => response["state"],
                  "updated_by" => consumer_id
                }

                save_edr_data(state, data, consumer_id)
              end

            error ->
              error
          end

        true ->
          Error.dump(%ValidationError{
            description: "Provided EDRPOU is not active in EDR",
            path: "$.data.edrpou"
          })
      end
    end
  end

  defp search_edr_legal_entities(value, edr_data_header) do
    if Confex.fetch_env!(:core, :legal_entity_edr_verify) do
      cond do
        Regex.match?(~r/^[0-9]{8,10}$/, value) ->
          case @rpc_edr_worker.run("edr_api", EdrApi.Rpc, :search_legal_entity, [%{code: value}]) do
            {:ok, response} -> {:ok, response}
            {:error, _} -> {:error, {:conflict, "Legal Entity not found in EDR"}}
          end

        Regex.match?(~r/^((?![ЫЪЭЁ])([А-ЯҐЇІЄ])){2}[0-9]{6}$/u, value) ->
          case @rpc_edr_worker.run("edr_api", EdrApi.Rpc, :search_legal_entity, [%{passport: value}]) do
            {:ok, response} -> {:ok, response}
            {:error, _} -> {:error, {:conflict, "Legal Entity not found in EDR"}}
          end

        true ->
          Error.dump(%ValidationError{
            description: "Invalid edrpou",
            path: "$.data.edrpou"
          })
      end
    else
      {:ok, Jason.decode!(edr_data_header)}
    end
  end

  defp get_legal_entity_from_edr(id) do
    case @rpc_edr_worker.run("edr_api", EdrApi.Rpc, :get_legal_entity_detailed_info, [id]) do
      {:ok, response} -> {:ok, response}
      {:error, _} -> {:error, {:conflict, "Legal Entity not found in EDR"}}
    end
  end

  defp save_edr_data(%LegalEntityCreator{legal_entity: legal_entity} = state, data, consumer_id) do
    case @read_prm_repo.get_by(EdrData, %{edr_id: data["edr_id"]}) do
      %EdrData{} = edr_data ->
        %{
          state
          | legal_entity: %{legal_entity | edr_data_id: edr_data.id},
            updates: [
              fn ->
                edr_data
                |> EdrData.changeset(data)
                |> PRMRepo.update()
              end
              | state.updates
            ]
        }

      _ ->
        data =
          Map.merge(data, %{
            "inserted_by" => consumer_id,
            "id" => UUID.generate()
          })

        %{
          state
          | legal_entity: %{legal_entity | edr_data_id: data["id"]},
            inserts: [
              fn ->
                %EdrData{}
                |> EdrData.changeset(data)
                |> PRMRepo.insert()
              end
              | state.inserts
            ]
        }
    end
  end

  defp validate_inactive_edr_data(items) do
    items
    |> Enum.filter(&(Map.get(&1, "state") != 1))
    |> Enum.reduce_while(:ok, fn item, acc ->
      case PRMRepo.get_by(EdrData, %{edr_id: item["id"]}) do
        %EdrData{} = edr_data ->
          check_existing_legal_entities(LegalEntities.active_by_edr_data_id(edr_data.id), acc)

        _ ->
          {:cont, acc}
      end
    end)
  end

  defp check_existing_legal_entities(legal_entities, acc) do
    if Enum.empty?(legal_entities) do
      {:cont, acc}
    else
      {:halt,
       Error.dump(%ValidationError{
         description: "Legal entity with such edrpou and type already exists",
         path: "$.data.edrpou"
       })}
    end
  end
end
