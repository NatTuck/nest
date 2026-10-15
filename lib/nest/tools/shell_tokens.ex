defmodule Nest.Tools.ShellTokens do
  @moduledoc """
  Quote- and heredoc-aware shell tokenizer and stage walk.

  Shared by the `shell-cmd` command filters — `Nest.Tools.ShellPipes` (pipes
  into `head`/`tail`) and `Nest.Tools.ShellBackground` (`setsid`, `nohup`, and
  `&`) — so the quote, comment, and heredoc rules are written and tested once.

  ## `tokenize/1`

  Returns `{:word, binary}` and `{:op, binary}` tokens in order. Quotes are
  stripped from words; operators are returned as written. Heredoc bodies and
  `#` comments are skipped, so their contents never become tokens. Operators
  are recognised longest-first, so `&&` is one token and never `&` + `&`, and
  `&>>` wins over `&>`.

  The scanner tracks single quotes, double quotes, backslash escapes, `#`
  comments, and heredoc bodies, so none of these is a false positive:

      cat head.txt          # head is a filename
      echo "| head"         # inside double quotes
      echo 'a | grep b'     # inside single quotes
      echo # | head         # inside a comment
      cat <<'EOF'           # heredoc body
      ls | head
      EOF

  Command substitution is inspected unless it sits inside double quotes: the
  contents of a backtick substitution and of an unquoted `$(...)` are scanned
  like ordinary shell code, while a substitution inside double quotes
  (`"$(...)"`) is not. `$((...))` and `((...))` are arithmetic and are consumed
  whole, so a `<<` inside them is a shift, not a heredoc.

  A heredoc delimiter undergoes quote removal only (POSIX 2.7.4), so `$` and
  backticks in it are literal: `cat <<$F` names the delimiter `$F`, and its
  body is skipped exactly as bash skips it. The one shape this tokenizer cannot
  model is a delimiter with an embedded quote or `(` (`cat <<E'OF'` is the
  delimiter `EOF` in bash, while `cat <<$(echo X)` is not resolved here); there
  it falls back to a conservative sentinel — the rest of the current line is
  still scanned, and everything from the next newline on is treated as the body
  (a miss, never a false positive).

  ## `command_words/1`

  Walks a token list and returns `{command_word, piped?}` for each simple
  command, where `piped?` is true when that command is a pipeline stage fed by
  a preceding `|` or `|&`. The command word is the first word of a stage after
  skipping `NAME=value` assignments and redirection targets.

  A newline or an opening paren while a command is still expected does not end
  the stage — bash reads

      ls |
      head

  as `ls | head`, and `ls | (head)` pipes into the subshell's first command.
  Once the stage has consumed an assignment or a redirection, though, a newline
  ends it: `ls | VAR=x` + newline + `head` runs `head` as a separate command.
  """

  # Operators that consume the following word as their target (a filename or a
  # heredoc delimiter). The walk skips that word.
  @redirection_ops ~w[> >> < << <<- <<< <> >& <& &> &>>]

  # Shell operators, longest first so `&>>` wins over `&>`, `<<-` over `<<`, and
  # so on. `take_operator/1` returns the first prefix that matches.
  @operators ~w[&>> <<< <<- &> && >> >& << <& <> |& || & > < ; ( ) |]

  # Characters that end a heredoc-delimiter word: blanks and the shell
  # metacharacters, plus the quoting introducers (handled separately). Any other
  # character is part of the delimiter, so `-EOF`, `.END`, `+EOF`, and even `$F`
  # work like bash's `<<WORD` — a delimiter undergoes quote removal only
  # (POSIX 2.7.4), so `$` and backticks in it are literal.
  @delimiter_stops [?\s, ?\t, ?\n, ?|, ?&, ?;, ?(, ?), ?<, ?>, ?\\, ?', ?"]

  # The `NAME=value` prefix of a simple command.
  @assignment ~r/^[A-Za-z_][A-Za-z0-9_]*=/

  @typedoc "A shell token: a word (quotes stripped) or an operator as written."
  @type token :: {:word, String.t()} | {:op, String.t()}

  @doc """
  Tokenize `command` into `{:word, binary}` and `{:op, binary}` tokens in order.
  """
  @spec tokenize(String.t()) :: [token()]
  def tokenize(command), do: scan(command, :normal, [], [], [])

  @doc """
  Return `{command_word, piped?}` for each simple command in `tokens`.
  """
  @spec command_words([token()]) :: [{String.t(), boolean()}]
  def command_words(tokens) do
    tokens |> drop_fd_numbers() |> walk({false, true, false, false}, [])
  end

  # ---- stage walk ----

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

  # Walk the token stream, accumulating `{command_word, piped?}` for each simple
  # command. The state tuple is `{piped?, expecting?, consumed?, skip}`:
  #
  #   * `piped?`     — the current command is a pipeline stage fed by a `|`/`|&`
  #   * `expecting?` — the next non-assignment, non-redirection word is the
  #                    command word
  #   * `consumed?`  — the current command already has an assignment or
  #                    redirection, so a newline ends it instead of continuing
  #   * `skip`       — the next word is a redirection target, not a command word
  defp walk([], _state, acc), do: Enum.reverse(acc)
  defp walk([{:op, op} | rest], state, acc), do: walk_op(op, rest, state, acc)
  defp walk([{:word, word} | rest], state, acc), do: walk_word(word, rest, state, acc)

  defp walk_op(op, rest, {piped?, expecting?, consumed?, _skip} = state, acc) do
    cond do
      op in ["|", "|&"] ->
        walk(rest, {true, true, false, false}, acc)

      op == "\n" and continuing?(state) ->
        walk(rest, {piped?, expecting?, consumed?, false}, acc)

      op == "(" and piped_stage?(state) ->
        walk(rest, {piped?, expecting?, consumed?, false}, acc)

      op in @redirection_ops ->
        walk(rest, {piped?, expecting?, true, true}, acc)

      true ->
        walk(rest, {false, true, false, false}, acc)
    end
  end

  defp walk_word(word, rest, {piped?, expecting?, consumed?, skip}, acc) do
    cond do
      skip ->
        walk(rest, {piped?, expecting?, consumed?, false}, acc)

      not expecting? ->
        walk(rest, {piped?, expecting?, consumed?, false}, acc)

      assignment?(word) ->
        walk(rest, {piped?, true, true, false}, acc)

      true ->
        walk(rest, {piped?, false, true, false}, [{word, piped?} | acc])
    end
  end

  # A newline right after a bare `|` is a continuation (`ls |` + newline +
  # `head` is `ls | head`); once the stage has an assignment or a redirection,
  # the newline ends the stage instead.
  defp continuing?({piped?, expecting?, consumed?, _skip}),
    do: piped? and expecting? and not consumed?

  # `(` while a pipeline stage is still expected keeps that stage: the
  # subshell's first command is the stage's command (`ls | (head)`).
  defp piped_stage?({piped?, expecting?, _consumed?, _skip}), do: piped? and expecting?

  defp assignment?(word), do: Regex.match?(@assignment, word)

  # ---- tokenizer ----
  #
  # `tokenize/1` returns `{:word, binary}` and `{:op, binary}` tokens in order.
  # Quotes are stripped from words; operators are returned as written. Heredoc
  # bodies and `#` comments are skipped, so their contents never become tokens.

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
        # The delimiter has an embedded quote or `(` (`<<E'OF'`, `<<$(cmd)`), so
        # its exact text is not knowable here. Keep scanning the rest of the
        # current line — a pipe there is real — and let `skip_heredocs/2` drop
        # everything from the next newline on as the body.
        scan(rest, :normal, [], push_op(flush(word, tokens), op), pending ++ [{:unknown, false}])

      :error ->
        scan(rest, :normal, [], push_op(flush(word, tokens), op), pending)
    end
  end

  # Returns `{:ok, delim, rest}` for a delimiter, `:unknown` when the delimiter
  # has an embedded quote or `(` (`<<E'OF'`, `<<$(cmd)`) that this tokenizer
  # cannot read as one word, or `:error` when this `<<` is not a heredoc at all.
  # A leading `\` quotes the delimiter (`<<\EOF`), and a quoted delimiter is read
  # to its matching quote so `<<'E OF'` works.
  defp take_heredoc_delim(input) do
    input = skip_blanks(input)

    case input do
      <<"\\", rest::binary>> -> unquoted_delim(rest)
      <<quote, rest::binary>> when quote in [?', ?"] -> take_quoted_delim(quote, rest, [])
      _ -> unquoted_delim(input)
    end
  end

  # A heredoc delimiter undergoes quote removal only (POSIX 2.7.4), so `$` and
  # backticks are literal (`<<$F` names the delimiter `$F`). A delimiter with an
  # embedded quote or `(` (`<<E'OF'` is `EOF`, `<<$(cmd)` is not read as one
  # word) falls back to the conservative sentinel.
  defp unquoted_delim(input) do
    case take_word(input) do
      {"", _rest} -> :error
      {_delim, <<quote, _rest::binary>>} when quote in [?', ?", ?(] -> :unknown
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

  defp take_word(<<char, rest::binary>>, acc) when char not in @delimiter_stops,
    do: take_word(rest, [acc, char])

  defp take_word(rest, acc), do: {IO.iodata_to_binary(acc), rest}

  # After a newline, consume heredoc bodies: skip lines until each pending
  # delimiter is seen, in order.
  defp skip_heredocs(input, []), do: {input, []}

  # A heredoc whose delimiter has an embedded quote or `(` (`<<E'OF'`): the
  # delimiter is not knowable here, so everything from this newline on is
  # treated as the body and the scan stops.
  defp skip_heredocs(_input, [{:unknown, _strip_tabs} | _pending]), do: {<<>>, []}

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
