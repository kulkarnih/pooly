defmodule Pooly.PoolsSupervisor do
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Initialise supervisor with no children.
    # Restart strategy is one for one as failure in one pool supervisor
    # should not affect other pools.
    Supervisor.init([], strategy: :one_for_one)
  end
end
