defmodule Nest.TestSupport.AgentToolsWaiters do
  @moduledoc """
  WAITERS RIP. Every function in this module was a
  mailbox-drain loop in disguise — they `receive`-d,
  pattern-matched one specific message, and re-`receive`d
  if it didn't match.

  drain loop killed with fire, it can *NEVER EVER* come back.

  This module is intentionally empty. Do not put helper
  code here. Tests that need synchronization on a specific
  `{:chat_message, ...}` broadcast should use `assert_receive`
  with a pattern + timeout.

  See AGENTS.md — `assert_receive` is the canonical
  synchronization primitive for GenServer / PubSub messages.
  """
end
