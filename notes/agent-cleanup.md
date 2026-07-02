
## Make sure OTP usage is correct

For some reason agent calls aren't properly using the registry. This is a
textbook example where we should be using the registry rather than pids. The
whole supervisor setup needs work.

## Startup Flow

Our startup flow for agents is a bit screwy.

Before an agent is running (returns from Agent.init), we need to have sufficient
information to build the system prompt and be ready to send messages. We don't
want to have a running agent waiting for async events to figure out what it's
doing.

We don't want to do DB access in init, because that screws up async tests.

That means any loading of state from the DB needs to happen in
Agents.create_agent or Agent.start_link, in the calling process.

Currently, we're depending on two async fetches:

- A probe for context length.
- Loading persisted state from DB.

There will likely be fewer providers than agents, so it makes sense to probe
the providers once at startup rather than each time an agent is spawned.

So neither of these things should be happening after the agent starts, they
should both be done before.



