defmodule Pooly.Server do

  use GenServer

  defmodule State do
    defstruct sup: nil, size: nil, mfa: nil, worker_sup: nil, workers: nil, monitors: nil
  end

  def start_link(sup, pool_config) do
    GenServer.start_link(__MODULE__, [sup, pool_config], name: __MODULE__)
  end

  def init([sup, pool_config]) when is_pid(sup) do
    monitors = :ets.new(:monitors, [:private])
    init(pool_config, %State{sup: sup, monitors: monitors})
  end

  def init([{:mfa, mfa} | rest], state) do
    init(rest, %{state | mfa: mfa})
  end

  def init([{:size, size} | rest], state) do
    init(rest, %{state | size: size})
  end

  def init([_ | rest], state) do
    init(rest, state)
  end

  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  def handle_info(:start_worker_supervisor, state = %{sup: sup, mfa: mfa, size: size}) do
    # sup -> Supervisor that supervises both GenServer(Pooly.Server) and DynamicSupervisor(Pooly.WorkerSupervisor)
    # DynamicSupervisor needs to run under `sup`.
    {:ok, worker_sup} = Supervisor.start_child(sup, worker_supervisor_spec())
    workers = prepopulate(size, worker_sup, mfa)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  defp worker_supervisor_spec() do
    %{
      id: Pooly.WorkerSupervisor,
      start: {Pooly.WorkerSupervisor, :start_link, []},
      restart: :temporary
    }
  end

  defp prepopulate(size, worker_sup, mfa) do
    prepopulate(size, worker_sup, mfa, [])
  end

  defp prepopulate(size, _worker_sup, _mfa, workers) when size < 1 do
    workers
  end

  defp prepopulate(size, worker_sup, mfa, workers) do
    prepopulate(size - 1, worker_sup, mfa, [new_worker(worker_sup, mfa) | workers])
  end

  defp new_worker(worker_sup, {m, f, a}) do
    spec = %{
      id: m,
      start: {m, f, a}
    }
    {:ok, worker} = DynamicSupervisor.start_child(worker_sup, spec)
    worker
  end

  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def checkin(worker_pid) do
    GenServer.cast(__MODULE__, {:checkin, worker_pid})
  end

  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
    case workers do
      [worker | rest] ->
        ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {:reply, worker, %{state | workers: rest}}

      [] -> {:reply, :noproc, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, {length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker_pid}, %{workers: workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker_pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        {:noreply, %{state | workers: [pid | workers]}}
      [] -> {:noreply, state}
    end
  end

end
