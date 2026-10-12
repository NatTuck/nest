defmodule Nest.Test.MaxCases do
  @moduledoc """
  `max_cases` for the suite: the **physical** core count, not the logical one.

  The suite is contention-bound — measured on the reference host: 8 cases gave 0
  failures, 16 gave 2, 24 gave 12 — so over-subscribing the schedulers is what
  produces fence misses. `System.schedulers_online/0` returns *logical* CPUs,
  which on an SMT host is 2x the real core count.

  The ratio comes from `/proc/cpuinfo` in one read: `real = logical / (siblings /
  cpu cores)`.

    * vampire: `32 / (32/16)` = **16**
    * celedyr: `24 / (12/12)` = **24**

  **Do not count unique `(physical_package_id, core_id)` pairs instead.** That is
  the textbook method and it is wrong on celedyr, an AMD Opteron 6234
  (Bulldozer/Interlagos): its 12 "cores" per socket are 6 modules x 2 integer
  cores sharing one FPU, and the kernel reports `core id` per *module* (0-5), so
  both sysfs and the cpuinfo topology IDs say 12 where the truth is 24.
  `siblings == cpu cores` is the field pair that correctly says "no SMT here".

  Test-only. `siblings`/`cpu cores` are generally absent on ARM; there we fall back
  to `System.schedulers_online/0` (i.e. assume no SMT).
  """

  @cpuinfo "/proc/cpuinfo"

  @spec real_cpus() :: pos_integer()
  def real_cpus do
    logical = System.schedulers_online()

    with text when is_binary(text) <- read_cpuinfo(),
         siblings when is_integer(siblings) <- field(text, "siblings"),
         cores when is_integer(cores) <- field(text, "cpu cores"),
         true <- siblings > 0 and cores > 0 do
      max(1, div(logical * cores, siblings))
    else
      _ -> logical
    end
  end

  defp read_cpuinfo do
    case File.read(@cpuinfo) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  # One scan, first match: `siblings` and `cpu cores` are constants of the first
  # processor block, so the first occurrence is the answer.
  defp field(text, key) do
    case Regex.run(~r/^#{key}\s*:\s*(\d+)/m, text) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end
end
