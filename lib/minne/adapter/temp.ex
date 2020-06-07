defmodule Minne.Adapter.Temp do
  @behaviour Minne.Adapter
  @default_length 1_000_000

  @type t() :: %__MODULE__{
          path: String.t(),
          file: any()
        }

  defstruct path: "",
            file: nil

  @impl Minne.Adapter
  def default_opts() do
    [length: 8_000_000, read_length: @default_length]
  end

  @impl Minne.Adapter
  def init(upload, _opts) do
    path = Plug.Upload.random_file!("multipart")
    %{upload | adapter: %{upload.adapter | path: path}}
  end

  @impl Minne.Adapter
  def start(upload, _opts) do
    {:ok, file} = File.open(upload.adapter.path, [:write, :binary, :delayed_write, :raw])

    %{upload | adapter: %{upload.adapter | file: file}}
  end

  @impl Minne.Adapter
  def write_part(upload, chunk, size, _opts) do
    binwrite!(upload.adapter.file, chunk)

    %{upload | size: upload.size + size}
  end

  @impl Minne.Adapter
  def close(upload, _opts) do
    :ok = File.close(upload.adapter.file)
    %{upload | adapter: %{upload.adapter | file: nil}}
  end

  defp binwrite!(device, contents) do
    case IO.binwrite(device, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        raise Plug.UploadError,
              "could not write to file #{inspect(device)} during upload " <>
                "due to reason: #{inspect(reason)}"
    end
  end
end
