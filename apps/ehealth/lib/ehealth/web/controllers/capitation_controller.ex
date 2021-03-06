defmodule EHealth.Web.CapitationController do
  @moduledoc false

  use EHealth.Web, :controller
  alias Core.Capitation.Capitation
  alias Scrivener.Page

  action_fallback(EHealth.Web.FallbackController)

  def index(%Plug.Conn{req_headers: headers} = conn, params) do
    with %Page{} = paging <- Capitation.list(params, headers) do
      render(
        conn,
        "index.json",
        reports: paging.entries,
        paging: paging
      )
    end
  end

  def details(%Plug.Conn{req_headers: headers} = conn, params) do
    with %Page{} = paging <- Capitation.details(params, headers) do
      render(
        conn,
        "details.json",
        details: paging.entries,
        paging: paging
      )
    end
  end
end
