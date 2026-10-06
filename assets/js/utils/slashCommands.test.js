/**
 * Tests for `js/utils/slashCommands.js`.
 *
 * The registry/parser powers the composer's `/command` handling and the
 * click-only autocomplete menu.
 */

import { describe, expect, it } from "vitest";
import {
  SLASH_COMMANDS,
  parseSlashCommand,
  commandSuggestions,
} from "./slashCommands.js";

describe("parseSlashCommand", () => {
  it("parses a registered command, trimming surrounding whitespace", () => {
    expect(parseSlashCommand("/compact")).toEqual({
      name: "compact",
      args: "",
    });
    expect(parseSlashCommand("  /compact  ")).toEqual({
      name: "compact",
      args: "",
    });
  });

  it("parses a command with trailing arguments", () => {
    expect(parseSlashCommand("/compact focus on tests")).toEqual({
      name: "compact",
      args: "focus on tests",
    });
  });

  it("keeps the full remainder as args, preserving newlines and inner spacing", () => {
    expect(parseSlashCommand("/compact focus on\nmultiple lines")).toEqual({
      name: "compact",
      args: "focus on\nmultiple lines",
    });
    expect(parseSlashCommand("/compact  keep   inner   spaces")).toEqual({
      name: "compact",
      args: "keep   inner   spaces",
    });
  });

  it("returns null for empty input, a bare slash, unknown commands, and plain text", () => {
    expect(parseSlashCommand("")).toBeNull();
    expect(parseSlashCommand("/")).toBeNull();
    expect(parseSlashCommand("/unknown")).toBeNull();
    expect(parseSlashCommand("/compactx")).toBeNull();
    expect(parseSlashCommand("hello")).toBeNull();
  });

  it("tolerates nullish input", () => {
    expect(parseSlashCommand(null)).toBeNull();
    expect(parseSlashCommand(undefined)).toBeNull();
  });
});

describe("commandSuggestions", () => {
  it("suggests matching commands for a bare or partial slash token", () => {
    expect(commandSuggestions("/")).toEqual(SLASH_COMMANDS);
    expect(commandSuggestions("/c")).toEqual(SLASH_COMMANDS);
    expect(commandSuggestions("/com")).toEqual(SLASH_COMMANDS);
  });

  it("returns no suggestions once a command is complete or spaced out", () => {
    expect(commandSuggestions("/compact")).toEqual([]);
    expect(commandSuggestions("/compact ")).toEqual([]);
    expect(commandSuggestions("/compact focus on tests")).toEqual([]);
  });

  it("returns no suggestions for plain text or an unknown partial", () => {
    expect(commandSuggestions("hello")).toEqual([]);
    expect(commandSuggestions("/unknown")).toEqual([]);
    expect(commandSuggestions(null)).toEqual([]);
    expect(commandSuggestions(undefined)).toEqual([]);
  });

  it("accepts a custom command registry", () => {
    const commands = [
      { name: "clear", description: "Clear the conversation." },
    ];
    expect(commandSuggestions("/cl", commands)).toEqual(commands);
    expect(commandSuggestions("/nope", commands)).toEqual([]);
  });
});
