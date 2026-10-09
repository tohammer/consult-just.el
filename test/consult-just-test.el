;;; consult-just-test.el --- Tests for consult-just -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run with:  make test
;;
;; Most tests work on a canned `just --dump --dump-format=json' output.
;; Tests marked "real just" need the just binary and are skipped
;; without it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'consult-just)

(defconst consult-just-test--json "
{\"source\": \"/path/to/project/justfile\",
 \"module_path\": \"\",
 \"settings\": {\"no_cd\": false},
 \"recipes\": {
   \"_under\": {\"name\": \"_under\", \"namepath\": \"_under\", \"private\": true,
              \"attributes\": [], \"doc\": null, \"parameters\": []},
   \"build\":  {\"name\": \"build\", \"namepath\": \"build\", \"private\": false,
              \"attributes\": [{\"group\": \"dev\"}], \"doc\": \"Build it\",
              \"parameters\": []},
   \"deploy\": {\"name\": \"deploy\", \"namepath\": \"deploy\", \"private\": false,
              \"attributes\": [], \"doc\": null,
              \"parameters\": [{\"name\": \"target\", \"default\": null, \"kind\": \"singular\"},
                             {\"name\": \"rest\", \"default\": null, \"kind\": \"star\"}]},
   \"hidden\": {\"name\": \"hidden\", \"namepath\": \"hidden\", \"private\": true,
              \"attributes\": [\"private\"], \"doc\": null, \"parameters\": []},
   \"test\":   {\"name\": \"test\", \"namepath\": \"test\", \"private\": false,
              \"attributes\": [{\"group\": \"ci\"}, {\"group\": \"dev\"}, \"no-cd\"],
              \"doc\": null,
              \"parameters\": [{\"name\": \"arg\", \"default\": \"x\", \"kind\": \"singular\"}]}},
 \"modules\": {
   \"sub\": {\"module_path\": \"sub\", \"settings\": {\"no_cd\": false}, \"modules\": {},
            \"recipes\": {
              \"foo\": {\"name\": \"foo\", \"namepath\": \"sub::foo\", \"private\": false,
                       \"attributes\": [], \"doc\": \"sub thing\", \"parameters\": []},
              \"bar\": {\"name\": \"bar\", \"namepath\": \"sub::bar\", \"private\": false,
                       \"attributes\": [{\"group\": \"tools\"}], \"doc\": null,
                       \"parameters\": []}}}}}"
  "Canned dump in the shape just 1.x prints.")

(defun consult-just-test--dump ()
  "Return the canned dump, parsed like `consult-just--dump' does."
  (json-parse-string consult-just-test--json
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun consult-just-test--recipes ()
  "Return the recipes of the canned dump."
  (consult-just--recipes (consult-just-test--dump)))

(defun consult-just-test--recipe (name)
  "Return the recipe NAME of the canned dump."
  (seq-find (lambda (r) (equal (plist-get r :name) name))
            (consult-just-test--recipes)))

(defmacro consult-just-test--with-fake-just (script &rest body)
  "Run BODY with `consult-just-executable' set to a shell SCRIPT."
  (declare (indent 1))
  `(let* ((file (make-temp-file "fake-just"))
          (consult-just-executable file))
     (unwind-protect
         (progn
           (with-temp-file file (insert "#!/bin/sh\n" ,script "\n"))
           (set-file-modes file #o755)
           ,@body)
       (delete-file file))))

;;; Parsing

(ert-deftest consult-just-test-plain-attributes ()
  "Attributes without an argument (\"no-cd\", \"private\") are strings.
Regression: they made parsing fail with `wrong-type-argument'."
  (should (consult-just-test--recipes)))

(ert-deftest consult-just-test-private-hidden ()
  "Private and underscore recipes are not listed."
  (let ((names (mapcar (lambda (r) (plist-get r :name)) (consult-just-test--recipes))))
    (should-not (member "hidden" names))
    (should-not (member "_under" names))
    (should (member "build" names))))

(ert-deftest consult-just-test-group ()
  "The first group attribute is the group; no group is nil."
  (should (equal (plist-get (consult-just-test--recipe "build") :group) "dev"))
  (should (equal (plist-get (consult-just-test--recipe "test") :group) "ci"))
  (should-not (plist-get (consult-just-test--recipe "deploy") :group)))

(ert-deftest consult-just-test-modules ()
  "Module recipes use their namepath; the module is the default group."
  (should (equal (plist-get (consult-just-test--recipe "sub::foo") :group) "sub"))
  (should (equal (plist-get (consult-just-test--recipe "sub::foo") :doc) "sub thing"))
  (should (equal (plist-get (consult-just-test--recipe "sub::bar") :group) "tools")))

(ert-deftest consult-just-test-no-cd ()
  "The no-cd attribute and the no-cd setting are both recognised."
  (should (plist-get (consult-just-test--recipe "test") :no-cd))
  (should-not (plist-get (consult-just-test--recipe "build") :no-cd))
  (let ((dump (consult-just-test--dump)))
    (setf (alist-get 'no_cd (alist-get 'settings dump)) t)
    (should (plist-get (car (consult-just--recipes dump)) :no-cd))))

