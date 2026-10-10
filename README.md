# consult-just

[![test](https://github.com/tohammer/consult-just.el/actions/workflows/test.yml/badge.svg)](https://github.com/tohammer/consult-just.el/actions/workflows/test.yml)

Select and run [just](https://github.com/casey/just) recipes with
[consult](https://github.com/minad/consult) completion. `M-x consult-just`
lists the public recipes of the nearest justfile, including recipes of `mod`
submodules. Each recipe is annotated with its `[group(...)]` and its doc
comment in two aligned columns, and recently used recipes come first. The
selected recipe runs in a compilation buffer, so `next-error`, `g` (recompile)
and the usual compilation keys work on its output.

## Quick start

```elisp
(require 'consult-just)
(global-set-key (kbd "C-c j") #'consult-just)
```

Open any file below a directory with a justfile and press `C-c j`.

## Installation

Requires Emacs 28.1 or later, [consult](https://github.com/minad/consult) 0.34
or later, and `just` 1.x on `exec-path`.

### use-package (Emacs 30+)

```elisp
(use-package consult-just
  :vc (:url "https://github.com/tohammer/consult-just.el")
  :bind ("C-c j" . consult-just))
```

### package-vc (Emacs 29)

```elisp
(package-vc-install "https://github.com/tohammer/consult-just.el")
(global-set-key (kbd "C-c j") #'consult-just)
```

### Doom Emacs

In `packages.el`:

```elisp
(package! consult-just
  :recipe (:host github :repo "tohammer/consult-just.el"))
```

In `config.el`:

```elisp
(use-package! consult-just
  :commands consult-just)
(map! "C-c j" #'consult-just)
```

## Usage

`M-x consult-just` reads the justfile that `just` itself finds from the
current directory (it searches upward).

- **Candidates.** All public recipes. Private recipes (`[private]` or a
  leading `_`) are hidden. Recipes of a `mod sub` submodule are listed as
  `sub::recipe`.
- **Annotations.** Two aligned columns after the name: the group (the first
  `[group('...')]` attribute, or the module name for module recipes without
  one) and the doc comment. They are plain completion annotations, so they
  show with or without marginalia. Faces: `consult-just-group`,
  `consult-just-doc`.
- **Order.** Sorting is left to the completion UI. Vertico's default
  (`vertico-sort-history-length-alpha`) lists recipes from
  `consult-just--history` first, most recent first, then the rest by length
  and name. prescient and similar packages apply their own ranking.
- **Arguments.** If the recipe has parameters, you are asked for an argument
  string. The prompt shows the parameters, e.g. `Arguments for deploy (target
  env="dev" *rest):`. The string goes to the shell as typed, so quote as you
  would on the command line. An empty string uses the defaults.
- **Running.** The recipe runs via `compile` in a buffer named
  `*just: RECIPE*`, in the justfile's directory (in the current directory for
  `[no-cd]` recipes). Running the same recipe again reuses its buffer. If
  [projectile](https://github.com/bbatsov/projectile) is loaded, the command
  is also stored as the project's compile command.

## Configuration

| Variable                    | Default  | Description                                      |
|-----------------------------|----------|--------------------------------------------------|
| `consult-just-executable`   | `"just"` | Name or path of the just binary                  |

consult-just binds no keys. The completion category is `just-recipe`, for
example for an [embark](https://github.com/oantolin/embark) keymap.

## Development

```sh
make          # byte-compile (warnings are errors), checkdoc, tests
make test     # tests only
```

consult and compat must be loadable. If they are not installed with
package.el, pass their directories:

```sh
make LOAD_PATH="-L /path/to/consult -L /path/to/compat"
```

One test runs the real `just` binary and is skipped if it is missing. See
[docs/architecture.md](docs/architecture.md) for how the package works.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## AI Disclaimer

This package was developed with the help of AI coding agents.
