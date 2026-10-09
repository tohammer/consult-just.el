;;; consult-just.el --- Consult-based completion for just recipes -*- lexical-binding: t; -*-

;; Author: Tobias Hammer <tohammer@users.noreply.github.com>
;; Maintainer: Tobias Hammer <tohammer@users.noreply.github.com>
;; Copyright (C) 2025 Tobias Hammer
;; Version: 0.3
;; Package-Requires: ((emacs "28.1") (consult "0.34"))
;; Keywords: convenience, tools, just
;; URL: https://github.com/tohammer/consult-just.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides `consult-just', an interactive command to select and run
;; recipes from a justfile using consult-based completion.
;;
;; Each recipe is annotated with its group and doc string in two
;; aligned columns.  Recipes of `mod' submodules are listed as
;; `module::recipe'.  Recipes are sorted by the completion UI, which
;; usually puts recently used ones first.  Recipes with parameters
;; prompt for an argument string.  The selected recipe is executed in
;; a compilation buffer.
;;
;; Usage:
;;   M-x consult-just
;;
;; Customization:
;;   `consult-just-executable' - name or path of the just binary

;;; Code:

(require 'consult)
(require 'compile)
(require 'seq)
(require 'subr-x)

(declare-function projectile-compilation-dir "ext:projectile")
(defvar projectile-compilation-cmd-map)

(defgroup consult-just nil
  "Consult-based completion for just recipes."
  :group 'tools
  :prefix "consult-just-")

(defcustom consult-just-executable "just"
  "Name or path of the just executable.
A bare name is looked up in variable `exec-path' (on the remote host
for remote directories) each time `consult-just' runs."
  :type 'string)

(defface consult-just-group
  '((t :inherit font-lock-type-face))
  "Face for the group column of `consult-just' annotations.")

(defface consult-just-doc
  '((t :inherit completions-annotations))
  "Face for the doc string column of `consult-just' annotations.")

(defvar consult-just--history nil
  "History for `consult-just' recipe selection.")

;;; Reading the justfile

(defun consult-just--executable ()
  "Return the just executable, or signal a `user-error'."
  (or (executable-find consult-just-executable t)
      (user-error "Consult-just: `%s' not found; set `consult-just-executable'"
                  consult-just-executable)))

