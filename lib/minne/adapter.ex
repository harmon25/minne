defmodule Minne.Adapter do
  @moduledoc """
  This module also specifies a behaviour that all the file writing adapters used with MultiStream should adopt.
  """
  alias Minne.Upload
  @type opts :: Keyword.t()

  @callback default_opts() :: Keyword.t()
  @callback init(Upload.t(), opts) :: Upload.t()
  @callback start(Upload.t(), opts) :: Upload.t()
  @callback write_part(Upload.t(), chunk :: binary(), size :: non_neg_integer(), opts) ::
              Upload.t()
  @callback close(Upload.t(), opts) :: Upload.t()
end
