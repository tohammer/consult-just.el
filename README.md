# consult-just

[Consult](https://github.com/minad/consult)-based completion for [just](https://github.com/casey/just) recipes.

## Features

- Select and run `just` recipes via `consult--read` completion
- Recipes grouped by their `[group(...)]` attribute; ungrouped recipes appear under **Other**
- Up to 5 recently used recipes surface in a **Recent** section at the top
- Doc strings shown as annotations via [marginalia](https://github.com/minad/marginalia) (when active) or the built-in annotator
- Private recipes (marked `[private]` or prefixed with `_`) are hidden
- `just` is invoked from `default-directory`; it finds the justfile itself by walking up the directory tree
- Selected recipe runs in a named `*just: <recipe>*` compilation buffer

## Requirements

- Emacs 28.1+
- [consult](https://github.com/minad/consult) 0.34+
- [just](https://github.com/casey/just) with `--unstable` dump support

## Setup

### use-package

```elisp
(use-package consult-just
  :ensure t
  :commands consult-just)
```

### Doom Emacs

In `packages.el`:

```elisp
(package! consult-just)
```

In `config.el`:

```elisp
(use-package! consult-just
  :commands consult-just)
```

Bind it however you like, e.g.:

```elisp
(global-set-key (kbd "C-c j") #'consult-just)
```

## Usage

`M-x consult-just` — opens a completing-read prompt listing all public recipes from the nearest justfile. Select one and press `RET` to run it.

## Customization

| Variable                  | Default                        | Description                    |
|---------------------------|--------------------------------|--------------------------------|
| `consult-just-executable` | result of `(executable-find "just")` | Path to the `just` binary |
