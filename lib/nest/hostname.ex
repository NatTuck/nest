defmodule Nest.Hostname do
  @moduledoc """
  The short hostname of the machine this instance runs on.

  Nest is expected to run on more than one machine — `vampire` and
  `typhon`, say — against different projects. Two instances are
  indistinguishable in a browser once their tabs are open: the shell
  HTML is identical and only the page content differs. The tab is the
  one piece of chrome that is readable without looking at the page, so
  the root layout titles every page with the instance hostname (see
  `lib/nest_web/components/layouts/root.html.heex`) and hands the same
  string to the client as `window.NEST_CONFIG.host`. The icon is the app's
  own mark (`priv/static/favicon.svg`) rather than Phoenix's stock one —
  the same file on every instance.

  The value is `config :nest, :hostname` when that is a non-empty
  string, otherwise the short name from `:inet.gethostname/0`:

      config :nest, :hostname, "vampire"

  The override exists for hosts whose BEAM hostname is not what an
  operator would recognise (a container id, for instance). Tests pin it
  (see `config/test.exs`) so they never assert against the machine they
  happen to run on.

  When neither source yields a name the literal `"[missing host]"` is
  returned: a tab that says nothing at all is worse than one that says
  the host is unknown, so the value is never omitted.
  """

  @missing_host "[missing host]"

  @doc """
  The hostname for this instance, or `"[missing host]"`.
  """
  @spec get() :: String.t()
  def get, do: get(Application.get_env(:nest, :hostname))

  @doc """
  As `get/0`, with the configured override supplied directly.

  Reading the override is this module's only impure step, and it is a
  VM-global `Application` read. A test that exercises the fallback would
  therefore have to mutate that global — forcing it, and anything that reads
  the same config, out of the concurrent phase. Taking the value as an argument
  is the same injected-seam shape as `Nest.Hardware.hpu_device_paths/2`, and
  leaves `get/0` as the only caller that touches the global.

  `nil` and `""` both mean "no usable override", matching `get/0`'s
  interpretation of an unset or blank config value.
  """
  @spec get(String.t() | nil) :: String.t()
  def get(override) do
    case override do
      hostname when is_binary(hostname) and hostname != "" -> hostname
      _ -> system_hostname()
    end
  end

  defp system_hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> @missing_host
    end
  end
end
