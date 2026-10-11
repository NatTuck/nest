defmodule Nest.Tools.ShellPipes do
  @moduledoc """
  Rejects `shell-cmd` commands that pipe a command's output into `head`, `tail`,
  or `grep`.

  Models habitually pipe a command's output into `head`/`tail`/`grep`, most
  often on long-running commands, which discards almost all of the output. It
  does not help with context management — the `shell-cmd` tool already caps its
  result size and substitutes a path-and-head summary when a result is too large
  — and it defeats output streaming. There is deliberately no escape hatch: a
  model that genuinely needs to filter output can write a script and run that.

  ## Detection

  The command is tokenized by a quote- and heredoc-aware scanner, then walked to
  find the command word of every pipeline stage: the word that follows an
  unquoted `|` or `|&`, after skipping `NAME=value` assignments and redirection
  targets. A stage whose command word is `head`, `tail`, or `grep` (compared by
  basename, so `/usr/bin/head` counts) is rejected.

  The scanner tracks single quotes, double quotes, backslash escapes, `#`
  comments, and heredoc bodies, so none of these is a false positive:

      head -1 file          # head is not piped to
      grep foo file         # grep is not piped to
      cat head.txt          # head is a filename
      echo "| head"         # inside double quotes
      echo 'a | grep b'     # inside single quotes
      cat <<'EOF'           # heredoc body — the "write a script" workaround
      ls | head
      EOF

  `||` (logical or) and `&&`/`;`/`&` are not pipes and never match. A newline or
  an opening paren while a command is still expected does not end the stage —
  bash reads

      ls |
      head

  as `ls | head`, and `ls | (head)` pipes into the subshell's first command.

  Command substitution is inspected unless it sits inside double quotes: the
  contents of a backtick substitution and of an unquoted `$(...)` are scanned
  like ordinary shell code, so `` `ls | head` `` and `$(ls | head)` are
  rejected. A substitution inside double quotes (`"$(...)"`) is not.

  Known limitations (misses, never false positives): the pager must be the
  stage's own command word, so one reached indirectly is not caught — behind a
  wrapper (`env`, `nice`, `sudo`, `command`, `timeout`, `stdbuf`, `busybox`, or
  `sh -c '...'`), inside a brace group (`ls | { head; }`), or in an `if`/`case`
  stage. `ls | xargs head` is likewise not caught, but it does not discard the
  piped output the way a plain `| head` does.

  A heredoc whose delimiter is a parameter expansion (`cat <<$F`) is not
  recognised: its terminator cannot be known at token level, so the remainder of
  the input is treated as the body (a miss, never a false positive).
  """

  # Command names whose pipeline use discards output.
  @pager_commands ~w(head tail grep)

  # Operators that consume the following word as their target (a filename or a
  # heredoc delimiter). The walk skips that word.
  @redirection_ops ~w[> >> < << <<- <<< <> >& <& &> &>>]

  # Shell operators, longest first so `&>>` wins over `&>`, `<<-` over `<<`, and
  # so on. `take_operator/1` returns the first prefix that matches.
  @operators ~w[&>> <<< <<- &> && >> >& << <& <> |& || & > < ; ( ) |]

  # The `NAME=value` prefix of a simple command.
  @assignment ~r/^[A-Za-z_][A-Za-z0-9_]*=/

  @doc """
  Returns `:ok`, or `{:error, message}` when `command` is not a string or pipes
  output into `head`, `tail`, or `grep`.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(command) when is_binary(command) do
    case piped_pager(command) do
      nil -> :ok
      name -> {:error, message(name)}
    end
  end

  # The tool's schema only checks that the `command` key is present, so a
  # non-string value (a list, a number) reaches here. Reject it with the same
  # shape as the `timeout` validation rather than letting `ShellCmd` crash on
  # `String.length/1` and leak a staged script.
  def check(other), do: {:error, invalid_command_message(other)}

  # ---- pipeline walk ----

  defp piped_pager(command) do
    command |> tokenize() |> drop_fd_numbers() |> find_pager(false, false)
  end

  # In `cmd | 2>/dev/null head` the `2` is a file-descriptor prefix, not the
  # stage's command word. Drop it when a redirection follows so the walk sees
  # the redirection (and then `head`). `2` as an ordinary argument (`echo 2`)
  # has no following redirection and is left alone.
  defp drop_fd_numbers([{:word, word}, {:op, op} | rest]) when op in @redirection_ops do
    if fd_number?(word) do
      drop_fd_numbers([{:op, op} | rest])
    else
      [{:word, word} | drop_fd_numbers([{:op, op} | rest])]
    end
  end

  defp drop_fd_numbers([token | rest]), do: [token | drop_fd_numbers(rest)]
  defp drop_fd_numbers([]), do: []

  defp fd_number?(word), do: String.match?(word, ~r/^\d+$/)

  # Walk the token stream. `stage` is:
  #
  #   * `false`    — not expecting a pipeline command
  #   * `:fresh`   — immediately after a pipe with nothing consumed yet, so a
  #                  newline is a continuation (`ls |` + newline + `head` is
  #                  `ls | head`)
  #   * `:started` — after the pipe but past an assignment or redirection, so a
  #                  newline ends the stage (`ls | 2>/dev/null` + newline +
  #                  `head` runs `head` as a separate command)
  #
  # `skip` is true when the next word is a redirection target, not a command.
  defp find_pager([], _stage, _skip), do: nil

  # Every operator is a pipe, a redirection, or a stage separator (`;`, `&&`,
  # `||`, `&`, a newline, or a subshell paren), so the last branch is total.
  defp find_pager([{:op, op} | rest], stage, _skip) do
    cond do
      op in ["|", "|&"] -> find_pager(rest, :fresh, false)
      op == "\n" and stage == :fresh -> find_pager(rest, :fresh, false)
      op == "(" and stage != false -> find_pager(rest, stage, false)
      op in @redirection_ops -> find_pager(rest, consumed(stage), true)
      true -> find_pager(rest, false, false)
    end
  end

  defp find_pager([{:word, word} | rest], stage, skip) do
    cond do
      skip -> find_pager(rest, stage, false)
      stage == false -> find_pager(rest, false, false)
      Regex.match?(@assignment, word) -> find_pager(rest, consumed(stage), false)
      true -> pager_name(word) || find_pager(rest, false, false)
    end
  end

  # An assignment or redirection is content in the stage.
  defp consumed(false), do: false
  defp consumed(_stage), do: :started

  defp pager_name(word) do
    base = Path.basename(word)
    if base in @pager_commands, do: base
  end

  defp message(name) do
    "Refused: `shell-cmd` will not pipe command output into `#{name}`. " <>
      "Piping to head, tail, or grep discards most of the command's output, and " <>
      "the tool already limits how much it returns: an oversized result is saved " <>
      "to a scratch file and summarised by its path and head lines. " <>
      "Re-run the command without the pipe."
  end

  defp invalid_command_message(other) do
    "Invalid `command` argument: expected a string, got: " <> inspect(other) <> "."
  end

  # ---- tokenizer ----
  #
  # `tokenize/1` returns `{:word, binary}` and `{:op, binary}` tokens in order.
  # Quotes are stripped from words; operators are returned as written. Heredoc
  # bodies and `#` comments are skipped, so their contents never become tokens.

  defp tokenize(command), do: scan(command, :normal, [], [], [])

  defp scan(<<>>, _mode, word, tokens, _pending), do: Enum.reverse(flush(word, tokens))

  # -- normal mode --

  # A backslash-newline is a line continuation: it disappears, so it neither
  # joins nor splits words.
  defp scan(<<"\\\n", rest::binary>>, :normal, word, tokens, pending),
    do: scan(rest, :normal, word, tokens, pending)

  defp scan(<<"\\", char, rest::binary>>, :normal, word, tokens, pending),
    do: scan(rest, :normal, [word, char], tokens, pending)

  defp scan(<<"\\">>, :normal, word, tokens, pending),
    do: scan(<<>>, :normal, [word, "\\"], tokens, pending)

  defp scan(<<"'", rest::binary>>, :normal, word, tokens, pending),
    do: scan(rest, :single, word, tokens, pending)

  defp scan(<<"\"", rest::binary>>, :normal, word, tokens, pending),
    do: scan(rest, :double, word, tokens, pending)

  # A backtick runs a command substitution whose contents are ordinary shell
  # code. Treat it as a word boundary (the contents are scanned like any other
  # code) so `` `ls | head` `` behaves like `$(ls | head)`, instead of gluing
  # the backtick onto the command word (`head` + backtick) and hiding the pager.
  defp scan(<<"`", rest::binary>>, :normal, word, tokens, pending),
    do: scan(rest, :normal, [], flush(word, tokens), pending)

  # `$((...))` and `((...))` are arithmetic: a `<<` inside them is a shift, not
  # a heredoc, and the expression is not shell code. Consume it whole.
  defp scan(<<"$((", rest::binary>>, :normal, word, tokens, pending),
    do: scan(skip_arith(rest, 0), :normal, [], flush(word, tokens), pending)

  defp scan(<<"((", rest::binary>>, :normal, word, tokens, pending),
    do: scan(skip_arith(rest, 0), :normal, [], flush(word, tokens), pending)

  # `#` starts a comment only at the start of a word, matching bash.
  defp scan(<<"#", rest::binary>>, :normal, [], tokens, pending),
    do: scan(skip_comment(rest), :normal, [], tokens, pending)

  defp scan(<<char, rest::binary>>, :normal, word, tokens, pending) when char in [?\s, ?\t],
    do: scan(rest, :normal, [], flush(word, tokens), pending)

  defp scan(<<"\n", rest::binary>>, :normal, word, tokens, pending) do
    tokens = push_op(flush(word, tokens), "\n")
    {rest, _pending} = skip_heredocs(rest, pending)
    scan(rest, :normal, [], tokens, [])
  end

  defp scan(input, :normal, word, tokens, pending),
    do: scan_operator(input, word, tokens, pending)

  # -- single quotes: everything is literal until the closing quote --

  defp scan(<<"'", rest::binary>>, :single, word, tokens, pending),
    do: scan(rest, :normal, word, tokens, pending)

  defp scan(<<char, rest::binary>>, :single, word, tokens, pending),
    do: scan(rest, :single, [word, char], tokens, pending)

  # -- double quotes: `\` escapes, everything else is literal --

  defp scan(<<"\\\n", rest::binary>>, :double, word, tokens, pending),
    do: scan(rest, :double, word, tokens, pending)

  defp scan(<<"\\", char, rest::binary>>, :double, word, tokens, pending),
    do: scan(rest, :double, [word, char], tokens, pending)

  defp scan(<<"\\">>, :double, word, tokens, pending),
    do: scan(<<>>, :double, [word, "\\"], tokens, pending)

  defp scan(<<"\"", rest::binary>>, :double, word, tokens, pending),
    do: scan(rest, :normal, word, tokens, pending)

  defp scan(<<char, rest::binary>>, :double, word, tokens, pending),
    do: scan(rest, :double, [word, char], tokens, pending)

  defp scan_operator(input, word, tokens, pending) do
    case take_operator(input) do
      {:ok, op, rest} when op in ["<<", "<<-"] ->
        heredoc(rest, op == "<<-", word, tokens, pending)

      {:ok, op, rest} ->
        scan(rest, :normal, [], push_op(flush(word, tokens), op), pending)

      :error ->
        <<char, rest::binary>> = input
        scan(rest, :normal, [word, char], tokens, pending)
    end
  end

  # ---- heredocs ----

  # `<<`/`<<-` starts a heredoc only when a delimiter follows; otherwise (for
  # example `<< | head`) the operator is emitted as-is.
  defp heredoc(rest, strip_tabs, word, tokens, pending) do
    op = if strip_tabs, do: "<<-", else: "<<"

    case take_heredoc_delim(rest) do
      {:ok, delim, rest} ->
        scan(
          rest,
          :normal,
          [],
          push_op(flush(word, tokens), op),
          pending ++ [{delim, strip_tabs}]
        )

      :unknown ->
        # The delimiter is a parameter expansion (`cat <<$F`), so the body's
        # terminator cannot be known at token level. Stop scanning here: the
        # remainder is treated as the body, so a pipe inside it is a miss,
        # never a false positive.
        Enum.reverse(push_op(flush(word, tokens), op))

      :error ->
        scan(rest, :normal, [], push_op(flush(word, tokens), op), pending)
    end
  end

  # Returns `{:ok, delim, rest}` for a delimiter, `:unknown` when the delimiter
  # is a parameter expansion (bash resolves it, so we cannot), or `:error` when
  # this `<<` is not a heredoc at all. A leading `\` quotes the delimiter
  # (`<<\EOF`), and a quoted delimiter is read to its matching quote so
  # `<<'E OF'` works.
  defp take_heredoc_delim(input) do
    input = skip_blanks(input)

    case input do
      <<"\\", rest::binary>> -> unquoted_delim(rest)
      <<quote, rest::binary>> when quote in [?', ?"] -> take_quoted_delim(quote, rest, [])
      _ -> unquoted_delim(input)
    end
  end

  defp unquoted_delim(<<?$, _rest::binary>>), do: :unknown

  defp unquoted_delim(input) do
    case take_word(input) do
      {"", _rest} -> :error
      {delim, rest} -> {:ok, delim, rest}
    end
  end

  defp take_quoted_delim(?', <<"'", rest::binary>>, acc),
    do: {:ok, IO.iodata_to_binary(acc), rest}

  defp take_quoted_delim(?", <<"\"", rest::binary>>, acc),
    do: {:ok, IO.iodata_to_binary(acc), rest}

  defp take_quoted_delim(quote, <<char, rest::binary>>, acc),
    do: take_quoted_delim(quote, rest, [acc, char])

  defp take_quoted_delim(_quote, <<>>, _acc), do: :error

  # Consume an arithmetic expression up to its closing `))`, tracking nested
  # parens. Returns the input after the pair (or `<<>>` when unterminated).
  defp skip_arith(<<"(", rest::binary>>, depth), do: skip_arith(rest, depth + 1)
  defp skip_arith(<<")", ")", rest::binary>>, 0), do: rest
  defp skip_arith(<<")", rest::binary>>, depth) when depth > 0, do: skip_arith(rest, depth - 1)
  defp skip_arith(<<_char, rest::binary>>, depth), do: skip_arith(rest, depth)
  defp skip_arith(<<>>, _depth), do: <<>>

  defp skip_blanks(<<char, rest::binary>>) when char in [?\s, ?\t], do: skip_blanks(rest)
  defp skip_blanks(input), do: input

  defp take_word(input), do: take_word(input, [])

  defp take_word(<<char, rest::binary>>, acc)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_,
       do: take_word(rest, [acc, char])

  defp take_word(rest, acc), do: {IO.iodata_to_binary(acc), rest}

  # After a newline, consume heredoc bodies: skip lines until each pending
  # delimiter is seen, in order.
  defp skip_heredocs(input, []), do: {input, []}

  defp skip_heredocs(input, [{delim, strip_tabs} | pending]) do
    case take_line(input) do
      {line, rest} ->
        if heredoc_terminator?(line, delim, strip_tabs) do
          skip_heredocs(rest, pending)
        else
          skip_heredocs(rest, [{delim, strip_tabs} | pending])
        end

      :eof ->
        {<<>>, []}
    end
  end

  defp take_line(input) do
    case :binary.split(input, "\n") do
      [line, rest] -> {line, rest}
      [_line] -> :eof
    end
  end

  defp heredoc_terminator?(line, delim, true), do: String.trim_leading(line, "\t") == delim
  defp heredoc_terminator?(line, delim, false), do: line == delim

  # Skip a `#` comment, keeping the terminating newline so the caller still
  # processes it (and any pending heredocs).
  defp skip_comment(input) do
    case :binary.split(input, "\n") do
      [_comment, rest] -> <<"\n", rest::binary>>
      [_comment] -> <<>>
    end
  end

  # ---- operators ----

  defp take_operator(input) do
    Enum.find_value(@operators, :error, fn op ->
      size = byte_size(op)

      case input do
        <<prefix::binary-size(size), rest::binary>> when prefix == op -> {:ok, op, rest}
        _ -> nil
      end
    end)
  end

  # ---- token helpers ----

  defp flush([], tokens), do: tokens
  defp flush(word, tokens), do: [{:word, IO.iodata_to_binary(word)} | tokens]

  defp push_op(tokens, op), do: [{:op, op} | tokens]
end
