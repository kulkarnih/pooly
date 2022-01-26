A pooling library in Elixir based on Poolboy

Initial testing commands

{:ok, pooly_supervisor} = Pooly.Supervisor.start_link([mfa: {SampleWorker, :start_link, []}, size: 5])
[{_, pooly_worker_supervisor, _, _}, {_, pooly_server, _, _}] = Supervisor.which_children(pooly_supervisor)
DynamicSupervisor.which_children(pooly_worker_supervisor)
