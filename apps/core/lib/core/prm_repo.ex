defmodule Core.PRMRepo do
  @moduledoc false

  use Ecto.Repo, otp_app: :core, adapter: Ecto.Adapters.Postgres
  use Scrivener, max_page_size: 500, page_size: 50, options: [allow_overflow_page_number: true]
  use EctoTrail
end
