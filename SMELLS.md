Here are some things to watch for in code reviews:

- Redundant code.
  - ex. If every call to a function has the same code next to it, that code should
  probably be in the function.
- Useless precondition checking.
  - ex. Doing an extra O(n) DB call to check for a unique or foreign key violation.
  Better to just try it and handle the error.
- Useless delegation or abstraction.
  - A helper function that just calls a function in another module should
  typically be eliminated in favor of just calling the function directly.

OTP Usage:

- We shouldn't be using send to communicate with our own GenServers. The
handle_info callback is only for interoperability with code that must
operate by sending raw messages (self-send is allowed).
- We should use call over cast. Using cast only makes sense for communicating
with a GenServer that blocks, and most of our GenServers don't block by design.
- Every GenServer should have a clear statement in its mod doc about whether it
*ever* blocks for an unknown amount of time or not. If the doc says it doesn't block,
then it doesn't block. A GenServer.call to a GenServer that "doesn't block"
doesn't count as blocking for this purpose - it's just synchronous communication.

Testing:

- Sleeps in tests are strictly disallowed.
- Timeouts in tests should be as low as possible. Typically 50ms, absolutely
no more than 500ms unless there are comments describing the concrete timings
(with real, measured numbers) and a clear justification.
- If we're doing something that's going to block in a test (like a receive), it's because
we know for sure the block will end in a fixed time - optimally we should only
be doing a receive if the message is *already* in the mailbox.
- We don't do "drain loops" in tests.
