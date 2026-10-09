# consult-just architecture

## Flow

1. `consult-just--dump` runs `just --unstable --dump --dump-format=json` with
   `process-file` from `default-directory`. stdout and stderr are kept apart:
   on a non-zero exit, just's stderr becomes the `user-error`; on success,
   warnings on stderr cannot corrupt the JSON. `process-file` and
   `(executable-find … t)` make it work in TRAMP directories.
2. `consult-just--recipes` walks the dump and its `modules` recursively and
   returns one plist per public recipe: `:name` (the `namepath`, e.g.
   `sub::foo`, which is what just accepts on the command line), `:group`,
   `:doc`, `:params`, `:no-cd`.
3. `consult-just` builds candidates (recipe names with the plist in the text
   property `consult-just--recipe`) and calls `consult--read` with an
   annotation function, `:history` and `consult--lookup-member`, which
   returns the original propertized candidate. It passes neither `:group`
   nor `:sort`, so the completion UI sorts.
4. `consult-just--read-arguments` prompts only if the recipe has parameters.
5. `consult-just--run` calls `compile` in the justfile's directory with
   `compilation-buffer-name-function` bound to give `*just: NAME*`.

## Decisions and the behaviour they work around

- **Attributes are mixed JSON.** Attributes with an argument are objects
  (`{"group": "dev"}`), others are strings (`"no-cd"`, `"private"`).
  `consult-just--group-attribute` only looks inside conses. 0.1 called
  `alist-get` on every attribute and failed on any justfile with a plain
  attribute. Test: `consult-just-test-plain-attributes`.
- **Working directory.** just runs recipes in the justfile's directory, and
  relative file names in their output are relative to it. The compilation
  buffer therefore uses the directory of the dump's `source`, with the
  remote prefix of `default-directory` added back. `[no-cd]` recipes and
  `set no-cd` run where just was invoked, so they keep `default-directory`.
  0.1 used `default-directory` for everything, so `next-error` opened the
  wrong files from subdirectories. Tests: `consult-just-test-root`,
  `consult-just-test-run-directory-and-command`, `consult-just-test-real-just`.
- **Buffer name.** Binding `compilation-buffer-name-function` (instead of
  renaming after `compile`, as 0.1 did) reuses `*just: NAME*` on each run,
  never touches an unrelated `*compilation*` buffer, and is stored in
  `compilation-arguments`, so `g` recompiles into the same buffer. Test:
  `consult-just-test-run-reuses-buffer`.
- **compile-command.** `compile` sets the global `compile-command`; users can
  rely on `recompile` re-running the last recipe.
- **Recency is the completion UI's job.** 0.1 and 0.2 built a "Recent"
  group themselves and passed `:sort nil`, which overrode the user's sorting
  (vertico's history sort, prescient, …) and moved a recipe between groups
  depending on use. `:group` is meant for what an item is, and `:sort nil` for
  lists whose order means something (buffer lines, imenu); neither applies.
  0.3 passes `:history` and lets the UI sort. Grouping by the justfile's
  groups was rejected because vertico sorts before grouping, so it would not
  give a flat most-recent-first list. Test:
  `consult-just-test-command-end-to-end`.
- **Annotations.** One annotation function with two columns, group and
  doc. The group column starts two columns after the widest name and the doc
  column two columns after the widest group (right after the names when no
  recipe has a group), via `(space :align-to COL)`. Widths come from
  `string-width`, so wide characters align. 0.1 also registered a marginalia
  annotator that duplicated the built-in one and referenced marginalia
  variables without declaring them. Without an entry in
  `marginalia-annotators`, marginalia uses the built-in annotation, so no
  marginalia annotator is registered. Tests: `consult-just-test-annotate`,
  `consult-just-test-annotate-alignment`,
  `consult-just-test-annotate-no-groups`.
- **Arguments as a raw string.** The argument string is appended to the
  command unquoted, so the user can quote and pass several words for
  variadic parameters, and the command in the compilation buffer shows
  exactly what ran.
- **Empty justfile.** A justfile without public recipes gives a
  `user-error`. 0.1 called `max` on an empty list. Test:
  `consult-just-test-no-recipes`.
- **projectile.** If loaded, the command is stored in
  `projectile-compilation-cmd-map` for `projectile-compilation-dir`. Guarded
  with `fboundp`/`boundp`; projectile is not a dependency.

## Known limitations and open points

- `--unstable` is still passed to `--dump`. Current just versions do not
  need it for JSON dumps; it is kept for older versions.
- Private modules and module doc comments are not used; all modules are
  walked.
- No preview (`:state`) of the recipe body.
- package-lint has not been run.
