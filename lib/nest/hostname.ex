defmodule Nest.Hostname do
  @moduledoc """
  The name this instance is known by: the machine's, plus its instance number.

  Nest is expected to run on more than one machine — `vampire` and `typhon`, say
  — against different projects, and **more than one instance per machine**. Two
  instances are indistinguishable in a browser once their tabs are open: the
  shell HTML is identical and only the page content differs. The tab is the one
  piece of chrome that is readable without looking at the page, so the root
  layout titles every page with this name (see
  `lib/nest_web/components/layouts/root.html.heex`) and hands the same string to
  the client as `window.NEST_CONFIG.host`. The icon is the app's own mark
  (`priv/static/favicon.svg`) rather than Phoenix's stock one — the same file on
  every instance.

  ## The value

  `config :nest, :hostname` when that is a non-empty string, otherwise the short
  name from `:inet.gethostname/0`:

      config :nest, :hostname, "vampire"

  The override exists for hosts whose BEAM hostname is not what an operator would
  recognise (a container id, for instance). Tests pin it (see `config/test.exs`)
  so they never assert against the machine they happen to run on.

  Then the checkout's **instance number**, when it has one, is appended:
  `config :nest, :instance`, which `config/dev.exs` derives from the dev database
  name (`Nest.Config.Checkout.instance/0`). So the `nest2` checkout's tabs read
  `vampire2` and `scripts/start-instance.sh 7`'s read `vampire7`, while the
  primary checkout's stay `vampire`. A machine name alone cannot separate two
  instances of one machine, which is the same problem the host was added to
  solve across machines (`notes/issue-14-page-title.md`).

  `config :nest, :instance` is unset in production, where there is one instance
  per host and `config/dev.exs` is not loaded.

  When neither host source yields a name the literal `"[missing host]"` is
  returned, and the instance number is still appended to it: a tab that says
  nothing at all is worse than one that says the host is unknown, so the value is
  never omitted — and `[missing host]2` still tells the reader *which* instance
  it is looking at.
  """

  @missing_host "[missing host]"

  @doc """
  The name for this instance, or `"[missing host]"`.
  """
  @spec get() :: String.t()
  def get do
    get(Application.get_env(:nest, :hostname), Application.get_env(:nest, :instance))
  end

  @doc """
  As `get/0`, with both configured values supplied directly.

  Reading them is this module's only impure step, and it is a VM-global
  `Application` read. A test that exercises the fallback would therefore have to
  mutate that global — forcing it, and anything that reads the same config, out
  of the concurrent phase. Taking the values as arguments is the same
  injected-seam shape as `Nest.Hardware.hpu_device_paths/2`, and leaves `get/0`
  as the only caller that touches the global.

  `nil` and `""` both mean "no usable override", matching `get/0`'s
  interpretation of an unset or blank config value. `instance` is a number, or
  `nil` for an instance with no number.
  """
  @spec get(String.t() | nil, pos_integer() | nil) :: String.t()
  def get(override, instance) do
    host =
      case override do
        hostname when is_binary(hostname) and hostname != "" -> hostname
        _ -> system_hostname()
      end

    case instance do
      number when is_integer(number) -> host <> Integer.to_string(number)
      _ -> host
    end
  end

  defp system_hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> @missing_host
    end
  end
end
