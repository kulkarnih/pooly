defmodule Pooly.WorkerSupervisor do

  # {:ok, pooly_supervisor} = Pooly.Supervisor.start_link([mfa: {SampleWorker, :start_link, []}, size: 5])
  # [{_, pooly_worker_supervisor, _, _}, {_, pooly_server, _, _}] = Supervisor.which_children(pooly_supervisor)
  # DynamicSupervisor.which_children(pooly_worker_supervisor)

  use DynamicSupervisor

  def start_link() do
    DynamicSupervisor.start_link(__MODULE__, :ok)
  end

  def init(_) do

    opts = [
      strategy: :one_for_one,
      max_restarts: 5,
      max_seconds: 5,
      max_children: 10
    ]

    DynamicSupervisor.init(opts)
  end

end
