
## Background:

- When conversation context fills, we can't continue without compacting the
conversation.
- If we have enough context space left, we can compact efficiently by simply
sending a new message requesting that the existing agent self-summarize.
- If we actually run out of context (there isn't enough space left for a
summarization request + thinking + summary response) then the only way to
recover is some sort of complex multi-stage compaction that necessarily involves
a large, uncached request, which is slow and expensive.
- We have that slow path for *offline* recovery, but we don't want to have it at
all for normal operation.
- Therefore, we must *structurally guarantee* that we always preserve enough
context to do compaction (again, summarization request + thinking + summary
response).
- A complication is that we can't calculate exact token costs of unsent
requests, so we need to use conservative estimates with a high likelihood of
being upper bounds during our calculations.
- We do have real token usage for everything but the latest unsent request,
so we should always use that value when we have it.

## Key Invariants:

- We maintain a reserve of sufficient size for compaction.
- We do not send or persist a pre-compaction message, ever, in any edge case,
that cuts into that reserve. The reserve must be reserved for compaction (our
compaction request and the response).
- That includes user messages, tool responses, synthetic messages, API
responses, and synthetic error messages. If it would cut into the reserve it
doesn't get sent, persisted, or displayed without a clear indication that it
hasn't been persisted.
- Every message must be checked against these invariants to decide how to handle
it and allow the invariant to be maintained, but not necessarily right before
the send/persist. A check right before send/persist might not be sufficient,
because sending/persisting might mean committing to future messages as well. We
must *structurally guarantee* that the invariants cannot be violated by logic
after the check. 

## Core Mechanism:

- Compaction first: Given a proposed message that would infringe on the reserve,
we can compact first and then send/persist the message after compaction.
  - Important, our history is immutable with strictly rising message indexes, so
  we need to hold these messages as deferred until compaction is resolved before
  even assigning a message index.
  - This is true for both requests and responses. A too-big response can be
  deferred and put in after the summary post-compaction.
  - Because an LLM *response* can be deferred, we don't need to worry about
  whether the response can fit in the current context before sending a request.
  But it does need to fit post deferral (so system + summary + last response +
  reserve must all fit in a context).
- Exceptional case: Tool responses. Once a tool call has been persisted, the
next message *must* be a tool response, otherwise the API may no longer treat
the conversation as valid. That means we cannot persist a tool call without
first *guaranteeing* that we have space for the tool response.
  - We could defer the tool call and compact.
  - We could run the tool and get the result before deciding, but we'd prefer to
  be able to decide before running the tool.
  - Tool calls come in batches, and it doesn't really make sense to split tool
  responses for a batch across compaction. Either all before, all after, or
  none.

## Batch Sizer

- Given a tool batch, we want to figure out of we can send all the responses
before compaction.
- And we'd still really like to avoid executing any costly tools.
  - Executing cheap / read-only tools would be fine. Reading a file to estimate
  the how many tokens read-file uses might make a lot of sense.
- So the batch sizer estimates costs before execution.
- Especially for shell-cmd, the full output estimate isn't limited. So for large
outputs we know we need to write to a file. Generalizing this, tool results can
have two token costs: the full output, and the path to an output file and maybe
some metadata (e.g. shell command exit code). In this case, knowing that the
*small* output will fit in context is sufficient to calculate the batch output
size.
- Tool output sizes have three cases:
  - Nearly fixed size small output, so we can give a high quality small estimate.
  - Unknown size output, but we can write it to a file and use the file path
  and token count as a fixed size small output if the real output is too big.
  - For file-read, writing the file contents to another file would be silly,
  so the fixed size small output is just "it's too big, X tokens".
- So we *estimate* with the small output, and then after execution we use the
small output in two cases:
  - We don't have context space for the big output.
  - The caller set a token limit which the big output would exceed.

## Budget Reminders

- To help the LLM plan tool calls, we inject budget reminders in to the
conversation.
- These come *before* messages that will pass token thresholds based on
on the same prediction logic the batch sizer is using for go/no-go on
a batch.

## context-management-sequence.md

5. The retry thing here is an example of an unchecked user message.
That must *never happen*. Synthetic messages must go through the
normal sequence.

6d. Why is this called swap? That's awful terminology.

**Gaps**

1. A last minute check would need to be a "never happens" condition. If we get
   here and fail, there's no way to fix it. Should have been fixed by compaction
   or otherwise earlier.
2. There needs to be proper accounting for all synthetic messages. They can't go
   on the list if there isn't space.
3. Once we have real counts, we should always use those over estimates. Also, if
   REAL > EST, we have a serious bug in our estimation logic - we should
   probably come up with a mechanism to occasionally check that.
4. We probably should set RunRequest.max_tokens ; we should have a mechanism for
   compact-before-response, so it doesn't need to fit in remaining context, but
   infinity is probably the wrong answer too.
5. We don't need a last minute persistence tripwire, we need a persist
   structural invariant. Again, all a check could tell us is that the invariant
   had been violated some time earlier.
6. Snapshots sound sketchy. We should make sure this is sane.



