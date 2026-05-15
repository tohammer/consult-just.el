# consult-just

[Consult](https://github.com/minad/consult)-based completion for [just](https://github.com/casey/just) recipes. Select and run recipes interactively with grouping, recency tracking, and doc string annotations.

## Requirements

- Emacs 28.1+
- [consult](https://github.com/minad/consult) 0.34+
- [just](https://github.com/casey/just) with `--unstable` dump support

## Installation

### use-package (Emacs 29+)

```elisp
(use-package consult-just
  :vc (:url "https://github.com/tohammer/consult-just.el")
  :commands consult-just)
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
```

Bind it:

```elisp
(map! "C-c j" #'consult-just)
```

## Usage

`M-x consult-just` — opens a completing-read prompt with all public recipes from the nearest justfile. Recipes are grouped by their `[group(...)]` attribute; up to 5 recently used recipes appear in a **Recent** section. Private recipes (`[private]` or `_`-prefixed) are hidden. The selected recipe runs in a `*just: <recipe>*` compilation buffer.

## Customization

| Variable                  | Default                              | Description                       |
|---------------------------|--------------------------------------|-----------------------------------|
| `consult-just-executable` | `(executable-find "just")`           | Path to the `just` binary         |

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## AI Disclaimer

This package was developed with the help of AI coding agents.
