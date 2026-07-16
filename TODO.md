# TODO

Fix issues:

- Browser performance on long conversations. At around 100k context things get
pretty laggy.
- Need to detect and reject invalid summaries somehow.
  - Minimax M3 likes to ignore the summary request and just issue another tool
  call.
- Can't run nested brwap in tests when developing nest-in-nest.
  - This seems tractable without wussing out in any way. We don't need to skip
  the tests, skip the bwrap, or jump straight to different bwrap configs for
  inner and outer, we just need to figure out what's breaking and use a
  reasonable nestable config.

