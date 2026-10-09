;;; consult-just.el --- Consult-based completion for just recipes -*- lexical-binding: t; -*-

;; Author: Tobias Hammer <tohammer@users.noreply.github.com>
;; Maintainer: Tobias Hammer <tohammer@users.noreply.github.com>
;; Copyright (C) 2025 Tobias Hammer
;; Version: 0.2
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
;; Recipes are displayed with their group (if any) and doc string.
;; Recipes of `mod' submodules are listed as `module::recipe'.
;; Recently used recipes appear in a "Recent" section at the top.
;; Recipes with parameters prompt for an argument string.  The
;; selected recipe is executed in a compilation buffer.
;;
;; Usage:
;;   M-x consult-just
;;
;; Customization:
;;   `consult-just-executable'   - name or path of the just binary
;;   `consult-just-recent-count' - size of the "Recent" section

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

(defcustom consult-just-recent-count 5
  "Number of recently used recipes shown in the \"Recent\" section."
  :type 'natnum)

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

(defun consult-just--recent (recipes)
  "Return names of recently used RECIPES, most recent first.
Only names that exist in RECIPES count, so recipes from other justfiles
do not take up the \"Recent\" section."
  (let ((names (mapcar (lambda (r) (plist-get r :name)) recipes)))
    (seq-take (seq-filter (lambda (h) (member h names))
                          (seq-uniq consult-just--history))
              consult-just-recent-count)))

(defun consult-just--candidates (recipes recent)
  "Return completion candidates for RECIPES, the RECENT ones first.
Each candidate is the recipe name with the plist in the text property
`consult-just--recipe'."
  (let ((cands (mapcar (lambda (r)
                         (propertize (plist-get r :name) 'consult-just--recipe r))
                       recipes)))
    (append (delq nil (mapcar (lambda (name) (car (member name cands))) recent))
            (seq-remove (lambda (c) (member c recent)) cands))))

(defun consult-just--group-function (recent)
  "Return a consult group function that puts RECENT names under \"Recent\"."
  (lambda (cand transform)
    (cond (transform cand)
          ((member cand recent) "Recent")
          ((plist-get (get-text-property 0 'consult-just--recipe cand) :group))
          (t "Other"))))

(defun consult-just--annotate-function (candidates recent)
  "Return an annotation function for CANDIDATES.
Doc strings are aligned in one column.  Recipes in RECENT also show
their group, which their section heading no longer does."
  (let* ((name-col  (+ 4 (apply #'max (mapcar #'string-width candidates))))
         (group-len (apply #'max 0
                           (mapcar (lambda (c)
                                     (if-let* (((member c recent))
                                               (r (get-text-property 0 'consult-just--recipe c))
                                               (g (plist-get r :group)))
                                         (string-width g)
                                       0))
                                   candidates)))
         (doc-col   (if (> group-len 0) (+ name-col group-len 4) name-col)))
    (lambda (cand)
      (let* ((r     (get-text-property 0 'consult-just--recipe cand))
             (doc   (plist-get r :doc))
             (group (and (member cand recent) (plist-get r :group))))
        (when (or group doc)
          (concat
           (when group
             (concat (propertize " " 'display `(space :align-to ,name-col))
                     (propertize group 'face 'completions-annotations)))
           (when doc
             (concat (propertize " " 'display `(space :align-to ,doc-col))
                     (propertize doc 'face 'completions-annotations)))))))))

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

Recipes are grouped by their [group(...)] attribute, or by their module
for recipes of `mod' submodules.  Recently used recipes appear in a
\"Recent\" section at the top.  Doc strings are shown as annotations.
If the recipe has parameters, prompt for arguments.  The recipe runs in
a compilation buffer named *just: RECIPE*."
  (interactive)
  (let* ((dump       (consult-just--dump))
         (recipes    (or (consult-just--recipes dump)
                         (user-error "Consult-just: no public recipes in justfile")))
         (recent     (consult-just--recent recipes))
         (candidates (consult-just--candidates recipes recent))
         (selected
          (consult--read
           candidates
           :prompt "Recipe: "
           :require-match t
           :lookup #'consult--lookup-member
           :history 'consult-just--history
           :annotate (consult-just--annotate-function candidates recent)
           :category 'just-recipe
           :group (consult-just--group-function recent)
           :sort nil))
         (recipe     (get-text-property 0 'consult-just--recipe selected)))
    (setq consult-just--history (delete-dups consult-just--history))
    (consult-just--run recipe
                       (consult-just--read-arguments recipe)
                       (consult-just--root dump))))

(provide 'consult-just)

;;; consult-just.el ends here
