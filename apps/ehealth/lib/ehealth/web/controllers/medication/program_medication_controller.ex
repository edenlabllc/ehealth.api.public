defmodule EHealth.Web.ProgramMedicationController do
  @moduledoc false

  use EHealth.Web, :controller

  alias Core.Medications
  alias Core.Medications.Program, as: ProgramMedication
  alias Scrivener.Page

  action_fallback(EHealth.Web.FallbackController)

  def index(conn, params) do
    with %Page{} = paging <- Medications.list_program_medications(params) do
      render(conn, "index.json", program_medications: paging.entries, paging: paging)
    end
  end

  def create(conn, params) do
    consumer_id = get_consumer_id(conn.req_headers)

    with {:ok, %ProgramMedication{} = program} <- Medications.create_program_medication(params, consumer_id) do
      program = Medications.preload_references(program)

      conn
      |> put_status(:created)
      |> put_resp_header("location", program_medication_path(conn, :show, program))
      |> render("show.json", program_medication: program)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, program} <- Medications.fetch_program_medication([id: id], :preload) do
      render(conn, "show.json", program_medication: program)
    end
  end

  def update(conn, %{"id" => id} = params) do
    consumer_id = get_consumer_id(conn.req_headers)

    with {:ok, program} <- Medications.fetch_program_medication(id: id),
         {:ok, %ProgramMedication{} = program} <- Medications.update_program_medication(program, params, consumer_id) do
      render(conn, "show.json", program_medication: program)
    end
  end
end
