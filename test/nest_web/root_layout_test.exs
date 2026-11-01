defmodule NestWeb.RootLayoutTest do
  @moduledoc """
  The root layout's viewport meta has to ask the browser to *resize the content*
  when the soft keyboard opens.

  This is the one place the keyboard problem can be fixed, and it is not a
  stylesheet: the chat page is a fixed-height shell (`h-dvh`, `overflow-hidden`,
  a bottom-pinned composer). Under the default `interactive-widget=resizes-visual`
  the keyboard shrinks only the visual viewport, so the shell keeps its full
  height, the composer stays at the bottom of a viewport that is now *behind* the
  keyboard, and the document cannot scroll the focused field into view — it is
  exactly one viewport tall. The browser then has nowhere to put the caret, and
  the IME is dismissed as soon as it opens. `resizes-content` shrinks the layout
  viewport instead, which is what the app's own measurement harness exercises and
  what keeps the field visible and focused.

  A source scan rather than a rendered-page assertion: this is a `<meta>` in the
  HEEx layout, so the browser is the only thing that can act on it, and the
  project already pins config copies this way (`Nest.DotConfigJsDefaultsTest`).
  """
  use ExUnit.Case, async: true

  @layout Path.join(["lib", "nest_web", "components", "layouts", "root.html.heex"])

  test "the viewport meta asks the keyboard to resize the content" do
    source = File.read!(Path.join(File.cwd!(), @layout))

    assert source =~ "interactive-widget=resizes-content"
    # ...and still keeps the safe-area insets real, which is the other half of a
    # composer that has to sit above the home indicator.
    assert source =~ "viewport-fit=cover"
  end
end
