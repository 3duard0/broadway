defmodule BroadwayTest do
  use ExUnit.Case

  import Integer
  alias Broadway.{Producer, Message, BatchInfo}

  @behaviour Broadway.Acknowledger

  def ack(successful, failed) do
    [%Message{acknowledger: {_, %{test_pid: test_pid}}} | _] = successful

    if test_pid do
      send(test_pid, {:ack, successful, failed})
    end
  end

  defmodule ManualProducer do
    use GenStage

    def start_link(args, opts \\ []) do
      GenStage.start_link(__MODULE__, args, opts)
    end

    def init(_args) do
      {:producer, %{}}
    end

    def handle_demand(_demand, state) do
      {:noreply, [], state}
    end
  end

  defmodule Counter do
    use GenStage

    @behaviour Broadway.Acknowledger

    def start_link(args, opts \\ []) do
      GenStage.start_link(__MODULE__, args, opts)
    end

    def init(args) do
      from = Keyword.fetch!(args, :from)
      to = Keyword.fetch!(args, :to)
      test_pid = Keyword.get(args, :test_pid)
      {:producer, %{to: to, counter: from, test_pid: test_pid}}
    end

    def handle_demand(demand, %{to: to, counter: counter} = state)
        when demand > 0 and counter > to do
      {:noreply, [], state}
    end

    def handle_demand(demand, state) when demand > 0 do
      %{to: to, counter: counter, test_pid: test_pid} = state
      max = min(to, counter + demand - 1)

      events =
        Enum.map(counter..max, fn e ->
          %Message{data: e, acknowledger: {__MODULE__, %{id: e, test_pid: test_pid}}}
        end)

      {:noreply, events, %{state | counter: max + 1}}
    end

    def ack(successful, failed) do
      [%Message{acknowledger: {_, %{test_pid: test_pid}}} | _] = successful

      if test_pid do
        send(test_pid, {:ack, successful, failed})
      end
    end
  end

  defmodule Forwarder do
    use Broadway

    import Message.Actions

    def handle_message(%Message{data: data} = message, %{test_pid: test_pid})
        when is_odd(data) do
      send(test_pid, {:message_handled, message.data})

      {:ok,
       message
       |> update_data(fn data -> data + 1000 end)
       |> put_publisher(:odd)}
    end

    def handle_message(message, %{test_pid: test_pid}) do
      send(test_pid, {:message_handled, message.data})

      {:ok,
       message
       |> update_data(fn data -> data + 1000 end)
       |> put_publisher(:even)}
    end

    def handle_batch(publisher, messages, _, %{test_pid: test_pid}) do
      send(test_pid, {:batch_handled, publisher, messages})
      {:ack, successful: messages, failed: []}
    end
  end

  defmodule ForwarderWithNoPublisherDefined do
    use Broadway

    def handle_message(message, _context) do
      {:ok, message}
    end

    def handle_batch(publisher, messages, _, %{test_pid: test_pid}) do
      send(test_pid, {:batch_handled, publisher, messages})
      {:ack, successful: messages, failed: []}
    end
  end

  defmodule ForwarderWithCustomHandlers do
    use Broadway

    def handle_message(message, %{handle_message: handler} = context) do
      handler.(message, context)
    end

    def handle_message(message, %{test_pid: test_pid}) do
      send(test_pid, {:message_handled, message})
      {:ok, message}
    end

    def handle_batch(publisher, messages, batch_info, %{handle_batch: handler} = context) do
      handler.(publisher, messages, batch_info, context)
    end

    def handle_batch(publisher, messages, batch_info, %{test_pid: test_pid}) do
      send(test_pid, {:batch_handled, publisher, messages, batch_info})
      {:ack, successful: messages, failed: []}
    end
  end

  describe "use Broadway" do
    test "generates child_spec/1" do
      defmodule MyBroadway do
        use Broadway
        def handle_message(_, _), do: nil
        def handle_batch(_, _, _, _), do: nil
      end

      assert MyBroadway.child_spec(:arg) == %{
               id: BroadwayTest.MyBroadway,
               start: {Broadway, :start_link, [BroadwayTest.MyBroadway, %{}, :arg]}
             }
    end

    test "generates child_spec/1 with overriden options" do
      defmodule MyBroadwayWithCustomOptions do
        use Broadway, id: :some_id

        def handle_message(_, _), do: nil
        def handle_batch(_, _, _, _), do: nil
      end

      assert MyBroadwayWithCustomOptions.child_spec(:arg).id == :some_id
    end
  end

  describe "broadway config" do
    test "default number of processors is schedulers_online * 2" do
      broadway = new_unique_name()

      Broadway.start_link(Forwarder, %{},
        name: broadway,
        producers: []
      )

      schedulers_online = :erlang.system_info(:schedulers_online)

      assert get_n_processors(broadway) == schedulers_online * 2
    end

    test "set number of processors" do
      broadway = new_unique_name()

      Broadway.start_link(Forwarder, %{},
        name: broadway,
        processors: [stages: 13],
        producers: []
      )

      assert get_n_processors(broadway) == 13
    end

    test "default number of consumers is 1 per publisher" do
      broadway = new_unique_name()

      Broadway.start_link(Forwarder, %{test_pid: self()},
        name: broadway,
        producers: [],
        publishers: [:p1, :p2]
      )

      assert get_n_consumers(broadway, :p1) == 1
      assert get_n_consumers(broadway, :p2) == 1
    end

    test "set number of consumers" do
      broadway = new_unique_name()

      Broadway.start_link(Forwarder, %{test_pid: self()},
        name: broadway,
        producers: [],
        publishers: [
          p1: [stages: 2],
          p2: [stages: 3]
        ]
      )

      assert get_n_consumers(broadway, :p1) == 2
      assert get_n_consumers(broadway, :p2) == 3
    end

    test "define a default publisher when none is defined" do
      broadway = new_unique_name()

      Broadway.start_link(ForwarderWithNoPublisherDefined, %{},
        name: broadway,
        producers: []
      )

      batcher = get_batcher(broadway, :default)
      assert Process.whereis(batcher) != nil
    end
  end

  describe "producer" do
    test "multiple producers" do
      broadway = new_unique_name()

      Broadway.start_link(Forwarder, %{test_pid: self()},
        name: broadway,
        producers: [
          producer1: [module: ManualProducer, arg: []],
          producer2: [module: ManualProducer, arg: []]
        ],
        publishers: [:even, :odd]
      )

      producer1 = get_producer(broadway, :producer1)
      producer2 = get_producer(broadway, :producer2)

      push_messages(producer1, [1])
      push_messages(producer2, [3])

      assert_receive {:message_handled, 1}
      assert_receive {:message_handled, 3}
    end

    test "push_messages/2" do
      broadway = new_unique_name()

      Broadway.start_link(Forwarder, %{test_pid: self()},
        name: broadway,
        producers: [[module: ManualProducer, arg: []]],
        publishers: [:even, :odd]
      )

      producer = get_producer(broadway)

      Producer.push_messages(producer, [
        %Message{data: 1},
        %Message{data: 3}
      ])

      assert_receive {:message_handled, 1}
      assert_receive {:message_handled, 3}
    end
  end

  describe "processor" do
    setup do
      broadway = new_unique_name()

      {:ok, _pid} =
        Broadway.start_link(Forwarder, %{test_pid: self()},
          name: broadway,
          producers: [[module: ManualProducer, arg: []]],
          publishers: [:even, :odd]
        )

      %{producer: get_producer(broadway)}
    end

    test "handle all produced messages", %{producer: producer} do
      push_messages(producer, 1..200)

      for counter <- 1..200 do
        assert_receive {:message_handled, ^counter}
      end

      refute_receive {:message_handled, _}
    end

    test "forward messages to the specified batcher", %{producer: producer} do
      push_messages(producer, 1..200)

      assert_receive {:batch_handled, :odd, messages}
      assert Enum.all?(messages, fn msg -> is_odd(msg.data) end)

      assert_receive {:batch_handled, :even, messages}
      assert Enum.all?(messages, fn msg -> is_even(msg.data) end)

      refute_receive {:batch_handled, _, _}
    end
  end

  describe "publisher/batcher" do
    setup do
      broadway = new_unique_name()

      {:ok, _pid} =
        Broadway.start_link(Forwarder, %{test_pid: self()},
          name: broadway,
          producers: [[module: ManualProducer, arg: []]],
          publishers: [
            odd: [batch_size: 10, batch_timeout: 20],
            even: [batch_size: 5, batch_timeout: 20]
          ]
        )

      %{producer: get_producer(broadway)}
    end

    test "generate batches based on :batch_size", %{producer: producer} do
      push_messages(producer, 1..40)

      assert_receive {:batch_handled, :odd, messages} when length(messages) == 10
      assert_receive {:batch_handled, :odd, messages} when length(messages) == 10
      assert_receive {:batch_handled, :even, messages} when length(messages) == 5
      assert_receive {:batch_handled, :even, messages} when length(messages) == 5
      assert_receive {:batch_handled, :even, messages} when length(messages) == 5
      assert_receive {:batch_handled, :even, messages} when length(messages) == 5
      refute_receive {:batch_handled, _, _}
    end

    test "generate batches with the remaining messages when :batch_timeout is reached", %{
      producer: producer
    } do
      push_messages(producer, 1..5)

      assert_receive {:batch_handled, :odd, messages} when length(messages) == 3
      assert_receive {:batch_handled, :even, messages} when length(messages) == 2
      refute_receive {:batch_handled, _, _}
    end
  end

  describe "publisher/consumer" do
    test "handle all generated batches" do
      {:ok, _} =
        Broadway.start_link(Forwarder, %{test_pid: self()},
          name: new_unique_name(),
          producers: [[module: Counter, arg: [from: 1, to: 200]]],
          publishers: [
            odd: [batch_size: 10],
            even: [batch_size: 10]
          ]
        )

      for _ <- 1..20 do
        assert_receive {:batch_handled, _, _}
      end

      refute_receive {:batch_handled, _, _}
    end

    test "pass messages to be acknowledged" do
      {:ok, _} =
        Broadway.start_link(Forwarder, %{test_pid: self()},
          name: new_unique_name(),
          producers: [[module: Counter, arg: [from: 1, to: 200, test_pid: self()]]],
          publishers: [:odd, :even]
        )

      assert_receive {:ack, successful, _failed}
      assert length(successful) == 100
    end

    test "messages including extra data for acknowledgement" do
      {:ok, _} =
        Broadway.start_link(Forwarder, %{test_pid: self()},
          name: new_unique_name(),
          producers: [[module: Counter, arg: [from: 1, to: 200, test_pid: self()]]],
          publishers: [:odd, :even]
        )

      assert_receive {:ack, successful, _failed}

      assert Enum.all?(successful, fn %Message{acknowledger: {_, ack_data}, data: data} ->
               data == ack_data.id + 1000
             end)
    end
  end

  describe "handle processor crash" do
    setup do
      handle_message = fn message, %{test_pid: test_pid} ->
        if message.data == :kill_processor do
          Process.exit(message.processor_pid, :kill)
        end

        send(test_pid, {:message_handled, message})
        {:ok, message}
      end

      context = %{
        test_pid: self(),
        handle_message: handle_message
      }

      broadway_name = new_unique_name()

      {:ok, _pid} =
        Broadway.start_link(ForwarderWithCustomHandlers, context,
          name: broadway_name,
          processors: [stages: 1, min_demand: 1, max_demand: 2],
          producers: [[module: ManualProducer, arg: []]],
          publishers: [default: [batch_size: 2]]
        )

      producer = get_producer(broadway_name, :default)
      processor = get_processor(broadway_name, 1)
      batcher = get_batcher(broadway_name, :default)

      %{producer: producer, processor: processor, batcher: batcher}
    end

    test "processor will be restarted in order to handle other messages", %{producer: producer} do
      push_messages(producer, [1])
      assert_receive {:message_handled, %{data: 1, processor_pid: processor1}}

      ref = Process.monitor(processor1)
      push_messages(producer, [:kill_processor])
      assert_receive {:DOWN, ^ref, _, _, _}

      push_messages(producer, [2])

      assert_receive {:message_handled, %{data: 2, processor_pid: processor2}}
      assert processor1 != processor2
    end

    test "batchers and producers should not be restarted", context do
      %{producer: producer, processor: processor, batcher: batcher} = context

      ref_batcher = Process.monitor(batcher)
      ref_processor = Process.monitor(processor)
      ref_producer = Process.monitor(producer)

      push_messages(producer, [:kill_processor])

      assert_receive {:DOWN, ^ref_processor, _, _, _}
      refute_receive {:DOWN, ^ref_batcher, _, _, _}
      refute_receive {:DOWN, ^ref_producer, _, _, _}
    end

    test "only the messages in the crashing processor are lost", %{producer: producer} do
      push_messages(producer, [1, 2, :kill_processor, 3, 4, 5])

      assert_receive {:message_handled, %{data: 1}}
      assert_receive {:message_handled, %{data: 2}}

      refute_receive {:message_handled, %{data: :kill_processor}}
      refute_receive {:message_handled, %{data: 3}}

      assert_receive {:message_handled, %{data: 4}}
      assert_receive {:message_handled, %{data: 5}}
    end

    test "batches are created normally (without the lost messages)", %{producer: producer} do
      push_messages(producer, [1, 2, :kill_processor, 3, 4, 5])

      assert_receive {:batch_handled, _, messages, _}
      values = messages |> Enum.map(& &1.data)
      assert values == [1, 2]

      assert_receive {:batch_handled, _, messages, _}
      values = messages |> Enum.map(& &1.data)
      assert values == [4, 5]
    end
  end

  describe "handle batcher crash" do
    setup do
      handle_batch = fn _publisher, messages, batch_info, %{test_pid: test_pid} ->
        if Enum.at(messages, 0).data == 1 do
          Process.exit(batch_info.batcher, :kill)
        end

        send(test_pid, {:batch_handled, messages, batch_info})
        {:ack, successful: messages, failed: []}
      end

      context = %{
        test_pid: self(),
        handle_batch: handle_batch
      }

      {:ok, _pid} =
        Broadway.start_link(ForwarderWithCustomHandlers, context,
          name: new_unique_name(),
          processors: [stages: 1, min_demand: 1, max_demand: 2],
          producers: [[module: Counter, arg: [from: 1, to: 6, test_pid: self()]]],
          publishers: [default: [batch_size: 2, min_demand: 0, max_demand: 2]]
        )

      :ok
    end

    test "batcher will be restarted in order to handle other messages" do
      assert_receive {:batch_handled, _, %BatchInfo{batcher: batcher1}}
      assert_receive {:batch_handled, _, %BatchInfo{batcher: batcher2}}
      assert batcher1 != batcher2
    end

    test "only the messages in the crashing batcher are lost" do
      assert_receive {:ack, successful, _failed}
      values = Enum.map(successful, & &1.data)
      assert values == [1, 2]

      assert_receive {:ack, successful, _failed}
      values = Enum.map(successful, & &1.data)
      assert values == [5, 6]

      refute_receive {:ack, _successful, _failed}
    end
  end

  describe "shutdown" do
    test "shutting down broadway waits until the Broadway.Supervisor is down" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Broadway.start_link(ForwarderWithNoPublisherDefined, %{test_pid: self()},
          name: new_unique_name(),
          producers: [[module: Counter, arg: [from: 1, to: 10]]]
        )

      %Broadway.State{supervisor_pid: supervisor_pid} = :sys.get_state(pid)

      Process.exit(pid, :shutdown)

      assert_receive {:EXIT, ^pid, :shutdown}
      assert Process.alive?(supervisor_pid) == false
    end

    @tag :capture_log
    test "killing the supervisor brings down the broadway GenServer" do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Broadway.start_link(ForwarderWithNoPublisherDefined, %{test_pid: self()},
          name: new_unique_name(),
          producers: [[module: Counter, arg: [from: 1, to: 10]]]
        )

      %Broadway.State{supervisor_pid: supervisor_pid} = :sys.get_state(pid)

      Process.exit(supervisor_pid, :kill)
      assert_receive {:EXIT, ^pid, :killed}
    end
  end

  defp new_unique_name() do
    :"Broadway#{System.unique_integer([:positive, :monotonic])}"
  end

  defp get_producer(broadway_name, key \\ :default) do
    :"#{broadway_name}.Producer_#{key}"
  end

  defp get_processor(broadway_name, key) do
    :"#{broadway_name}.Processor_#{key}"
  end

  defp get_batcher(broadway_name, key) do
    :"#{broadway_name}.Batcher_#{key}"
  end

  defp get_n_processors(broadway_name) do
    Supervisor.count_children(:"#{broadway_name}.ProcessorSupervisor").workers
  end

  defp get_n_consumers(broadway_name, key) do
    Supervisor.count_children(:"#{broadway_name}.ConsumerSupervisor_#{key}").workers
  end

  defp push_messages(producer, list) do
    messages =
      Enum.map(list, fn data ->
        %Message{data: data, acknowledger: {__MODULE__, %{id: data, test_pid: self()}}}
      end)

    Producer.push_messages(producer, messages)
  end
end
