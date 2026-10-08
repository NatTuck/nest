
We've got a bunch of goals related to async messaging, and the current design
ends up not working.

The core problem is agents-query. Currently it sends a message to another agent
and waits for that agent to "reply" by finishing a turn. That's possibly okay
as long as there's only one message at a time, but as soon as we allow a second
message to interrupt that turn, we can no longer reasonably declare the end
of turn message to be a reply to any particular query.

Solution: Require explicit responses. Specifically, each agents-query (maybe
spawn, probably batch) requires the recipient to use `agents-send` to send a
message to that sender. If goes idle without having sent such a message, it is
explicitly re-prompted with "you have an outstanding message from agent 'foo',
you must send a reply using the 'agents-send' tool".

As a related fix, we should move from a /tmp folder per agent to a /tmp folder
per space. It looks like agents really want to communicate within a space using
/tmp, and that makes some other stuff easier too.

Proposed tool revisions:

- agents-query: Sends a message, recipient is required (with re-prompting) to
replay with agents-send, always async.
- agents-spawn: With query is like spawn+query. Always async.
- agents-wait: Waits for a matching idle, returns that final message (no
conflict here, that's just what it does). Long messages show up as file path in
shared /tmp, like with shell-cmd. Needs max_result_tokens. Needs a mechanism
to specify glob / regex style names.
- agents-batch: Like a spawn + query. Always async.
