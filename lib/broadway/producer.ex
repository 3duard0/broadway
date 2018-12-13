defmodule Broadway.Producer do
  @moduledoc false
  use GenStage

  defmodule State do
    @moduledoc false
    defstruct [:module, :state]
  end

  def start_link(args, opts \\ []) do
    GenStage.start_link(__MODULE__, args, opts)
  end

  def push_messages(producer, messages) do
    GenStage.call(producer, {:push_messages, messages})
  end

  def init(args) do
    module = args[:module]
    {:producer, state} = module.init(args[:args])
    {:producer, %State{module: module, state: state}}
  end

  def handle_demand(demand, %State{module: module, state: module_state} = state) do
    case module.handle_demand(demand, module_state) do
      {tag, events_or_reason, new_state} ->
        {tag, events_or_reason, %State{state | state: new_state}}

      {:noreply, events, new_state, :hibernate} ->
        {:noreply, events, %State{state | state: new_state}, :hibernate}
    end
  end

  def handle_call({:push_messages, messages}, _from, state) do
    {:reply, :ok, messages, state}
  end
end