(ert-deftest consult-just-test-root ()
  "The justfile's directory is the root, with the remote prefix kept."
  (let ((dump (consult-just-test--dump)))
    (let ((default-directory "/somewhere/else/"))
      (should (equal (consult-just--root dump) "/path/to/project/")))
    (let ((default-directory "/ssh:host:/somewhere/"))
      (should (equal (consult-just--root dump) "/ssh:host:/path/to/project/")))
    (let ((default-directory "/somewhere/else/"))
      (should (equal (consult-just--root '((recipes))) "/somewhere/else/")))))

;;; Reading just's output

(ert-deftest consult-just-test-dump-error ()
  "When just fails, its own message is reported.
Regression: the stderr text was parsed as JSON."
  (consult-just-test--with-fake-just "echo 'error: no justfile found' >&2; exit 1"
    (let ((err (should-error (consult-just--dump) :type 'user-error)))
      (should (string-match-p "no justfile found" (cadr err))))))

(ert-deftest consult-just-test-dump-ok ()
  "The dump is parsed; stderr output does not disturb the JSON."
  (consult-just-test--with-fake-just
      "echo warning >&2; echo '{\"recipes\": {}, \"modules\": {}}'"
    (should (equal (consult-just--dump) '((recipes) (modules))))))

(ert-deftest consult-just-test-missing-executable ()
  "A missing executable gives a `user-error'."
  (let ((consult-just-executable "consult-just-no-such-binary"))
    (should-error (consult-just--dump) :type 'user-error)))

;;; Completion

(ert-deftest consult-just-test-candidates ()
  "Candidates are the recipe names with the recipe attached."
  (let ((cands (consult-just--candidates (consult-just-test--recipes))))
    (should (member "sub::foo" cands))
    (should (equal (consult-just--get (car (member "build" cands)) :doc)
                   "Build it"))))

(defun consult-just-test--annotations ()
  "Return an alist of candidate name to annotation for the canned dump."
  (let* ((cands (consult-just--candidates (consult-just-test--recipes)))
         (annotate (consult-just--annotate-function cands)))
    (mapcar (lambda (c) (cons c (funcall annotate c))) cands)))

(defun consult-just-test--align-to (annotation text)
  "Return the :align-to column of the space before TEXT in ANNOTATION."
  (let ((pos (string-search text annotation)))
    (and pos (> pos 0)
         (nth 2 (get-text-property (1- pos) 'display annotation)))))

(ert-deftest consult-just-test-annotate ()
  "Every recipe shows its group and its doc string, if it has them."
  (let ((anns (consult-just-test--annotations)))
    (should (equal (substring-no-properties (cdr (assoc "build" anns)))
                   " dev Build it"))
    (should (equal (substring-no-properties (cdr (assoc "sub::foo" anns)))
                   " sub sub thing"))
    (should (equal (substring-no-properties (cdr (assoc "test" anns))) " ci"))
    (should-not (cdr (assoc "deploy" anns)))
    (should (eq (get-text-property 1 'face (cdr (assoc "build" anns)))
                'consult-just-group))
    (should (eq (get-text-property 0 'face (substring (cdr (assoc "build" anns)) -1))
                'consult-just-doc))))

(ert-deftest consult-just-test-annotate-alignment ()
  "Groups share one column after the longest name; docs share another
after the longest group."
  (let* ((anns (consult-just-test--annotations))
         (name-width (apply #'max (mapcar (lambda (a) (string-width (car a))) anns)))
         (group-col (+ name-width 2))
         (doc-col (+ group-col (length "tools") 2)))
    (should (equal (consult-just-test--align-to (cdr (assoc "build" anns)) "dev")
                   group-col))
    (should (equal (consult-just-test--align-to (cdr (assoc "sub::bar" anns)) "tools")
                   group-col))
    (should (equal (consult-just-test--align-to (cdr (assoc "build" anns)) "Build it")
                   doc-col))
    (should (equal (consult-just-test--align-to (cdr (assoc "sub::foo" anns)) "sub thing")
                   doc-col))))

(ert-deftest consult-just-test-annotate-no-groups ()
  "Without any group, the doc column follows the name column."
  (let* ((cands (consult-just--candidates
                 (list (list :name "a" :doc "Doc a") (list :name "bbb"))))
         (ann (funcall (consult-just--annotate-function cands) (car cands))))
    (should (equal (consult-just-test--align-to ann "Doc a") 5))))

(ert-deftest consult-just-test-no-recipes ()
  "A justfile without public recipes gives a `user-error'.
Regression: `max' was applied to an empty list."
  (cl-letf (((symbol-function 'consult-just--dump)
             (lambda () '((recipes) (modules)))))
    (should-error (consult-just) :type 'user-error)))

;;; Running

(ert-deftest consult-just-test-signature ()
  "Parameters are shown with their kind and default."
  (should (equal (consult-just--signature
                  (plist-get (consult-just-test--recipe "deploy") :params))
                 "target *rest"))
  (should (equal (consult-just--signature
                  (plist-get (consult-just-test--recipe "test") :params))
                 "arg=\"x\"")))

(ert-deftest consult-just-test-read-arguments ()
  "Prompt only for recipes with parameters."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (error "Prompted"))))
    (should (equal (consult-just--read-arguments (consult-just-test--recipe "build")) "")))
  (let (prompt)
    (cl-letf (((symbol-function 'read-string)
               (lambda (p &rest _) (setq prompt p) "  prod a b ")))
      (should (equal (consult-just--read-arguments (consult-just-test--recipe "deploy"))
                     "prod a b"))
      (should (string-match-p "deploy (target \\*rest)" prompt)))))

(ert-deftest consult-just-test-run-directory-and-command ()
  "Recipes run in the justfile's directory, no-cd recipes where invoked.
Regression: they ran in `default-directory', so relative file names in
the output pointed to the wrong place."
  (let ((consult-just-executable "sh") calls)
    (cl-letf (((symbol-function 'compile)
               (lambda (cmd &rest _)
                 (push (list default-directory cmd
                             (funcall compilation-buffer-name-function 'compilation-mode))
                       calls))))
      (let ((default-directory "/path/to/project/sub/"))
        (consult-just--run (consult-just-test--recipe "build") "" "/path/to/project/")
        (consult-just--run (consult-just-test--recipe "test") "y" "/path/to/project/")))
    (should (equal (nth 1 calls)
                   (list "/path/to/project/"
                         (concat (shell-quote-argument (executable-find "sh")) " build")
                         "*just: build*")))
    (should (equal (car (nth 0 calls)) "/path/to/project/sub/"))
    (should (string-suffix-p " test y" (nth 1 (nth 0 calls))))))

(ert-deftest consult-just-test-run-reuses-buffer ()
  "Running a recipe twice reuses its compilation buffer.
Regression: the buffer was renamed after `compile', so each run left a
*just: NAME*<N> buffer behind."
  (let ((consult-just-executable "echo")
        (compilation-ask-about-save nil)
        (default-directory temporary-file-directory))
    (dotimes (_ 2)
      (consult-just--run (consult-just-test--recipe "build") "" default-directory)
      (with-current-buffer "*just: build*"
        (while (get-buffer-process (current-buffer))
          (accept-process-output nil 0.05))))
    (should (equal (seq-filter (lambda (n) (string-prefix-p "*just: build*" n))
                               (mapcar #'buffer-name (buffer-list)))
                   '("*just: build*")))
    (should-not (get-buffer "*compilation*"))
    (kill-buffer "*just: build*")))

(ert-deftest consult-just-test-command-end-to-end ()
  "`consult-just' passes the selected recipe, its arguments and the root.
Sorting is left to the completion UI and nothing is grouped."
  (let (ran options)
    (cl-letf (((symbol-function 'consult-just--dump) #'consult-just-test--dump)
              ((symbol-function 'consult--read)
               (lambda (cands &rest opts)
                 (setq options opts)
                 (car (member "deploy" cands))))
              ((symbol-function 'read-string) (lambda (&rest _) "prod"))
              ((symbol-function 'consult-just--run)
               (lambda (r args root) (setq ran (list (plist-get r :name) args root)))))
      (let ((consult-just--history nil))
        (consult-just)))
    (should (equal ran '("deploy" "prod" "/path/to/project/")))
    (should-not (plist-member options :sort))
    (should-not (plist-member options :group))
    (should (eq (plist-get options :history) 'consult-just--history))))

;;; Real just

(ert-deftest consult-just-test-real-just ()
  "Real just: modules, attributes and the root from a subdirectory."
  (skip-unless (executable-find "just"))
  (let* ((root (file-name-as-directory (make-temp-file "consult-just" t)))
         (consult-just-executable "just"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "sub" root))
          (make-directory (expand-file-name "deep" root))
          (with-temp-file (expand-file-name "justfile" root)
            (insert "mod sub\n\n# Build it\n[group('dev')]\nbuild:\n    true\n\n"
                    "[private]\nhidden:\n    true\n\n[no-cd]\nhere arg='x':\n    true\n"))
          (with-temp-file (expand-file-name "sub/justfile" root)
            (insert "foo:\n    true\n"))
          (let* ((default-directory (expand-file-name "deep/" root))
                 (dump (consult-just--dump))
                 (recipes (consult-just--recipes dump)))
            (should (equal (sort (mapcar (lambda (r) (plist-get r :name)) recipes) #'string<)
                           '("build" "here" "sub::foo")))
            (should (equal (file-truename (consult-just--root dump))
                           (file-truename root)))))
      (delete-directory root t))))

;;; consult-just-test.el ends here
