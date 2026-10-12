/**
 * ToolMedia component tests (issue #40).
 *
 * Covers the rendered previews and — just as importantly — the explicit
 * indicators: the project rule is that expected data is never silently
 * dropped, so a missing payload, a missing type, a missing size, and a
 * modality this build does not know each have to say so rather than
 * render as nothing.
 */
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { ToolMedia } from "./ToolMedia";

const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

function imageMedia(overrides = {}) {
  return {
    tool_call_id: "call_1",
    modality: "image",
    mediaType: "image/png",
    bytes: 68,
    data: PNG,
    path: "shot.png",
    ...overrides,
  };
}

describe("ToolMedia", () => {
  it("renders nothing when there is no media at all", () => {
    expect(
      render(<ToolMedia media={undefined} />).container.firstChild,
    ).toBeNull();
    expect(render(<ToolMedia media={[]} />).container.firstChild).toBeNull();
  });

  it("renders an image preview labelled with its type, size, and path", () => {
    render(<ToolMedia media={[imageMedia()]} />);

    const img = screen.getByTestId("tool-media-image");
    expect(img).toHaveAttribute("src", `data:image/png;base64,${PNG}`);
    expect(img).toHaveAttribute("alt", "Attached image shot.png");

    expect(screen.getByText("Image")).toBeInTheDocument();
    expect(screen.getByText("image/png")).toBeInTheDocument();
    expect(screen.getByText("68 bytes")).toBeInTheDocument();
    expect(screen.getByText("shot.png")).toBeInTheDocument();
  });

  it("scales the size label and omits the path the wire did not carry", () => {
    render(
      <ToolMedia media={[imageMedia({ bytes: 1_500_000, path: null })]} />,
    );

    expect(screen.getByText("1.5 MB")).toBeInTheDocument();
    expect(screen.queryByText("shot.png")).toBeNull();
    // The type is still named, so the block is still identifiable.
    expect(screen.getByText("image/png")).toBeInTheDocument();
  });

  it("names an unknown modality rather than rendering nothing", () => {
    // A row written by a newer build. Rendering nothing would make it
    // indistinguishable from a message with no attachment at all.
    render(<ToolMedia media={[imageMedia({ modality: "hologram" })]} />);

    expect(
      screen.getByText("Unknown media modality (hologram)"),
    ).toBeInTheDocument();
    expect(screen.getByTestId("tool-media-unknown")).toBeInTheDocument();
    expect(screen.queryByTestId("tool-media-image")).toBeNull();
  });

  it("says the payload is unavailable when there is nothing to preview", () => {
    render(<ToolMedia media={[imageMedia({ data: null })]} />);

    expect(screen.getByTestId("tool-media-unavailable")).toBeInTheDocument();
    expect(screen.queryByTestId("tool-media-image")).toBeNull();
  });

  it("flags a missing type and a missing size instead of leaving blanks", () => {
    render(
      <ToolMedia media={[imageMedia({ mediaType: null, bytes: undefined })]} />,
    );

    expect(screen.getByText("type not reported")).toBeInTheDocument();
    expect(screen.getByText("size not reported")).toBeInTheDocument();
    expect(screen.getByTestId("tool-media-unavailable")).toBeInTheDocument();
  });

  it("renders one block per media part, keyed on the part's own identity", () => {
    render(
      <ToolMedia
        media={[
          imageMedia({ tool_call_id: "c1", path: "a.png" }),
          imageMedia({ tool_call_id: "c2", path: "b.png" }),
        ]}
      />,
    );

    expect(screen.getAllByTestId("tool-media-item")).toHaveLength(2);
    expect(screen.getByText("a.png")).toBeInTheDocument();
    expect(screen.getByText("b.png")).toBeInTheDocument();
  });

  it("still keys a media part the wire gave no call id", () => {
    // Defensive: the wire always carries `toolCallId`, but a missing one must
    // not produce an `undefined` key.
    render(
      <ToolMedia
        media={[imageMedia({ tool_call_id: undefined, path: null })]}
      />,
    );

    expect(screen.getByTestId("tool-media-image")).toBeInTheDocument();
  });

  it("renders a player for the audio and video modalities", () => {
    // Neither is reachable from the wire today — the modality vocabulary is
    // one entry — but the component's contract is to render whatever it is
    // given, so both branches are pinned.
    const audio = render(
      <ToolMedia
        media={[imageMedia({ modality: "audio", mediaType: "audio/mpeg" })]}
      />,
    );

    expect(screen.getByTestId("tool-media-audio")).toHaveAttribute(
      "src",
      `data:audio/mpeg;base64,${PNG}`,
    );
    expect(screen.getByText("Audio")).toBeInTheDocument();
    audio.unmount();

    render(
      <ToolMedia
        media={[imageMedia({ modality: "video", mediaType: "video/mp4" })]}
      />,
    );

    expect(screen.getByTestId("tool-media-video")).toHaveAttribute(
      "src",
      `data:video/mp4;base64,${PNG}`,
    );
    expect(screen.getByText("Video")).toBeInTheDocument();
  });
});
