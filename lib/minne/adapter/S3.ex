defmodule Minne.Adapter.S3 do
  alias Minne.Upload
  @behaviour Minne.Adapter

  @min_chunk 5_242_880

  @type t() :: %__MODULE__{
          key: String.t(),
          bucket: String.t(),
          parts: list(),
          parts_count: non_neg_integer(),
          upload_id: String.t() | nil
        }

  defstruct key: "",
            bucket: "",
            parts: [],
            parts_count: 0,
            upload_id: nil

  @impl Minne.Adapter
  def default_opts() do
    # might want to make this length adjustable, but for the most part, is OK as S3 can handle pretty much anything.
    [length: 16_000_000_000, read_length: @min_chunk]
  end

  @impl Minne.Adapter
  def init(upload, opts) do
    %{
      upload
      | adapter: %{upload.adapter | key: gen_key(opts), bucket: opts[:bucket]}
    }
  end

  @impl Minne.Adapter
  def start(upload, _opts) do
    upload
  end

  @impl Minne.Adapter
  def write_part(
        %{adapter: %__MODULE__{parts_count: parts_count}} = upload,
        chunk,
        size,
        _opts
      )
      when size < @min_chunk and parts_count == 0 do
    ExAws.S3.put_object(upload.adapter.bucket, upload.adapter.key, chunk,
      content_disposition: "attachment; filename=\"#{upload.filename}\""
    )
    |> ExAws.request!()

    %{
      upload
      | size: size + upload.size
    }
  end

  def write_part(%{} = upload, chunk, size, _opts) do
    upload |> set_upload_id() |> upload_part(size, chunk)
  end

  @impl Minne.Adapter
  def close(%{adapter: %{upload_id: nil}} = upload, _opts) do
    upload
  end

  def close(
        %{
          adapter: %{upload_id: upload_id, bucket: bucket, key: key, parts: parts} = adapter
        } = upload,
        _opts
      ) do
    reversed_parts = Enum.map(parts, &Task.await/1) |> Enum.reverse()

    ExAws.S3.complete_multipart_upload(
      bucket,
      key,
      upload_id,
      reversed_parts
    )
    |> ExAws.request!()

    %{upload | adapter: %{adapter | parts: reversed_parts}}
  end

  defp set_upload_id(%{adapter: %{upload_id: nil, bucket: bucket, key: key} = adapter} = uploaded) do
    %{body: %{upload_id: upload_id}} =
      ExAws.S3.initiate_multipart_upload(bucket, key,
        content_disposition: "attachment; filename=\"#{uploaded.filename}\""
      )
      |> ExAws.request!()

    %{uploaded | adapter: %{adapter | upload_id: upload_id}}
  end

  defp set_upload_id(%{adapter: %{upload_id: _upload_id}} = uploaded), do: uploaded

  defp gen_key(opts) do
    prefix = Keyword.get(opts, :upload_prefix, "upload")
    key_generator = Keyword.get(opts, :key_generator, &default_key_generator/0)

    Path.join([prefix, key_generator.()])
  end

  defp default_key_generator() do
    :crypto.strong_rand_bytes(64) |> Base.url_encode64() |> binary_part(0, 32)
  end

  defp upload_part(%{} = uploaded, size, body) do
    parts_count = uploaded.adapter.parts_count + 1

    new_part_async = upload_async(uploaded, parts_count, body)

    %{
      uploaded
      | size: size + uploaded.size,
        adapter: %{
          uploaded.adapter
          | parts_count: parts_count,
            parts: [new_part_async | uploaded.adapter.parts]
        }
    }
  end

  # launches async task to upload this part.
  defp upload_async(uploaded, parts_count, body) do
    Task.async(fn ->
      %{headers: headers} =
        ExAws.S3.upload_part(
          uploaded.adapter.bucket,
          uploaded.adapter.key,
          uploaded.adapter.upload_id,
          parts_count,
          body
        )
        |> ExAws.request!()

      {parts_count, Minne.get_header(headers, "ETag")}
    end)
  end
end
