defmodule GnatTest do
  use ExUnit.Case, async: true
  doctest Gnat

  setup context do
    if context[:multi_server] do
      case :gen_tcp.connect('localhost', 4223, [:binary]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
        {:error, reason} ->
          Mix.raise "Cannot connect to gnatsd" <>
                    " (http://localhost:4223):" <>
                    " #{:inet.format_error(reason)}\n" <>
                    "You probably need to start a gnatsd " <>
                    "server that requires authentication with " <>
                    "the following command `gnatsd -p 4223 " <>
                    "--user bob --pass alice`."
      end
    end
    :ok
  end

  test "connect to a server" do
    {:ok, pid} = Gnat.start_link()
    assert Process.alive?(pid)
    :ok = Gnat.stop(pid)
  end

  @tag :multi_server
  test "connect to a server with authentication" do
    connection_settings = %{
      host: 'localhost',
      port: 4223,
      tcp_opts: [:binary],
      username: "bob",
      password: "alice"
    }
    {:ok, pid} = Gnat.start_link(connection_settings)
    assert Process.alive?(pid)
    :ok = Gnat.ping(pid)
    :ok = Gnat.stop(pid)
  end

  test "subscribe to topic and receive a message" do
    {:ok, pid} = Gnat.start_link()
    {:ok, _ref} = Gnat.sub(pid, self(), "test")
    :ok = Gnat.pub(pid, "test", "yo dawg")

    assert_receive {:msg, %{topic: "test", body: "yo dawg", reply_to: nil}}, 1000
    :ok = Gnat.stop(pid)
  end

  test "subscribe receive a message with a reply_to" do
    {:ok, pid} = Gnat.start_link()
    {:ok, _ref} = Gnat.sub(pid, self(), "with_reply")
    :ok = Gnat.pub(pid, "with_reply", "yo dawg", reply_to: "me")

    assert_receive {:msg, %{topic: "with_reply", reply_to: "me", body: "yo dawg"}}, 1000
    :ok = Gnat.stop(pid)
  end

  test "receive multiple messages" do
    {:ok, pid} = Gnat.start_link()
    {:ok, _ref} = Gnat.sub(pid, self(), "test")
    :ok = Gnat.pub(pid, "test", "message 1")
    :ok = Gnat.pub(pid, "test", "message 2")
    :ok = Gnat.pub(pid, "test", "message 3")

    assert_receive {:msg, %{topic: "test", body: "message 1", reply_to: nil}}, 500
    assert_receive {:msg, %{topic: "test", body: "message 2", reply_to: nil}}, 500
    assert_receive {:msg, %{topic: "test", body: "message 3", reply_to: nil}}, 500
    :ok = Gnat.stop(pid)
  end

  test "subscribing to the same topic multiple times" do
    {:ok, pid} = Gnat.start_link()
    {:ok, _sub1} = Gnat.sub(pid, self(), "dup")
    {:ok, _sub2} = Gnat.sub(pid, self(), "dup")
    :ok = Gnat.pub(pid, "dup", "yo")
    :ok = Gnat.pub(pid, "dup", "ma")
    assert_receive {:msg, %{topic: "dup", body: "yo"}}, 500
    assert_receive {:msg, %{topic: "dup", body: "yo"}}, 500
    assert_receive {:msg, %{topic: "dup", body: "ma"}}, 500
    assert_receive {:msg, %{topic: "dup", body: "ma"}}, 500
  end

  test "subscribing to the same topic multiple times with a queue group" do
    {:ok, pid} = Gnat.start_link()
    {:ok, _sub1} = Gnat.sub(pid, self(), "dup", queue_group: "us")
    {:ok, _sub2} = Gnat.sub(pid, self(), "dup", queue_group: "us")
    :ok = Gnat.pub(pid, "dup", "yo")
    :ok = Gnat.pub(pid, "dup", "ma")
    assert_receive {:msg, %{topic: "dup", body: "yo"}}, 500
    assert_receive {:msg, %{topic: "dup", body: "ma"}}, 500
    receive do
      {:msg, %{topic: _topic}}=msg -> flunk("Received duplicate message: #{inspect msg}")
      after 200 -> :ok
    end
  end

  test "unsubscribing from a topic" do
    topic = "testunsub"
    {:ok, pid} = Gnat.start_link()
    {:ok, sub_ref} = Gnat.sub(pid, self(), topic)
    :ok = Gnat.pub(pid, topic, "msg1")
    assert_receive {:msg, %{topic: ^topic, body: "msg1"}}, 500
    :ok = Gnat.unsub(pid, sub_ref)
    :ok = Gnat.pub(pid, topic, "msg2")
    receive do
      {:msg, %{topic: _topic, body: _body}}=msg -> flunk("Received message after unsubscribe: #{inspect msg}")
      after 200 -> :ok
    end
  end

  test "unsubscribing from a topic after a maximum number of messages" do
    topic = "testunsub_maxmsg"
    {:ok, pid} = Gnat.start_link()
    {:ok, sub_ref} = Gnat.sub(pid, self(), topic)
    :ok = Gnat.unsub(pid, sub_ref, max_messages: 2)
    :ok = Gnat.pub(pid, topic, "msg1")
    :ok = Gnat.pub(pid, topic, "msg2")
    :ok = Gnat.pub(pid, topic, "msg3")
    assert_receive {:msg, %{topic: ^topic, body: "msg1"}}, 500
    assert_receive {:msg, %{topic: ^topic, body: "msg2"}}, 500
    receive do
      {:msg, _topic, _msg}=msg -> flunk("Received message after unsubscribe: #{inspect msg}")
      after 200 -> :ok
    end
  end

  test "request-reply convenience function" do
    topic = "req-resp"
    {:ok, pid} = Gnat.start_link()
    spin_up_echo_server_on_topic(pid, topic)
    {:ok, msg} = Gnat.request(pid, topic, "ohai", receive_timeout: 500)
    assert msg.body == "ohai"
  end

  test "reconnect when pub fails" do
    mock_server = fn ->
      {:ok, socket} = :gen_tcp.listen(11111, [:binary, active: false, reuseaddr: true])
      {:ok, client} = :gen_tcp.accept(socket)
      :gen_tcp.send(client, "INFO {}")
      :gen_tcp.close(client)
      {:ok, client2} = :gen_tcp.accept(socket)
      :gen_tcp.send(client2, "INFO {}")
      :gen_tcp.recv(client2, 0)
      :gen_tcp.close(socket)
      :ok
    end
    mock_server_task = Task.async(mock_server)
    {:ok, pid} = Gnat.start_link(%{port: 11111})
    {:error, :closed} = Gnat.pub(pid, "test", "yo dawg")
    :ok = Gnat.pub(pid, "test", "yo dawg")
    :ok = Task.await(mock_server_task)
    :ok = Gnat.stop(pid)
  end

  defp spin_up_echo_server_on_topic(gnat, topic) do
    spawn(fn ->
      {:ok, subscription} = Gnat.sub(gnat, self(), topic)
      :ok = Gnat.unsub(gnat, subscription, max_messages: 1)
      receive do
        {:msg, %{topic: ^topic, body: body, reply_to: reply_to}} ->
          Gnat.pub(gnat, reply_to, body)
      end
    end)
  end
end
