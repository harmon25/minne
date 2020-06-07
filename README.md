# Minne

Multipart form parser for plug based applications that allows customizing the file handling behaviour.
To be used as a replacement for the built in :multipart handler.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `minne` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:minne, "~> 0.1.0"}
  ]
end
```

## Usage

Tweak your `Plug.Parsers` config to include `Minne`

### S3

Requires `ExAws.S3` and its dependencies.

Will upload the file to S3 directly, never hitting the servers hardrive.

```elixir
plug(Plug.Parsers,
  parsers: [
    {
      Minne,
      adapter: Minne.Adapter.S3
      adapter_opts: [bucket: "some-bucket", upload_prefix: "upload"],
    },
    :urlencoded,
    :json
  ],
  json_decoder: Jason
)
```

### Temp

This behaves almost identically to the built in `Plug.Upload`, and writes the files to temp.

```elixir
plug(Plug.Parsers,
  parsers: [
    {
      Minne,
      adapter: Minne.Adapter.Temp
    },
    :urlencoded,
    :json
  ],
  json_decoder: Jason
)
```

### From the Controller

The built-in `Plug.Parsers.MULTIPART` represents files parsed from the body as a `Plug.Upload` struct.
Minne does similar, but is instead a `Minne.Upload`, it is not a drop in replacment for `Plug.Upload`, but would not be hard to adapt code to use it.
