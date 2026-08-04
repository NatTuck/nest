# Vocation Design Specification

## Overview

Vocations are **reusable agent blueprints** that define an agent's role, available tools, and sandbox capabilities. They decouple the "what" (the agent's role and capabilities) from the "who" (the specific runtime instance of an agent).

### Key Concepts

- **Vocation**: A durable template defining an agent's capabilities, base system prompt, and available tools.
- **Mode**: A runtime capability profile (defined within a Vocation) that dictates sandbox permissions for a given turn (e.g., "plan" vs "build").
- **Agent**: A runtime instance spawned from a Vocation. It maintains its own conversation state, workspace, and current operational mode.
- **Tool**: An executable action available to agents, typically implemented as a sandboxed shell command via `bwrap`.

---

## Design Goals

### 1. Capability Isolation
Agents must operate within strictly defined boundaries to ensure system security and predictability.
- **Sandbox Isolation**: Every tool execution happens within a Linux namespace (via `bwrap`) to prevent unauthorized host access.
- **Mode-Based Permissions**: Permissions are not static; they shift based on the agent's current "mode," allowing an agent to be read-only during analysis (plan) and read-write during execution (build).

### 2. Blueprint Reusability
The Vocation model allows the same architectural role to be instantiated multiple times across different workspaces or conversations without duplicating the configuration.

### 3. Predictable Lifecycle
- **Ephemerality of Temp Space**: Each agent has a dedicated `/tmp` directory that is purged upon agent termination.
- **Durability of Workspaces**: Agent workspaces are persistent, allowing humans to review the results of an agent's work or for subsequent agents in a workflow to inherit the state.

---

## Architectural Model

### Vocation Structure
A Vocation consists of:
- **Identity**: Name and description.
- **Prompting**: A base system prompt used as the foundation for the agent's personality and instructions.
- **Tool Registry**: A list of tool identifiers the agent is permitted to use.
- **Mode Definitions**: A map of mode names to **Capability Sets** (caps), defining:
    - **Network Access**: Whether the sandbox has network connectivity.
    - **Filesystem Access**: A list of read-only and read-write bind mounts (e.g., the agent's specific workspace).

### Agent Runtime State
When an agent is spawned from a Vocation, it inherits the Vocation's constraints but maintains its own:
- **Workspace Path**: A unique directory on the host filesystem.
- **Current Mode**: The active capability profile.
- **Conversation History**: The sequence of messages and tool results.

### Tool Execution Flow
1. **Selection**: The LLM selects a tool from the Vocation's permitted list.
2. **Contextualization**: The agent retrieves the capability set for the current active mode.
3. **Isolation**: A sandbox is constructed using `bwrap` based on the capability set and the agent's workspace path.
4. **Execution**: The command is executed, and output is streamed back to the user and the LLM.

---

## Summary

The Vocation system ensures that agents are **safe**, **specialized**, and **consistent**. By separating the blueprint (Vocation) from the instance (Agent) and the permissions (Mode), the system can scale to complex multi-agent workflows while maintaining rigorous security boundaries.
