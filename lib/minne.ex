defmodule Minne do
  @moduledoc """
  Parses multipart request body, file handling is configurable via adapters.

  ## Options
    * `:adapter` - defines behaviour for multipart file handling
    * `:adapter_opts` - options for the specified adapter, see the adapter for details

  Besides the options supported by `Plug.Conn.read_body/2`, the multipart parser
  also checks for:
    * `:headers` - containing the same `:length`, `:read_length`
      and `:read_timeout` options which are used explicitly for parsing multipart
      headers.
    * `:include_unnamed_parts_at` - string specifying a body parameter that can
      hold a lists of body parts that didn't have a 'Content-Disposition' header.
      For instance, `include_unnamed_parts_at: "_parts"` would result in
      a body parameter `"_parts"`, containing a list of parts, each with `:body`
      and `:headers` fields, like `[%{body: "{}", headers: [{"content-type", "application/json"}]}]`.
  * `:validate_utf8` - specifies whether multipart body parts should be validated
      as utf8 binaries. Defaults to true.
  """

  @behaviour Plug.Parsers
  require Logger

  alias __MODULE__

  @impl Plug.Parsers
  def init(opts) do
    adapter = Keyword.get(opts, :adapter) || raise "Must supply adapter in options"
    default_adapter_opts = apply(adapter, :default_opts, [])

    # Remove the length from options as it would attempt
    # to eagerly read the body on the limit value.
    {limit, opts} = Keyword.pop(opts, :length, default_adapter_opts[:length])

    # The read length is now our effective length per call.
    {read_length, opts} = Keyword.pop(opts, :read_length, default_adapter_opts[:read_length])
    opts = [length: read_length, read_length: read_length] ++ opts

    # The header options are handled individually.
    {headers_opts, opts} = Keyword.pop(opts, :headers, [])

    {limit, headers_opts, opts}
  end

  @impl Plug.Parsers
  def parse(conn, "multipart", subtype, _headers, opts_tuple)
      when subtype in ["form-data", "mixed"] do
    try do
      parse_multipart(conn, opts_tuple)
    rescue
      # Do not ignore upload errors
      e in [Plug.UploadError, Plug.Parsers.BadEncodingError] ->
        reraise e, __STACKTRACE__

      # All others are wrapped
      e ->
        reraise Plug.Parsers.ParseError.exception(exception: e), __STACKTRACE__
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts) do
    {:next, conn}
  end

  ## Multipart

  defp parse_multipart(conn, {{module, fun, args}, header_opts, opts}) do
    limit = apply(module, fun, args)
    parse_multipart(conn, {limit, header_opts, opts})
  end

  defp parse_multipart(conn, {limit, headers_opts, opts}) do
    read_result = Plug.Conn.read_part_headers(conn, headers_opts)
    {:ok, limit, acc, conn} = parse_multipart(read_result, limit, opts, headers_opts, [])

    if limit > 0 do
      {:ok, Enum.reduce(acc, %{}, &Plug.Conn.Query.decode_pair/2), conn}
    else
      {:error, :too_large, conn}
    end
  end

  defp parse_multipart({:ok, headers, conn}, limit, opts, headers_opts, acc) when limit >= 0 do
    {conn, limit, acc} = parse_multipart_headers(headers, conn, limit, opts, acc)
    read_result = Plug.Conn.read_part_headers(conn, headers_opts)
    parse_multipart(read_result, limit, opts, headers_opts, acc)
  end

  defp parse_multipart({:ok, _headers, conn}, limit, _opts, _headers_opts, acc) do
    {:ok, limit, acc, conn}
  end

  defp parse_multipart({:done, conn}, limit, _opts, _headers_opts, acc) do
    {:ok, limit, acc, conn}
  end

  defp parse_multipart_headers(headers, conn, limit, opts, acc) do
    case multipart_type(headers, opts) do
      {:binary, name} ->
        {:ok, limit, body, conn} =
          parse_multipart_body(Plug.Conn.read_part_body(conn, opts), limit, opts, "")

        if Keyword.get(opts, :validate_utf8, true) do
          Plug.Conn.Utils.validate_utf8!(body, Plug.Parsers.BadEncodingError, "multipart body")
        end

        {conn, limit, [{name, body} | acc]}

      {:part, name} ->
        {:ok, limit, body, conn} =
          parse_multipart_body(Plug.Conn.read_part_body(conn, opts), limit, opts, "")

        {conn, limit, [{name, %{headers: headers, body: body}} | acc]}

      {:file, name, upload} ->
        upload = apply(upload.adapter.__struct__, :start, [upload, opts[:adapter_opts]])

        {:ok, limit, conn, upload} =
          parse_multipart_file(Plug.Conn.read_part_body(conn, opts), limit, opts, upload)

        upload = apply(upload.adapter.__struct__, :close, [upload, opts[:adapter_opts]])

        {conn, limit, [{name, upload} | acc]}

      :skip ->
        {conn, limit, acc}
    end
  end

  defp parse_multipart_body({:more, tail, conn}, limit, opts, body)
       when limit >= byte_size(tail) do
    read_result = Plug.Conn.read_part_body(conn, opts)
    parse_multipart_body(read_result, limit - byte_size(tail), opts, body <> tail)
  end

  defp parse_multipart_body({:more, tail, conn}, limit, _opts, body) do
    {:ok, limit - byte_size(tail), body, conn}
  end

  defp parse_multipart_body({:ok, tail, conn}, limit, _opts, body)
       when limit >= byte_size(tail) do
    {:ok, limit - byte_size(tail), body <> tail, conn}
  end

  defp parse_multipart_body({:ok, tail, conn}, limit, _opts, body) do
    {:ok, limit - byte_size(tail), body, conn}
  end

  defp parse_multipart_file({:more, tail, conn}, limit, opts, upload) do
    chunk_size = byte_size(tail)

    upload =
      apply(upload.adapter.__struct__, :write_part, [
        upload,
        tail,
        chunk_size,
        opts[:adapter_opts]
      ])

    # keep reading.
    Plug.Conn.read_part_body(conn, opts)
    |> parse_multipart_file(limit - chunk_size, opts, upload)
  end

  defp parse_multipart_file({:ok, tail, conn}, limit, opts, upload)
       when byte_size(tail) <= limit do
    chunk_size = byte_size(tail)

    upload =
      apply(upload.adapter.__struct__, :write_part, [
        upload,
        tail,
        chunk_size,
        opts[:adapter_opts]
      ])

    {:ok, limit - chunk_size, conn, upload}
  end

  defp parse_multipart_file({:ok, tail, conn}, limit, _opts, upload) do
    {:ok, limit - byte_size(tail), conn, upload}
  end

  # for a full chunk, when uploading file > 5 mb

  ## Helpers

  defp multipart_type(headers, opts) do
    if disposition = get_header(headers, "content-disposition") do
      multipart_type_from_disposition(headers, disposition, opts)
    else
      multipart_type_from_unnamed(opts)
    end
  end

  defp multipart_type_from_unnamed(opts) do
    case Keyword.fetch(opts, :include_unnamed_parts_at) do
      {:ok, name} when is_binary(name) -> {:part, name <> "[]"}
      :error -> :skip
    end
  end

  defp multipart_type_from_disposition(headers, disposition, opts) do
    with [_, params] <- :binary.split(disposition, ";"),
         %{"name" => name} = params <- Plug.Conn.Utils.params(params) do
      handle_disposition(params, name, headers, opts)
    else
      _ -> :skip
    end
  end

  defp handle_disposition(params, name, headers, opts) do
    case params do
      %{"filename" => ""} ->
        :skip

      %{"filename" => filename} ->
        content_type = get_header(headers, "content-type")
        # alternative to plug upload struct
        {:file, name, create_new_upload(filename, content_type, opts)}

      %{"filename*" => ""} ->
        :skip

      %{"filename*" => "utf-8''" <> filename} ->
        filename = URI.decode(filename)

        Plug.Conn.Utils.validate_utf8!(
          filename,
          Plug.Parsers.BadEncodingError,
          "multipart filename"
        )

        content_type = get_header(headers, "content-type")

        {:file, name, create_new_upload(filename, content_type, opts)}

      %{} ->
        {:binary, name}
    end
  end

  defp create_new_upload(filename, content_type, opts) do
    # grab adapter from options, convert to struct, and create new upload struct
    ms =
      Keyword.get(opts, :adapter, Minne.Adapter.Temp)
      |> struct()
      |> Minne.Upload.new()
      |> Map.merge(%{
        filename: filename,
        content_type: content_type
      })

    apply(ms.adapter.__struct__, :init, [ms, opts[:adapter_opts]])
  end

  def get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end
end
