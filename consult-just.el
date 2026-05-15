;;; consult-just.el --- Consult-based completion for just recipes -*- lexical-binding: t; -*-

;; Author: Tobias Hammer
;; Maintainer: Tobias Hammer
;; Version: 0.1
;; Package-Requires: ((emacs "28.1") (consult "0.34"))
;; Keywords: convenience, tools, just
;; URL: https://github.com/tohammer/consult-just.el
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Provides `consult-just', an interactive command to select and run
;; recipes from a justfile using consult-based completion.
;;
;; Recipes are displayed with their group (if any) and doc string.
;; Recently used recipes appear in a "Recent" section at the top.
;; The selected recipe is executed in a compilation buffer.
;;
;; Annotations are provided via marginalia when available.
;;
;; Usage:
;;   M-x consult-just
;;
;; Customization:
;;   `consult-just-executable' - path to the just binary

;;; Code:

(require 'consult)
(require 'json)
(require 'compile)
(require 'seq)

(defgroup consult-just nil
  "Consult-based completion for just recipes."
  :group 'tools
  :prefix "consult-just-")

(defcustom consult-just-executable (executable-find "just")
  "Path to the just executable."
  :type 'string
  :group 'consult-just)

(defvar consult-just--history nil
  "History for `consult-just' recipe selection.")

(defvar consult-just--annotation-col 0
  "Column used for doc-string alignment in annotations; set dynamically.")

(defvar consult-just--doc-col 0
  "Column used for doc-string when a group column precedes it; set dynamically.")

;;; Internal helpers

(defun consult-just--parse-recipes ()
  "Parse recipes from the justfile found by `just' using `--dump --dump-format=json'.
Returns a list of plists with :name :group :doc."
  (unless consult-just-executable
    (user-error "consult-just: `just' executable not found; set `consult-just-executable'"))
  (let* ((json-str (with-temp-buffer
                     (call-process consult-just-executable nil t nil
                                   "--unstable"
                                   "--dump"
                                   "--dump-format=json")
                     (buffer-string)))
         (data (condition-case err
                   (json-parse-string json-str :object-type 'alist :array-type 'list :false-object nil)
                 (error (user-error "consult-just: failed to parse justfile: %s" (error-message-string err)))))
         (recipes-alist (alist-get 'recipes data)))
    (delq nil
          (mapcar (lambda (entry)
                    (let* ((recipe (cdr entry))
                           (private (alist-get 'private recipe))
                           (name    (alist-get 'name recipe))
                           (doc     (alist-get 'doc recipe))
                           (attrs   (alist-get 'attributes recipe))
                           (group   (car (delq nil (mapcar (lambda (a) (alist-get 'group a)) attrs)))))
                      (unless (or private (string-prefix-p "_" name))
                        (list :name name
                              :group (and (stringp group) group)
                              :doc   (and (stringp doc) doc)))))
                  recipes-alist))))

(defun consult-just--make-candidates (recipes)
  "Build consult candidate strings from RECIPES plists.
Each candidate is the recipe name, with text properties for group and doc."
  (mapcar (lambda (r)
            (let ((name  (plist-get r :name))
                  (group (plist-get r :group))
                  (doc   (plist-get r :doc)))
              (propertize name
                          'consult-just--group group
                          'consult-just--doc   doc)))
          recipes))

(defun consult-just--group (candidate transform)
  "Group function for `consult--read'.
Recently used recipes (up to 5) appear under \"Recent\"; others under their
justfile group or \"Other\".  When TRANSFORM is non-nil, return CANDIDATE."
  (if transform
      candidate
    (let ((name (substring-no-properties candidate)))
      (if (member name (seq-take consult-just--history 5))
          "Recent"
        (or (get-text-property 0 'consult-just--group candidate) "Other")))))

(defun consult-just--run (recipe)
  "Run RECIPE using just in a compilation buffer."
  (let* ((buf-name (format "*just: %s*" recipe))
         (cmd (mapconcat #'shell-quote-argument
                         (list consult-just-executable recipe)
                         " ")))
    (with-current-buffer (compile cmd)
      (rename-buffer buf-name t))
    ;; Populate projectile's per-project compile cache so F5 / recompile
    ;; can re-run this command without prompting.
    (when (and (fboundp 'projectile-compilation-dir)
               (boundp 'projectile-compilation-cmd-map))
      (puthash (projectile-compilation-dir) cmd projectile-compilation-cmd-map))))

;;; Marginalia integration

(defun consult-just--marginalia-annotate (candidate)
  "Marginalia annotator for `just-recipe' CANDIDATE."
  (let* ((doc   (get-text-property 0 'consult-just--doc   candidate))
         (group (get-text-property 0 'consult-just--group candidate))
         (in-recent (member (substring-no-properties candidate)
                            (seq-take consult-just--history 5)))
         (show-group (and in-recent group)))
    (when (or show-group doc)
      (concat
       (when show-group
         (concat (propertize " " 'display `(space :align-to ,consult-just--annotation-col))
                 marginalia-separator
                 (propertize group 'face 'marginalia-type)))
       (when doc
         (concat (propertize " " 'display `(space :align-to ,consult-just--doc-col))
                 marginalia-separator
                 (propertize doc 'face 'marginalia-documentation)))))))

(with-eval-after-load 'marginalia
  (add-to-list 'marginalia-annotators
               '(just-recipe consult-just--marginalia-annotate none)))

;;; Public command

;;;###autoload
(defun consult-just ()
  "Select and run a just recipe using consult completion.

Recipes are grouped by their [group(...)] attribute.  Previously used
recipes appear in a \"Recent\" section at the top.  Doc strings are shown
as annotations via marginalia (if active) or the built-in annotator.
The selected recipe runs in a named compilation buffer."
  (interactive)
  (let* ((recipes      (consult-just--parse-recipes))
         (recent-names (seq-take (seq-uniq consult-just--history) 5))
         (candidates   (let* ((all (consult-just--make-candidates recipes))
                              (recent (delq nil
                                           (mapcar (lambda (name)
                                                     (seq-find (lambda (c)
                                                                 (string= (substring-no-properties c) name))
                                                               all))
                                                   recent-names)))
                              (rest (seq-remove
                                     (lambda (c) (member (substring-no-properties c) recent-names))
                                     all)))
                          (append recent rest)))
         (name-col     (+ (apply #'max (mapcar (lambda (c) (length (substring-no-properties c)))
                                               candidates))
                          4))
         (max-group-len (let ((groups (delq nil
                                            (mapcar (lambda (c)
                                                      (when (member (substring-no-properties c) recent-names)
                                                        (get-text-property 0 'consult-just--group c)))
                                                    candidates))))
                          (if groups (apply #'max (mapcar #'length groups)) 0)))
         (doc-col      (if (> max-group-len 0) (+ name-col max-group-len 4) name-col))
         (annotate-fn  (lambda (candidate)
                         (let* ((doc   (get-text-property 0 'consult-just--doc   candidate))
                                (group (get-text-property 0 'consult-just--group candidate))
                                (show-group (and (member (substring-no-properties candidate) recent-names)
                                                 group)))
                           (when (or show-group doc)
                             (concat
                              (when show-group
                                (concat (propertize " " 'display `(space :align-to ,name-col))
                                        (propertize group 'face 'completions-annotations)))
                              (when doc
                                (concat (propertize " " 'display `(space :align-to ,doc-col))
                                        (propertize doc 'face 'completions-annotations))))))))
         (selected
          (let ((consult-just--annotation-col name-col)
                (consult-just--doc-col         doc-col))
            (consult--read
             candidates
             :prompt "Recipe: "
             :require-match t
             :history 'consult-just--history
             :annotate annotate-fn
             :category 'just-recipe
             :group #'consult-just--group
             :sort nil))))
    (setq consult-just--history (delete-dups consult-just--history))
    (consult-just--run selected)))

(provide 'consult-just)

;;; consult-just.el ends here

