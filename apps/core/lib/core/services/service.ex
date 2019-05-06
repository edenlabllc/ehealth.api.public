defmodule Core.Services.Service do
  @moduledoc false

  use Ecto.Schema
  alias Ecto.UUID

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "services" do
    field(:code, :string)
    field(:name, :string)
    field(:is_active, :boolean)
    field(:parent_id, UUID)
    field(:category, :string)
    field(:is_composition, :boolean)
    field(:request_allowed, :boolean)
    field(:inserted_by, UUID)
    field(:updated_by, UUID)

    timestamps(type: :utc_datetime_usec)
  end
end
