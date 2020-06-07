defmodule MinneTest do
  # tests from https://github.com/elixir-plug/plug/blob/master/test/plug/parsers_test.exs
  # this is to ensure the Temp behaviour is consistent with built in parsers.

  # doctest Minne
  use ExUnit.Case, async: true

  use Plug.Test

  def parse(conn, opts \\ []) do
    opts =
      Keyword.put_new(opts, :parsers, [
        Plug.Parsers.URLENCODED,
        {Minne, adapter: Minne.Adapter.Temp}
      ])

    Plug.Parsers.call(conn, Plug.Parsers.init(opts))
  end

  test "parsing prefers body params over query params with existing params" do
    conn =
      conn(:post, "/?foo=query", "foo=body")
      |> Map.put(:params, %{"foo" => "params"})
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> parse()

    assert conn.params["foo"] == "body"
  end

  test "keeps existing body params" do
    conn = conn(:post, "/?foo=bar")
    conn = parse(%{conn | body_params: %{"foo" => "baz"}, params: %{"foo" => "baz"}})
    assert conn.params["foo"] == "baz"
    assert conn.body_params["foo"] == "baz"
    assert conn.query_params["foo"] == "bar"
  end

  test "ignore bodies unless post/put/match/delete" do
    conn =
      conn(:get, "/?foo=bar", "foo=baz")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> parse()

    assert conn.params["foo"] == "bar"
    assert conn.body_params == %{}
    assert conn.query_params["foo"] == "bar"
  end

  test "errors on invalid utf-8 in body params when validate_utf8 true (by default)" do
    conn =
      conn(:post, "/", "foo=#{<<139>>}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    assert_raise(
      Plug.Parsers.BadEncodingError,
      "invalid UTF-8 on urlencoded params, got byte 139",
      fn ->
        parse(conn, validate_utf8: true)
      end
    )
  end

  test "parses invalid utf-8 in body params when validate_utf8 false" do
    conn =
      conn(:post, "/", "foo=#{<<139>>}")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> parse(validate_utf8: false)

    assert conn.params["foo"] == <<139>>
    assert conn.body_params["foo"] == <<139>>
  end

  test "parses url encoded bodies" do
    conn =
      conn(:post, "/?foo=bar", "foo=baz")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> parse()

    assert conn.params["foo"] == "baz"
  end

  test "parses multipart bodies with test params" do
    conn = parse(conn(:post, "/?foo=bar"))
    assert conn.params == %{"foo" => "bar"}

    conn = parse(conn(:post, "/?foo=bar", foo: "baz"))
    assert conn.params == %{"foo" => "baz"}
  end

  test "parses multipart bodies with test body" do
    multipart = """
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"name\"\r
    \r
    hello\r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"pic\"; filename=\"foo.txt\"\r
    Content-Type: text/plain\r
    \r
    hello
    \r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"doc\"; filename*=\"utf-8''%C5%BC%C3%B3%C5%82%C4%87.txt\"\r
    Content-Type: text/plain\r
    \r
    hello
    \r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data\r
    \r
    skipped\r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"empty\"; filename=\"\"\r
    Content-Type: application/octet-stream\r
    \r
    \r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name="status[]"\r
    \r
    choice1\r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name="status[]"\r
    \r
    choice2\r
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"commit\"\r
    \r
    Create User\r
    ------w58EW1cEpjzydSCq--\r
    """

    %{params: params} =
      conn(:post, "/", multipart)
      |> put_req_header("content-type", "multipart/mixed; boundary=----w58EW1cEpjzydSCq")
      |> parse()

    assert params["name"] == "hello"
    assert params["status"] == ["choice1", "choice2"]
    assert params["empty"] == nil

    assert %Minne.Upload{} = upload = params["pic"]
    assert File.read!(upload.adapter.path) == "hello\n"
    assert upload.content_type == "text/plain"
    assert upload.filename == "foo.txt"

    assert %Minne.Upload{} = upload = params["doc"]
    assert File.read!(upload.adapter.path) == "hello\n"
    assert upload.content_type == "text/plain"
    assert upload.filename == "żółć.txt"
  end

  test "multipart legth accepts MFA evaluated on request" do
    multipart = """
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"name\"\r
    \r
    hello\r
    ------w58EW1cEpjzydSCq--\r
    """

    {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :multipart_length)

    defmodule LengthGetter do
      def get() do
        Agent.get(:multipart_length, & &1)
      end
    end

    opts = Plug.Parsers.init(parsers: [{:multipart, length: {LengthGetter, :get, []}}])

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      conn(:post, "/", multipart)
      |> put_req_header("content-type", "multipart/mixed; boundary=----w58EW1cEpjzydSCq")
      |> Plug.Parsers.call(opts)
    end

    Agent.update(:multipart_length, fn _ -> 10_000 end)

    %{params: params} =
      conn(:post, "/", multipart)
      |> put_req_header("content-type", "multipart/mixed; boundary=----w58EW1cEpjzydSCq")
      |> Plug.Parsers.call(opts)

    assert params["name"] == "hello"
  end

  test "multipart bodies with unnamed body parts opt" do
    multipart = """
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"name\"\r
    \r
    hello\r
    ------w58EW1cEpjzydSCq\r
    Content-Type: application/json\r
    \r
    {"indisposed": "json"}\r
    ------w58EW1cEpjzydSCq\r
    Content-Type: application/octet-stream\r
    X-My-Foo: bar\r
    \r
    foo\r
    ------w58EW1cEpjzydSCq\r
    \r
    No content-type? No problem!\r
    ------w58EW1cEpjzydSCq--\r
    """

    %{params: params} =
      conn(:post, "/", multipart)
      |> put_req_header("content-type", "multipart/mixed; boundary=----w58EW1cEpjzydSCq")
      |> parse(include_unnamed_parts_at: "_parts")

    assert params["name"] == "hello"

    assert [part1, part2, part3] = params["_parts"]
    assert part1.body == "{\"indisposed\": \"json\"}"
    assert part1.headers == [{"content-type", "application/json"}]
    assert part2.body == "foo"
    assert part2.headers == [{"x-my-foo", "bar"}, {"content-type", "application/octet-stream"}]
    assert part3.body == "No content-type? No problem!"
    assert part3.headers == []
  end

  test "validates utf8 in multipart body" do
    latin1_binary = :unicode.characters_to_binary('hello©', :utf8, :latin1)

    multipart = """
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"name\"\r
    \r
    #{latin1_binary}\r
    ------w58EW1cEpjzydSCq--\r
    """

    assert_raise Plug.Parsers.BadEncodingError, fn ->
      conn(:post, "/", multipart)
      |> put_req_header("content-type", "multipart/mixed; boundary=----w58EW1cEpjzydSCq")
      |> parse()
    end
  end

  test "does not validate utf8 in multipart body opt" do
    latin1_binary = :unicode.characters_to_binary('hello©', :utf8, :latin1)

    multipart = """
    ------w58EW1cEpjzydSCq\r
    Content-Disposition: form-data; name=\"name\"\r
    \r
    #{latin1_binary}\r
    ------w58EW1cEpjzydSCq--\r
    """

    %{params: params} =
      conn(:post, "/", multipart)
      |> put_req_header("content-type", "multipart/mixed; boundary=----w58EW1cEpjzydSCq")
      |> parse(validate_utf8: false)

    assert params["name"] == latin1_binary
  end

  test "parses empty multipart body" do
    %{params: params} =
      conn(:post, "/", "")
      |> put_req_header("content-type", "multipart/form-data")
      |> parse()

    assert params == %{}
  end
end
