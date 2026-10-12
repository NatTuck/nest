/**
 * Tests for the shared media presentation helpers (issue #40).
 *
 * These are what the panel header and the clipboard serialiser both read, so
 * the missing-data behaviour matters as much as the happy path: every
 * function returns `null` (or an explicit "not reported" string) rather than
 * an empty value, because the caller's job is to render an indicator.
 */
import { describe, it, expect } from "vitest";
import {
  MODALITY_LABELS,
  formatBytes,
  mediaDataUri,
  mediaSummary,
} from "./media.js";

describe("formatBytes", () => {
  it("scales a byte count to bytes, KB, or MB", () => {
    expect(formatBytes(0)).toBe("0 bytes");
    expect(formatBytes(68)).toBe("68 bytes");
    expect(formatBytes(999)).toBe("999 bytes");
    expect(formatBytes(1_000)).toBe("1.0 KB");
    expect(formatBytes(1_500)).toBe("1.5 KB");
    expect(formatBytes(1_000_000)).toBe("1.0 MB");
    expect(formatBytes(2_450_000)).toBe("2.5 MB");
  });

  it("returns null for anything that is not a byte count", () => {
    // `null` is the caller's cue to render an explicit "size not reported"
    // indicator; an empty string would render as nothing.
    for (const bad of [undefined, null, "68", NaN, Infinity, -1]) {
      expect(formatBytes(bad)).toBeNull();
    }
  });
});

describe("mediaDataUri", () => {
  it("builds a data URI from the type and the base64 payload", () => {
    expect(mediaDataUri({ mediaType: "image/png", data: "AAAA" })).toBe(
      "data:image/png;base64,AAAA",
    );
  });

  it("returns null when the type or the payload is missing", () => {
    expect(mediaDataUri(null)).toBeNull();
    expect(mediaDataUri({ data: "AAAA" })).toBeNull();
    expect(mediaDataUri({ mediaType: "", data: "AAAA" })).toBeNull();
    expect(mediaDataUri({ mediaType: "image/png" })).toBeNull();
    expect(mediaDataUri({ mediaType: "image/png", data: "" })).toBeNull();
  });
});

describe("mediaSummary", () => {
  it("joins the fields that are present, in a stable order", () => {
    expect(
      mediaSummary({ mediaType: "image/png", bytes: 68, path: "shot.png" }),
    ).toBe("image/png · 68 bytes · shot.png");

    // A field the wire omitted is left out rather than rendered as a blank.
    expect(mediaSummary({ mediaType: "image/png", bytes: 68 })).toBe(
      "image/png · 68 bytes",
    );
  });

  it("says the type is not reported rather than emitting a blank", () => {
    expect(mediaSummary({ bytes: 68 })).toBe("type not reported · 68 bytes");
    expect(mediaSummary({})).toBe("type not reported");
    expect(mediaSummary(null)).toBe("type not reported");
  });

  it("labels every modality the vocabulary declares", () => {
    // The panel's heading comes from here, so a modality with no label would
    // render as a bare "undefined" rather than an explicit unknown.
    expect(MODALITY_LABELS).toEqual({
      image: "Image",
      audio: "Audio",
      video: "Video",
    });
  });
});
