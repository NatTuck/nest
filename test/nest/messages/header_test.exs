defmodule Nest.Messages.HeaderTest do
  @moduledoc """
  The header's grammar: what `line/3` writes, what `parse/1` accepts, and the pin
  that keeps the client's parser in step with both.

  The format has one spec — `Nest.Messages.Header`'s moduledoc — and two
  implementations: this module and `assets/js/utils/header.js`. The pin at the
  bottom runs the **client's own parser** over this module's output, through
  `node`, so the two cannot drift; a copy of the regex on either side would only
  prove the copy agrees with itself.

  Which rows carry a header, and what each says, is
  `test/nest/agents/agent/header_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Header
  alias Nest.Messages.User

  describe "line/3" do
    test "writes every shape the grammar has" do
      assert Header.line(:user, "act") == "[From user | mode: act]"
      assert Header.line({:user, "nat"}, "act") == "[From user @nat | mode: act]"

      assert Header.line({:user, "nat"}, "act", true) ==
               "[From user @nat, agents-send reply required | mode: act]"

      assert Header.line({:agent, "crazy-dolphin"}, "plan") ==
               "[From agent crazy-dolphin | mode: plan]"

      assert Header.line({:agent, nil}, "plan") == "[From agent | mode: plan]"
      assert Header.line(:runtime, "compact") == "[From nest runtime | mode: compact]"
    end

    test "refuses a name or a mode the grammar cannot carry" do
      # The header has no escaping: a name holding the separator, the closing
      # bracket or a newline would either parse as something else or not parse at
      # all. A name that is not a `Nest.Name` is a bug upstream, so it is refused
      # here rather than escaped silently — an escape would hide the bug and
      # still leave the client unable to read the line.
      for bad <- ["a | b", "a]b", "a\nb", "Nat", "a,b"] do
        assert_raise ArgumentError, ~r/sender name must be a Nest.Name/, fn ->
          Header.line({:agent, bad}, "act")
        end

        assert_raise ArgumentError, ~r/sender name must be a Nest.Name/, fn ->
          Header.line({:user, bad}, "act")
        end
      end

      for bad <- ["a | b", "a]b", "act\n", ""] do
        assert_raise ArgumentError, ~r/mode must be/, fn -> Header.line(:runtime, bad) end
      end

      # An empty name is *no* name, not an invalid one: `sender/3` produces
      # `{:agent, ""}` for a producer with no name, and the row says `agent`
      # rather than a stray `@`.
      assert Header.line({:agent, ""}, "act") == "[From agent | mode: act]"
      assert Header.line({:user, ""}, "act") == "[From user | mode: act]"
    end
  end

  describe "parse/1" do
    test "reads back every shape line/3 writes" do
      senders = [
        :user,
        {:user, "nat"},
        {:user, "nat_x"},
        {:agent, "crazy-dolphin"},
        {:agent, nil},
        :runtime
      ]

      for sender <- senders,
          mode <- Nest.Modes.names() ++ [User.compaction_mode()],
          reply <- [false, true] do
        line = Header.line(sender, mode, reply)

        assert Header.parse(line) ==
                 {:ok, %{sender: sender, reply_required: reply, mode: mode}},
               line
      end
    end

    test "reads the header at the head of a text, and only there" do
      assert Header.parse("[From user @nat | mode: act]\nthe body\n") ==
               {:ok, %{sender: {:user, "nat"}, reply_required: false, mode: "act"}}

      # A header is the first line: one quoted mid-text is content.
      assert Header.parse("hello\n[From user | mode: act]") == :error
    end

    test "refuses what line/3 could not have written" do
      for bad <- [
            # not this format at all — the retired markers are the client's
            # compat path, and they are not headers
            ~s([Message from agent "x"]),
            "[nest notice]",
            "[mode: act]",
            "no header at all",
            "",
            # a name or a mode outside the charset. Hand-made: `line/3` raises,
            # so nothing in the app can produce one — which is exactly why the
            # parser must not read one as a header.
            "[From agent a | b | mode: act]",
            "[From user @a b | mode: act]",
            "[From agent a]b | mode: act]",
            "[From user | mode: a | b]",
            "[From user | mode: ]",
            # structure
            "[From | mode: act]",
            "[From user | mode: act",
            "[From user mode: act]",
            "[From user | mode: act] trailing",
            "[From user, agents-send reply required, agents-send reply required | mode: act]"
          ] do
        assert Header.parse(bad) == :error, bad
      end
    end
  end

  describe "the readers, through the parser" do
    test "body/1 needs a header that parses, not one that merely starts right" do
      assert Header.body("[From user | mode: act]\nhello") == "hello"

      # A line that only looks like a header keeps its text: `body/1` is the
      # parser now, so a malformed row is not truncated.
      assert Header.body("[From the top] of my head\nhello") == nil
      assert Header.body("[From agent a | b | mode: act]\nhello") == nil
      assert Header.body("[From user | mode: act]") == nil
    end

    test "runtime?/1 is the parsed sender, not a prefix match" do
      assert Header.runtime?("[From nest runtime | mode: act]")
      assert Header.runtime?("[From nest runtime, agents-send reply required | mode: act]")

      # A name that merely starts with the runtime's is somebody else.
      refute Header.runtime?("[From nest runtimex | mode: act]")
      refute Header.runtime?("[From agent nest runtime | mode: act]")
      refute Header.runtime?("[From nest runtime | mode: act] and more")
    end
  end

  describe "the client's parser" do
    # `assets/` is an ES module tree (`"type": "module"`), so `node` can import
    # the very module the browser bundle uses — the pin is the client's code, not
    # a copy of it. One process, no build step.
    @client_parser """
    import { readFileSync } from "node:fs";
    import { parseHeaderLine } from "./js/utils/header.js";
    const lines = JSON.parse(readFileSync(process.argv[1], "utf8"));
    console.log(JSON.stringify(lines.map((line) => parseHeaderLine(line))));
    """

    test "accepts exactly what the writer writes" do
      senders = [
        {:user, %{"kind" => "human", "name" => nil}},
        {{:user, "nat"}, %{"kind" => "human", "name" => "nat"}},
        {{:user, "nat_x"}, %{"kind" => "human", "name" => "nat_x"}},
        {{:agent, "crazy-dolphin"}, %{"kind" => "agent", "name" => "crazy-dolphin"}},
        {{:agent, nil}, %{"kind" => "agent", "name" => nil}},
        {:runtime, %{"kind" => "runtime", "name" => nil}}
      ]

      shapes =
        for {sender, client_sender} <- senders,
            mode <- Nest.Modes.names() ++ [User.compaction_mode()],
            reply <- [false, true] do
          {Header.line(sender, mode, reply),
           %{"sender" => client_sender, "replyRequired" => reply, "mode" => mode}}
        end

      for {{line, expected}, actual} <-
            Enum.zip(shapes, parse_with_client(Enum.map(shapes, &elem(&1, 0)))) do
        assert actual == expected, "the client read #{inspect(line)} as #{inspect(actual)}"
      end
    end

    test "rejects a line the writer refuses to make" do
      # Both sides refuse the name, so a hand-made line cannot smuggle a clause
      # into a row: the writer raises, and the parser does not see a header.
      assert_raise ArgumentError, fn -> Header.line({:agent, "a | b"}, "act") end

      assert [nil, nil] =
               parse_with_client([
                 "[From agent a | b | mode: act]",
                 "[From user | mode: a | b]"
               ])

      assert Header.parse("[From agent a | b | mode: act]") == :error
    end
  end

  defp parse_with_client(lines) do
    path =
      Path.join(
        System.tmp_dir!(),
        "nest-tmp-header-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(lines))
    on_exit(fn -> File.rm(path) end)

    {output, status} =
      System.cmd("node", ["--input-type=module", "-e", @client_parser, path],
        cd: Path.join(File.cwd!(), "assets"),
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("the client's parser could not run: #{output}")

    Jason.decode!(output)
  end
end
