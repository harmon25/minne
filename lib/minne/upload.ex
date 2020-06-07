defmodule Minne.Upload do
  @moduledoc """
  Similar to Plug.Upload, used internally to manage state of upload.
  Also passed to consumer after done parsing
  """

  @enforce_keys [:adapter]

  @type t() :: %__MODULE__{
          filename: String.t(),
          content_type: String.t(),
          size: non_neg_integer(),
          adapter: map() | atom() | nil
        }

  defstruct filename: "",
            content_type: "",
            size: 0,
            adapter: nil

  def new(adapter) do
    %__MODULE__{adapter: adapter}
  end
end
