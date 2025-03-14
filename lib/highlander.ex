defmodule Highlander do
  @moduledoc """
  Highlander allows you to run a single globally unique process in a cluster.

  Highlander uses erlang's `:global` module to ensure uniqueness, and uses `child_spec.id` as the uniqueness key.

  Highlander will start its child process just once in a cluster. The first Highlander process will start its child, all other Highlander processes will monitor the first process and attempt to take over when it goes down.

  _Note: You can also use Highlander to start a globally unique supervision tree._

  ## Usage
  Simply wrap a child process with `{Highlander, child}`.

  Before:

  ```
  children = [
    child_spec
  ]

  Supervisor.init(children, strategy: :one_for_one)
  ```

  After:

  ```
  children = [
    {Highlander, child_spec}
  ]

  Supervisor.init(children, strategy: :one_for_one)
  ```
  See the [documentation on Supervisor.child_spec/1](https://hexdocs.pm/elixir/Supervisor.html#module-child_spec-1) for more information.

  ## `child_spec.id` is used to determine global uniqueness

  Ensure that `child_spec.id` has the correct value! Check the debug logs if you are unsure what is being used.

  ## Globally unique supervisors

  You can also have Highlander run a supervisor:

  ```
  children = [
    {Highlander, {MySupervisor, arg}},
  ]
  ```

  ## Handling netsplits

  If there is a netsplit in your cluster, then Highlander will think that the other process has died, and start a new one. When the split heals, `:global` will recognize that there is a naming conflict, and will take action to rectify that. To deal with this, Highlander simply terminates one of the two child processes with reason `:shutdown`.

  To catch this, simply trap exits in your process and add a `terminate/2` callback.

  Note: The `terminate/2` callback will also run when your application is terminating.

  ```
  def init(arg) do
    Process.flag(:trap_exit, true)
    {:ok, initial_state(arg)}
  end

  def terminate(_reason, _state) do
    # this will run when the process receives an exit signal from its parent
  end
  ```
  """

  use GenServer
  require Logger

  def child_spec(child_child_spec) do
    child_child_spec = Supervisor.child_spec(child_child_spec, [])

    Logger.debug("Starting Highlander with #{inspect(child_child_spec.id)} as uniqueness key")

    %{
      id: child_child_spec.id,
      start: {GenServer, :start_link, [__MODULE__, child_child_spec, []]},
      restart: :transient
    }
  end

  @impl true
  def init(child_spec) do
    Process.flag(:trap_exit, true)
    {:ok, register(%{child_spec: child_spec})}
  end

  def whereis(name) do
    name
    |> name()
    |> :global.whereis_name()
    |> case do
      pid when is_pid(pid) -> GenServer.call(pid, :get_child_pid)
      _ -> nil
    end
  end

  def terminate_child(name) do
    name
    |> name()
    |> :global.whereis_name()
    |> Supervisor.stop(:normal)
  end

  @impl true
  def handle_call(:get_child_pid, _from, state) do
    pid =
      state.pid
      |> Supervisor.which_children()
      |> case do
        [{_, pid, _, _}] when pid not in [:restarting, :undefined] -> pid
        _ -> nil
      end

    {:reply, pid, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, :normal}, %{ref: ref} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{ref: ref} = state) do
    {:noreply, register(state)}
  end

  def handle_info({:EXIT, _pid, :name_conflict}, %{pid: pid} = state) do
    :ok = Supervisor.stop(pid, :shutdown)
    {:stop, {:shutdown, :name_conflict}, Map.delete(state, :pid)}
  end

  @impl true
  def terminate(reason, %{pid: pid} = state) do
    unregister_name(name(state))
    :ok = Supervisor.stop(pid, reason)
  end

  def terminate(_, _), do: nil

  defp name(%{child_spec: %{id: global_name}}) do
    {__MODULE__, global_name}
  end

  defp name(name), do: name(%{child_spec: %{id: name}})

  defp handle_conflict(_name, pid1, pid2) do
    Process.exit(pid2, :name_conflict)
    pid1
  end

  defp unregister_name(state) do
    :ok = :global.unregister_name(name(state))
  end

  defp register(state) do
    case :global.register_name(name(state), self(), &handle_conflict/3) do
      :yes -> start(state)
      :no -> monitor(state)
    end
  end

  defp start(state) do
    {:ok, pid} = Supervisor.start_link([state.child_spec], strategy: :one_for_one)
    Map.put(state, :pid, pid)
  end

  defp monitor(state) do
    case :global.whereis_name(name(state)) do
      :undefined ->
        register(state)

      pid ->
        ref = Process.monitor(pid)
        %{child_spec: state.child_spec, ref: ref}
    end
  end
end
