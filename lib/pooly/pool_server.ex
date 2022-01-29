defmodule Pooly.PoolServer do

  use GenServer

  defmodule State do
    defstruct pool_sup: nil, worker_sup: nil, monitors: nil,
    size: nil, mfa: nil,  workers: nil,
    name: nil, overflow: nil, max_overflow: nil,
    waiting: nil
  end

  def start_link(pool_sup, pool_config) do
    GenServer.start_link(__MODULE__, [pool_sup, pool_config], name: name(pool_config[:name]))
  end

  def init([pool_sup, pool_config]) when is_pid(pool_sup) do
    # We need to perform operations when Pooly.Server or Worker crashes.
    # In case the worker crashes only cleanup is required.
    # In case the server crashes workers need to be killed as a dangling worker will be orphaned without reference.
    # Link the server to worker processes, and trap exits only in the server.
    Process.flag(:trap_exit, true)
    monitors = :ets.new(:monitors, [:private])
    waiting = :queue.new
    state = %State{
      pool_sup: pool_sup, monitors: monitors,
      waiting: waiting, overflow: 0
    }
    init(pool_config, state)
  end

  def init([{:name, name} | rest], state) do
    init(rest, %{state | name: name})
  end

  def init([{:mfa, mfa} | rest], state) do
    init(rest, %{state | mfa: mfa})
  end

  def init([{:size, size} | rest], state) do
    init(rest, %{state | size: size})
  end

  def init([{:max_overflow, max_overflow} | rest], state) do
    init(rest, %{state | max_overflow: max_overflow})
  end

  def init([_ | rest], state) do
    init(rest, state)
  end

  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  def checkout(pool_name, block, timeout) do
    GenServer.call(name(pool_name), {:checkout, block}, timeout)
  end

  def checkin(pool_name, worker_pid) do
    GenServer.cast(name(pool_name), {:checkin, worker_pid})
  end

  def status(pool_name) do
    GenServer.call(name(pool_name), :status)
  end

  def terminate(_reason, _state) do
    :ok
  end

  # Invoked by init.
  def handle_info(:start_worker_supervisor, state = %{pool_sup: pool_sup, name: name, mfa: mfa, size: size}) do
    # sup -> Supervisor that supervises both GenServer(Pooly.Server) and DynamicSupervisor(Pooly.WorkerSupervisor)
    # DynamicSupervisor needs to run under `sup`.

    # {:ok, worker_sup} = Supervisor.start_child(pool_sup, worker_supervisor_spec(name))
    # workers = prepopulate(size, worker_sup, mfa)
    # {:noreply, %{state | worker_sup: worker_sup, workers: workers}}

    # Code for making worker supervisor restart permanent.
    worker_sup = case Supervisor.start_child(pool_sup, worker_supervisor_spec(name)) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end

    workers = prepopulate(size, worker_sup, mfa)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}

  end

  # Handle consumer going down. Return worker back to the pool.
  def handle_info({:DOWN, ref, _, _, _}, state = %{monitors: monitors, workers: workers}) do
    case :ets.match(monitors, {:"$1", ref}) do
      [[pid]] ->
        true = :ets.delete(monitors, pid)
        new_state = %{state | workers: [pid | workers]}
        {:noreply, new_state}
      [[]] -> {:noreply, state}
    end
  end

  # Handle worker going down. Start another instance of worker.
  def handle_info({:EXIT, pid, _reason}, state = %{monitors: monitors}) do
    case :ets.lookup(monitors, pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = handle_worker_exit(pid, state)
        {:noreply, new_state}
      _ -> {:noreply, state}
    end
  end

  # Handle worker supervisor going down.
  def handle_info({:EXIT, worker_sup, reason}, state = %{worker_sup: worker_sup}) do
    {:stop, reason, state}
  end

  def handle_call({:checkout, block}, {from_pid, _ref}, state) do

    %{
      worker_sup: worker_sup, workers: workers,
      monitors: monitors, overflow: overflow,
      max_overflow: max_overflow, mfa: mfa,
      waiting: waiting
    } = state

    case workers do
      [worker | rest] ->
        # Monitor the consumer process.
        # A crashed consumer should return the worker to pool.
        monitor_ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, monitor_ref})
        {:reply, worker, %{state | workers: rest}}
      [] when max_overflow > 0 and overflow < max_overflow ->
        {worker, worker_ref} = new_worker(worker_sup, from_pid, mfa)
        true = :ets.insert(monitors, {worker, worker_ref})
        {:reply, worker, %{state | overflow: overflow + 1}}
      [] when block == true ->
        monitor_ref = Process.monitor(from_pid)
        waiting = :queue.in({from_pid, monitor_ref}, waiting)
        {:noreply, %{state | waiting: waiting}, :infinity}
      [] -> {:reply, :full, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, state_name(state), {length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker_pid}, %{monitors: monitors} = state) do
    case :ets.lookup(monitors, worker_pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = handle_checkin(pid, state)
        {:noreply, new_state}
      [] -> {:noreply, state}
    end
  end

  defp name(pool_name) do
    :"#{pool_name}Server"
  end

  defp worker_supervisor_spec(name) do
    # Restart is temporary because we want to have some custom
    # recovery.
    %{
      id: :"#{name}WorkerSupervisor",
      start: {Pooly.WorkerSupervisor, :start_link, [:"#{name}WorkerSupervisor"]},
      type: :supervisor,
      restart: :permanent
      # restart: :temporary
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
    Process.link(worker)
    worker
  end

  defp new_worker(sup, from_pid, mfa) do
    pid = new_worker(sup, mfa)
    ref = Process.monitor(from_pid)
    {pid, ref}
  end

  defp handle_checkin(pid, state) do
    %{
      worker_sup: worker_sup, workers: workers,
      monitors: monitors, overflow: overflow,
      waiting: waiting
    } = state

    case :queue.out(waiting) do
      {{:value, {from, ref}}, left} ->
        true = :ets.insert(monitors, {pid, ref})
        GenServer.reply(from, pid)
        %{state | waiting: left}
      {:empty, empty} when overflow > 0 ->
        :ok = dismiss_worker(worker_sup, pid)
        %{state | waiting: empty, overflow: overflow - 1}
      {:empty, empty} ->
        %{state | waiting: empty, workers: [pid | workers], overflow: 0}
    end
  end

  defp dismiss_worker(worker_sup, pid) do
    true = Process.unlink(pid)
    Supervisor.terminate_child(worker_sup, pid)
    :ok
  end

  defp handle_worker_exit(_pid, state) do
    %{
      worker_sup: worker_sup, workers: workers,
      monitors: monitors, mfa: mfa,
      overflow: overflow, waiting: waiting
    } = state

    case :queue.out(waiting) do
      {{:value, {from, ref}}, left} ->
        new_worker = new_worker(worker_sup, mfa)
        true = :ets.insert(monitors, {new_worker, ref})
        GenServer.reply(from, new_worker)
        %{state | waiting: left}
      {:empty, empty} when overflow > 0 ->
        %{state | overflow: overflow - 1, waiting: empty}
      {:empty, empty} ->
        workers = [new_worker(worker_sup, mfa) | workers]
        %{state | workers: workers, waiting: empty}
    end
  end

  defp state_name(%State{overflow: overflow, max_overflow: max_overflow, workers: workers}) when overflow < 1 do
    case length(workers) == 0 do
      true ->
        if max_overflow > 1 do
          :full
        else
          :overflow
        end
      false ->
        :ready
    end
  end

  defp state_name(%State{overflow: _overflow, max_overflow: _max_overflow}) do
    :full
  end

  defp state_name(_state) do
    :overflow
  end

end
