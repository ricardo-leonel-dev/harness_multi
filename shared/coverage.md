# Shared coverage guidance

Harness-owned instructions: refreshed by install.sh. Project docs, specs and
runtime configuration remain project-owned. Change shared guidance in the source
toolkit and reinstall; do not maintain independent edits in installed copies.

Every requirement still needs a concrete, currently-passing test. A compact
acceptance evidence table may group multiple requirements in one row when the
named test actually exercises each of them. State the grouping in design.md and
list every requirement id explicitly. A preservation requirement can use one
baseline comparison when it checks the complete required surface; separate rows
for each unchanged item are unnecessary. These choices reduce report repetition,
not the evidence required or the independent reviewer check.

An evidence index generated from names is only a navigation aid. It neither
executes tests nor establishes that they exercise the mapped requirements.
