Here are some things to watch for in code reviews:

- Redundant code.
  - ex. If every call to a function has the same code next to it, that code should
  probably be in the function.
- Useless precondition checking.
  - ex. Doing an extra O(n) DB call to check for a unique or foreign key violation.
  Better to just try it and handle the error.
- Useless delegation or abstraction.
  - A helper function that just calls a function in another module should
  typically be eliminated in favor of just calling the function directly.

