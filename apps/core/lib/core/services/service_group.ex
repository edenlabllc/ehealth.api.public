defmodule Core.Services.ServiceGroup do
  @moduledoc false

  use Ecto.Schema

  alias Core.Services.Service
  alias Ecto.UUID

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "service_groups" do
    field(:code, :string)
    field(:name, :string)
    field(:is_active, :boolean)
    field(:request_allowed, :boolean)
    field(:inserted_by, UUID)
    field(:updated_by, UUID)

    belongs_to(:parent_group, __MODULE__, foreign_key: :parent_id, type: UUID)
    has_many(:sub_groups, __MODULE__, foreign_key: :parent_id)
    many_to_many(:services, Service, join_through: "services_groups")

    timestamps(type: :utc_datetime_usec)
  end
end