(defun consult-just--dump ()
  "Return the justfile found from `default-directory' as parsed JSON.
Objects are alists, arrays are lists and JSON false is nil.  Signal a
`user-error' with just's own message when just fails."
  (let ((exe (consult-just--executable))
        (err (make-temp-file "consult-just")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (process-file exe nil (list t err) nil
                                      "--unstable" "--dump" "--dump-format=json")))
            (unless (eql status 0)
              (user-error "Consult-just: %s"
                          (string-trim
                           (with-temp-buffer
                             (insert-file-contents err)
                             (buffer-string)))))
            (condition-case e
                (json-parse-string (buffer-string)
                                   :object-type 'alist :array-type 'list
                                   :null-object nil :false-object nil)
              (error (user-error "Consult-just: cannot parse just's output: %s"
                                 (error-message-string e))))))
      (delete-file err))))

(defun consult-just--group-attribute (attributes)
  "Return the first group name in ATTRIBUTES, or nil.
Attributes with an argument are alists such as ((group . \"dev\"));
attributes without one are plain strings such as \"no-cd\"."
  (seq-some (lambda (a) (and (consp a) (alist-get 'group a))) attributes))

(defun consult-just--recipes (module)
  "Return the public recipes of MODULE and its submodules.
MODULE is a parsed `just --dump' object.  Each recipe is a plist with
:name (the name to pass to just), :group, :doc, :params and :no-cd."
  (let ((path  (alist-get 'module_path module))
        (no-cd (alist-get 'no_cd (alist-get 'settings module))))
    (append
     (delq nil
           (mapcar
            (lambda (entry)
              (let* ((recipe (cdr entry))
                     (name   (alist-get 'name recipe))
                     (attrs  (alist-get 'attributes recipe)))
                (unless (or (alist-get 'private recipe)
                            (string-prefix-p "_" name))
                  (list :name   (or (alist-get 'namepath recipe) name)
                        :group  (or (consult-just--group-attribute attrs)
                                    (and (stringp path) (not (string-empty-p path))
                                         path))
                        :doc    (alist-get 'doc recipe)
                        :params (alist-get 'parameters recipe)
                        :no-cd  (or no-cd (and (member "no-cd" attrs) t))))))
            (alist-get 'recipes module)))
     (mapcan (lambda (entry) (consult-just--recipes (cdr entry)))
             (alist-get 'modules module)))))

(defun consult-just--root (dump)
  "Return the directory of the justfile described by DUMP.
Fall back to `default-directory' when just does not report a source."
  (let ((source (alist-get 'source dump)))
    (if (stringp source)
        (concat (file-remote-p default-directory)
                (file-name-directory source))
      default-directory)))

;;; Completion

(defun consult-just--candidates (recipes)
  "Return completion candidates for RECIPES.
Each candidate is the recipe name with the plist in the text property
`consult-just--recipe'."
  (mapcar (lambda (r) (propertize (plist-get r :name) 'consult-just--recipe r))
          recipes))

(defun consult-just--annotate-function (candidates)
  "Return an annotation function for CANDIDATES.
The group and the doc string are shown in two columns, each aligned
across all CANDIDATES.  The doc column starts right after the name
column when no recipe has a group."
  (let* ((width     (lambda (f) (apply #'max 0 (mapcar f candidates))))
         (group-col (+ 2 (funcall width #'string-width)))
         (group-len (funcall width
                             (lambda (c)
                               (string-width
                                (or (consult-just--get c :group) "")))))
         (doc-col   (if (> group-len 0) (+ group-col group-len 2) group-col)))
    (lambda (cand)
      (let ((group (consult-just--get cand :group))
            (doc   (consult-just--get cand :doc)))
        (when (or group doc)
          (concat
           (when group
             (concat (propertize " " 'display `(space :align-to ,group-col))
                     (propertize group 'face 'consult-just-group)))
           (when doc
             (concat (propertize " " 'display `(space :align-to ,doc-col))
                     (propertize doc 'face 'consult-just-doc)))))))))

(defun consult-just--get (cand prop)
  "Return PROP of the recipe of candidate CAND."
  (plist-get (get-text-property 0 'consult-just--recipe cand) prop))

;;; Running

(defun consult-just--signature (params)
  "Return a one-line description of recipe PARAMS for a prompt."
  (mapconcat
   (lambda (p)
     (let ((name    (alist-get 'name p))
           (default (alist-get 'default p)))
       (concat (pcase (alist-get 'kind p) ("star" "*") ("plus" "+") (_ ""))
               name
               (when (stringp default) (format "=%S" default)))))
   params " "))

(defun consult-just--read-arguments (recipe)
  "Return the argument string for RECIPE, prompting if it has parameters.
The string is passed to the shell unchanged; empty means none."
  (if-let* ((params (plist-get recipe :params)))
      (string-trim
       (read-string (format "Arguments for %s (%s): "
                            (plist-get recipe :name)
                            (consult-just--signature params))))
    ""))

(defun consult-just--command (name args)
  "Return the shell command that runs recipe NAME with ARGS."
  (concat (shell-quote-argument (file-local-name (consult-just--executable)))
          " " (shell-quote-argument name)
          (unless (string-empty-p args) (concat " " args))))

(defun consult-just--run (recipe args root)
  "Run RECIPE with ARGS in a compilation buffer.
The compilation runs in ROOT, the justfile's directory, because that is
where just runs recipes and where relative file names in the output are
meant; recipes with `no-cd' run in `default-directory' instead."
  (let* ((name (plist-get recipe :name))
         (default-directory (if (plist-get recipe :no-cd) default-directory root))
         (cmd (consult-just--command name args))
         (compilation-buffer-name-function
          (lambda (_mode) (format "*just: %s*" name))))
    (compile cmd)
    ;; Populate projectile's per-project compile cache so that
    ;; `projectile-compile-project' and friends re-run this command
    ;; without prompting.
    (when (and (fboundp 'projectile-compilation-dir)
               (boundp 'projectile-compilation-cmd-map))
      (puthash (projectile-compilation-dir) cmd projectile-compilation-cmd-map))))

;;; Public command

;;;###autoload
(defun consult-just ()
  "Select and run a just recipe using consult completion.

Each recipe is annotated with its group (its [group(...)] attribute, or
its module for recipes of `mod' submodules) and its doc string.  The
completion UI sorts the recipes; with the default `vertico' sorting,
recently used ones come first.
If the recipe has parameters, prompt for arguments.  The recipe runs in
a compilation buffer named *just: RECIPE*."
  (interactive)
  (let* ((dump       (consult-just--dump))
         (recipes    (or (consult-just--recipes dump)
                         (user-error "Consult-just: no public recipes in justfile")))
         (candidates (consult-just--candidates recipes))
         (selected
          (consult--read
           candidates
           :prompt "Recipe: "
           :require-match t
           :lookup #'consult--lookup-member
           :history 'consult-just--history
           :annotate (consult-just--annotate-function candidates)
           :category 'just-recipe))
         (recipe     (get-text-property 0 'consult-just--recipe selected)))
    (setq consult-just--history (delete-dups consult-just--history))
    (consult-just--run recipe
                       (consult-just--read-arguments recipe)
                       (consult-just--root dump))))

(provide 'consult-just)

;;; consult-just.el ends here
