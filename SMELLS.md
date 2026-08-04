Essential rules:

- During this process **ABSOLUTELY NEVER** run `git stash`. NEVER.
NOT FOR ANY REASON, NO EXCUSES.
- **ABSOLUTELY NEVER** re-run the tests a bunch of times for any
reason.

Here are some things to watch for in code reviews:

- Avoid redundant code.
  - ex. If every call to a function has the same code next to it, that code should
  probably be in the function.
- Avoid useless precondition checking.
  - ex. Doing an extra O(n) DB call to check for a unique or foreign key violation.
  Better to just try it and handle the error.
- Avoid useless delegation or abstraction.
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
- We can't do db access in the GenServer init callback. That breaks async tests.
Push any such logic out to the calling process (e.g. in start_link, or have a
helper function in the GenServer module that gets called by whatever the
external interface function is that eventually leads to start_link being
called. If there's a Supervisor.start_child in the chain, it needs to be
outside of that).

Testing:

- Sleeps in tests are strictly disallowed.
- Timeouts in tests should be as low as possible. Typically 50ms, absolutely
no more than 500ms unless there are comments describing the concrete timings
(with real, measured numbers) and a clear justification.
- Any increase in a timeout is a likely smell. We need to find and fix the bug.
- We should *never* introduce timeout over 500ms without some absolutely epic
justification. That probably hides bugs and will certainly slow down the suite -
we need to find and fix the bug *and* refactor the test with the long timeout.
- If we're doing something that's going to block in a test (like a receive), it's because
we know for sure the block will end in a fixed time - optimally we should only
be doing a receive if the message is *already* in the mailbox.
- We don't do "drain loops" in tests.
- We don't do "async: false" just because a test hits the DB. Any "async: false"
must have a clear and concrete justification that explains some atypical
situation.
- We're using the test DB sandbox. That means that any DB activity triggered by a
test must 1.) happen in sandbox for that test, 2.) complete before the test
finishes. We can't just trigger background test processes that might do DB work 
and not wait for them.

Temp files:

- Temp files should go somewhere appropriate, with a path including a string
(e.g. "nest-tmp") that is unlikely to occur in other paths.
- Cleanup of a temp directory with "rm -rf" or similar should always be guarded
by a check to confirm that the path contains that identifying string.
