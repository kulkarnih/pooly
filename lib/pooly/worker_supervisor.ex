defmodule Pooly.WorkerSupervisor do

  use DynamicSupervisor

  def start_link(name) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
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
