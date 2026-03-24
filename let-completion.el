;;; let-completion.el --- Show let-binding values in Elisp completion -*- lexical-binding: t -*-

;; Author: Gino Cornejo <gggion123@gmail.com>
;; Maintainer: Gino Cornejo <gggion123@gmail.com>
;; URL: https://github.com/gggion/let-completion.el
;; Keywords: lisp, completion

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `let-completion-mode' makes Emacs Lisp in-buffer completion
;; aware of lexically enclosing binding forms.  Local variables
;; are promoted to the top of the candidate list, annotated with their
;; binding values when short enough or a [local] tag otherwise, and
;; shown in full via pretty-printed fontified expressions in
;; corfu-popupinfo or any completion UI that reads `:company-doc-buffer'.
;;
;; Binding form recognition is data-driven via a registry of
;; descriptors stored as symbol properties.  Built-in forms (`let',
;; `let*', `defun', `lambda', `dolist', `condition-case', etc.) are
;; registered at load time.  Third-party macros opt in by calling
;; `let-completion-register-binding-form'.
;;
;; Usage:
;;
;;     (add-hook 'emacs-lisp-mode-hook #'let-completion-mode)
;;
;; Customize `let-completion-inline-max-width' to control the maximum
;; printed width for inline value annotations, or set it to nil to
;; always show [local] instead.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defgroup let-completion nil
  "Show let-binding values in Elisp completion."
  :group 'lisp
  :prefix "let-completion-")

(defcustom let-completion-annotation-format " %s"
  "Format string for inline value annotation.
Receives one string argument: the printed binding value or the
fallback label from `let-completion-annotation-fallback'.

Also see `let-completion-annotation-format-tag' and
`let-completion-inline-max-width'."
  :type 'string)

(defcustom let-completion-annotation-format-tag " [%s]"
  "Format string for tag annotation.
Receives one string argument: the tag label (e.g. \"&optional\",
\"fn\", \"let\").  The tag annotation precedes the value annotation
when both are present.

Set to nil to disable tag annotations entirely and fall back to
value-only display as in version 0.1.

Also see `let-completion-annotation-format'."
  :type '(choice string (const :tag "Disable" nil)))

(defcustom let-completion-annotation-fallback "local"
  "Label shown when binding value is absent or too wide to display.
Used when `let-completion-inline-max-width' is exceeded or value
is nil, and tag annotations are disabled.

Also see `let-completion-annotation-format' and
`let-completion-annotation-format-tag'."
  :type 'string)

(defcustom let-completion-inline-max-width 5
  "Max printed width for inline value annotation, or nil to disable.
Only binding values whose `prin1-to-string' form fits within this
many characters appear inline next to the candidate.  Longer values
show \" [local]\" instead.  The popupinfo buffer always shows the
full value regardless of this setting.

Also see `let-completion-mode'."
  :type '(choice natnum (const :tag "Disable" nil)))

(defcustom let-completion-tag-refine-alist nil
  "Alist mapping (TAG . VALUE-HEAD) to replacement tag strings.
Each key is a cons of (TAG-STRING . SYMBOL-OR-NIL) where
SYMBOL-OR-NIL is the `car-safe' of the binding value.  When a
binding's tag and value head match a key, the associated string
replaces the tag.

Consulted before `let-completion-tag-refine-function'.  First
match wins.

Example:

    \\='(((\"let\" . lambda) . \"λ let\")
      ((\"arg\" . lambda) . \"LAMBDA arg\"))

Also see `let-completion-tag-refine-function'."
  :type '(alist :key-type (cons string symbol)
                :value-type string))

(defcustom let-completion-tag-refine-function nil
  "Function to refine tag strings based on binding context.
Receives three arguments: NAME (string), TAG (string), and VALUE
\(the raw sexp or nil).  Returns a replacement tag string.
Return nil to keep the original TAG.

This function runs after `let-completion-tag-refine-alist' is
consulted.  Use it for context-dependent logic that the alist
cannot express.

Also see `let-completion-tag-refine-alist'."
  :type '(choice function (const :tag "Disable" nil)))

(defcustom let-completion-tag-alist nil
  "Alist mapping binding form symbols to replacement tag strings.
Each entry is (SYMBOL . TAG-STRING).  When a binding form's head
symbol matches SYMBOL, TAG-STRING replaces the tag from the
registry descriptor before any refinement via
`let-completion-tag-refine-alist' or
`let-completion-tag-refine-function'.

Example:

    \\='((cond-let--and-let* . \"clet\")
      (dolist . \"each\")
      (condition-case . \"rescue\"))"
  :type '(alist :key-type symbol :value-type string))

;;;; Binding Form Registry

(defvar-local let-completion-binding-forms nil
  "Buffer-local alist overriding binding form descriptors.
Each entry is (SYMBOL . SPEC) where SPEC is a plist or function.
Takes priority over symbol properties at lookup time.

Set by major mode hooks for non-Elisp Lisp dialects.")

(defun let-completion-register-binding-form (symbol spec)
  "Register SYMBOL as a binding form with descriptor SPEC.
SPEC is either a plist with keys `:bindings-index', `:binding-shape',
`:scope', and `:tag', or a function receiving (POS COMPLETION-POS)
and returning an alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL).

`:bindings-index' is the 1-based position of the binding sexp
after the head symbol.  `:binding-shape' is one of `list',
`arglist', `single', `error-var'.  `:scope' is one of `body',
`then', `handlers'.  `:tag' is a string label for annotation
display (e.g. \"let\", \"arg\", \"var\", \"err\").

Store SPEC as symbol property `let-completion--binding-form'.
Buffer-local overrides via `let-completion-binding-forms' take
priority at lookup time.

Called at load time for built-in forms.  Third-party macros call
this to opt in."
  (put symbol 'let-completion--binding-form spec))

(defun let-completion--lookup-spec (symbol)
  "Look up binding form descriptor for SYMBOL.
Check buffer-local `let-completion-binding-forms' first, then
symbol property `let-completion--binding-form'.

Return SPEC or nil."
  (or (alist-get symbol let-completion-binding-forms)
      (get symbol 'let-completion--binding-form)))

;;;;; Built-in Registrations

;;;;;; list shape: ((VAR EXPR) ...) bindings

;; Index 1, body scope.
(let-completion-register-binding-form 'let
  '(:bindings-index 1 :binding-shape list :scope body :tag "let"))
(let-completion-register-binding-form 'let*
  '(:bindings-index 1 :binding-shape list :scope body :tag "let"))
(let-completion-register-binding-form 'when-let*
  '(:bindings-index 1 :binding-shape list :scope body :tag "let"))
(let-completion-register-binding-form 'and-let*
  '(:bindings-index 1 :binding-shape list :scope body :tag "let"))
(let-completion-register-binding-form 'dlet
  '(:bindings-index 1 :binding-shape list :scope body :tag "let"))
(let-completion-register-binding-form 'letrec
  '(:bindings-index 1 :binding-shape list :scope body :tag "let"))
(let-completion-register-binding-form 'cl-do
  '(:bindings-index 1 :binding-shape list :scope body :tag "do"))
(let-completion-register-binding-form 'cl-do*
  '(:bindings-index 1 :binding-shape list :scope body :tag "do"))
(let-completion-register-binding-form 'cl-symbol-macrolet
  '(:bindings-index 1 :binding-shape list :scope body :tag "symm"))
(let-completion-register-binding-form 'with-slots
  '(:bindings-index 1 :binding-shape list :scope body :tag "slot"))

;; Index 1, then scope.
(let-completion-register-binding-form 'if-let
  '(:bindings-index 1 :binding-shape list :scope then :tag "let"))
(let-completion-register-binding-form 'if-let*
  '(:bindings-index 1 :binding-shape list :scope then :tag "let"))

;; Index 2, body scope.
(let-completion-register-binding-form 'named-let
  '(:bindings-index 2 :binding-shape list :scope body :tag "let"))

;;;;;; arglist shape: (ARG &optional ARG2 &rest ARG3) parameters

;; Index 1, body scope.
(let-completion-register-binding-form 'lambda
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-destructuring-bind
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-multiple-value-bind
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "mv"))
(let-completion-register-binding-form 'cl-with-gensyms
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "sym"))
(let-completion-register-binding-form 'cl-once-only
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "sym"))

;; Index 2, body scope.
(let-completion-register-binding-form 'defun
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'defmacro
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'defsubst
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-defun
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-defmacro
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-defsubst
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'define-inline
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-defgeneric
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-defmethod
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'iter-defun
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-iter-defun
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))

;;;;;; single shape: (VAR EXPR) one binding

(let-completion-register-binding-form 'dolist
  '(:bindings-index 1 :binding-shape single :scope body :tag "var"))
(let-completion-register-binding-form 'dotimes
  '(:bindings-index 1 :binding-shape single :scope body :tag "var"))
(let-completion-register-binding-form 'cl-do-symbols
  '(:bindings-index 1 :binding-shape single :scope body :tag "var"))
(let-completion-register-binding-form 'cl-do-all-symbols
  '(:bindings-index 1 :binding-shape single :scope body :tag "var"))
(let-completion-register-binding-form 'dolist-with-progress-reporter
  '(:bindings-index 1 :binding-shape single :scope body :tag "var"))
(let-completion-register-binding-form 'dotimes-with-progress-reporter
  '(:bindings-index 1 :binding-shape single :scope body :tag "var"))

;;;;;; error-var shape: bare symbol

(let-completion-register-binding-form 'condition-case
  '(:bindings-index 1 :binding-shape error-var :scope handlers :tag "err"))
(let-completion-register-binding-form 'condition-case-unless-debug
  '(:bindings-index 1 :binding-shape error-var :scope handlers :tag "err"))
(let-completion-register-binding-form 'ert-with-temp-file
  '(:bindings-index 1 :binding-shape error-var :scope body :tag "file"))
(let-completion-register-binding-form 'ert-with-temp-directory
  '(:bindings-index 1 :binding-shape error-var :scope body :tag "dir"))
(let-completion-register-binding-form 'ert-with-message-capture
  '(:bindings-index 1 :binding-shape error-var :scope body :tag "msg"))

;;;;;; Custom extractors

(let-completion-register-binding-form 'cl-flet
  '(:extractor let-completion--extract-flet :tag "fn"))
(let-completion-register-binding-form 'cl-labels
  '(:extractor let-completion--extract-flet :tag "fn"))
(let-completion-register-binding-form 'cl-macrolet
  '(:extractor let-completion--extract-flet :tag "mac"))
(let-completion-register-binding-form 'cl-letf
  '(:extractor let-completion--extract-letf :tag "letf"))
(let-completion-register-binding-form 'cl-letf*
  '(:extractor let-completion--extract-letf :tag "letf"))


;;;; Scope Checking

(defun let-completion--scope-visible-p
    (form-start bindings-end completion-pos scope)
  "Return non-nil if COMPLETION-POS is in scope per SCOPE.
FORM-START is the opening paren of the entire form.
BINDINGS-END is the position after the binding sexp.

`body'     -- visible in all forms after the binding list.
`then'     -- visible only in the first form after the binding list.
`handlers' -- visible in all forms after the second element
              (the protected expression in `condition-case').

Called by `let-completion--extract-by-spec'."
  (ignore form-start)
  (pcase scope
    ('body
     (> completion-pos bindings-end))
    ('then
     (and (> completion-pos bindings-end)
          (save-excursion
            (goto-char bindings-end)
            (skip-chars-forward " \t\n")
            (let ((then-end (ignore-errors (scan-sexps (point) 1))))
              (or (null then-end)
                  (<= completion-pos then-end))))))
    ('handlers
     (save-excursion
       (goto-char bindings-end)
       (skip-chars-forward " \t\n")
       ;; Skip the protected expression.
       (let ((protected-end (ignore-errors (scan-sexps (point) 1))))
         (and protected-end
              (> completion-pos protected-end)))))
    (_ t)))

;;;; Shape Extractors

(defun let-completion--extract-shape (shape start end completion-pos tag)
  "Dispatch extraction on SHAPE between START and END.
COMPLETION-POS is used to skip bindings that contain point.
TAG is the base tag string from the registry descriptor.
SHAPE is one of `list', `arglist', `single', `error-var'.

Return alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL).

Called by `let-completion--extract-by-spec'."
  (pcase shape
    ('list     (let-completion--extract-shape-list
                start end completion-pos tag))
    ('arglist  (let-completion--extract-shape-arglist
                start end completion-pos tag))
    ('single   (let-completion--extract-shape-single
                start end completion-pos tag))
    ('error-var (let-completion--extract-shape-error-var
                 start end completion-pos tag))))

(defun let-completion--extract-shape-list (start end completion-pos tag)
  "Extract bindings from a list-shaped form between START and END.
Handle ((VAR EXPR) ...) and bare (VAR ...) entries.
TAG is the base tag string from the registry descriptor.
Skip any binding whose span contains COMPLETION-POS.

Return alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL).

Used for `let', `let*', `when-let*', `if-let*', `and-let*', `dlet'.
Called by `let-completion--extract-shape'."
  (save-excursion
    (goto-char (1+ start))
    (let (result)
      (while (progn (skip-chars-forward " \t\n")
                    (< (point) (1- end)))
        (let ((b-start (point)))
          (condition-case nil
              (let ((b-end (scan-sexps (point) 1)))
                (if (<= b-start completion-pos b-end)
                    (goto-char b-end)
                  (cond
                   ;; (VAR EXPR) -- compound binding.
                   ((eq (char-after b-start) ?\()
                    (save-excursion
                      (goto-char (1+ b-start))
                      (skip-chars-forward " \t\n")
                      (let ((name-start (point))
                            (name-end (ignore-errors
                                        (scan-sexps (point) 1))))
                        (when name-end
                          (let* ((name (buffer-substring-no-properties
                                        name-start name-end))
                                 (value
                                  (condition-case nil
                                      (progn
                                        (goto-char name-end)
                                        (skip-chars-forward " \t\n")
                                        (when (< (point) (1- b-end))
                                          (let* ((vs (point))
                                                 (ve (scan-sexps (point) 1)))
                                            (when ve
                                              (car (read-from-string
                                                    (buffer-substring-no-properties
                                                     vs ve)))))))
                                    (error nil))))
                            (push (cons name (cons tag value)) result))))))
                   ;; Bare symbol.
                   (t
                    (let ((name (buffer-substring-no-properties
                                 b-start b-end)))
                      (push (cons name (cons tag nil)) result))))
                  (goto-char b-end)))
            ;; scan-sexps failed -- bail out.
            (error (goto-char end)))))
      result)))

(defun let-completion--arglist-non-binding-p (name)
  "Return non-nil if NAME is not a variable binding in a compound spec.
Non-binding elements include lambda-list keywords, keyword symbols,
boolean constants, and numeric literals.  These appear as default
values or structural markers inside compound arglist specs.

Called by `let-completion--extract-shape-arglist'."
  (or (string-prefix-p "&" name)
      (string-prefix-p ":" name)
      (string= name "nil")
      (string= name "t")
      (string-match-p "\\`[0-9+-]" name)))

(defun let-completion--extract-shape-arglist (start end completion-pos tag)
  "Extract parameter names from an arglist between START and END.
Skip lambda-list keywords.  For bare symbols, collect directly.
For compound specs like (VAR DEFAULT SUPPLIED-P), enter the list
and collect bare symbols that pass `let-completion--arglist-non-binding-p'.

Handle the CL extended keyword spec ((:KEYWORD VAR) DEFAULT) by
entering the inner list and collecting the second element when
the current context is `&key'.

Track the current lambda-list keyword to refine TAG per parameter.
TAG is the base tag string from the registry descriptor, used for
required parameters.  Lambda-list keywords override it.
Skip any name whose span contains COMPLETION-POS.

Return alist of (NAME-STRING TAG-STRING . nil).

Used for `defun', `defmacro', `defsubst', `cl-defun', `lambda',
`cl-destructuring-bind'.
Called by `let-completion--extract-shape'."
  (save-excursion
    (goto-char (1+ start))
    (let (result
          (current-tag tag))
      (while (progn (skip-chars-forward " \t\n")
                    (< (point) (1- end)))
        (let ((sym-start (point)))
          (condition-case nil
              (let ((sym-end (scan-sexps (point) 1)))
                (if (<= sym-start completion-pos sym-end)
                    (goto-char sym-end)
                  (cond
                   ;; Navigate: lambda-list keyword -- update tag, do not
                   ;; collect.
                   ((and (not (eq (char-after sym-start) ?\())
                         (let ((name (buffer-substring-no-properties
                                      sym-start sym-end)))
                           (when (string-prefix-p "&" name)
                             (setq current-tag name)
                             t))))
                   ;; Walk: compound spec -- enter and collect symbols.
                   ((eq (char-after sym-start) ?\()
                    (save-excursion
                      (goto-char (1+ sym-start))
                      (while (progn (skip-chars-forward " \t\n")
                                    (< (point) (1- sym-end)))
                        (let ((inner-start (point)))
                          (condition-case nil
                              (let ((inner-end (scan-sexps (point) 1)))
                                (unless (<= inner-start
                                            completion-pos inner-end)
                                  (cond
                                   ;; Entry: inner list in &key context is
                                   ;; ((:KEYWORD VAR) ...).  Enter and take
                                   ;; second element as variable name.
                                   ((eq (char-after inner-start) ?\()
                                    (when (string= current-tag "&key")
                                      (save-excursion
                                        (goto-char (1+ inner-start))
                                        ;; Navigate: skip keyword element.
                                        (skip-chars-forward " \t\n")
                                        (ignore-errors (forward-sexp 1))
                                        ;; Navigate: now at VAR position.
                                        (skip-chars-forward " \t\n")
                                        (when (< (point) (1- inner-end))
                                          (let* ((var-start (point))
                                                 (var-end
                                                  (ignore-errors
                                                    (scan-sexps (point) 1))))
                                            (when (and var-end
                                                       (not (eq (char-after
                                                                 var-start)
                                                                ?\()))
                                              (let ((vname
                                                     (buffer-substring-no-properties
                                                      var-start var-end)))
                                                (unless
                                                    (let-completion--arglist-non-binding-p
                                                     vname)
                                                  (push
                                                   (cons vname
                                                         (cons current-tag
                                                               nil))
                                                   result)))))))))
                                   ;; Entry: quoted form or string -- skip.
                                   ((memq (char-after inner-start) '(?' ?\"))
                                    nil)
                                   ;; Entry: bare symbol -- collect if it
                                   ;; passes the non-binding filter.
                                   (t
                                    (let ((inner-name
                                           (buffer-substring-no-properties
                                            inner-start inner-end)))
                                      (unless
                                          (let-completion--arglist-non-binding-p
                                           inner-name)
                                        (push (cons inner-name
                                                    (cons current-tag nil))
                                              result))))))
                                (goto-char inner-end))
                            (error (goto-char sym-end)))))))
                   ;; Entry: plain parameter name -- collect with current tag.
                   (t
                    (let ((name (buffer-substring-no-properties
                                 sym-start sym-end)))
                      (push (cons name (cons current-tag nil)) result))))
                  (goto-char sym-end)))
            (error (goto-char end)))))
      result)))

(defun let-completion--extract-shape-single (start end completion-pos tag)
  "Extract one binding from a (VAR EXPR) form between START and END.
TAG is the base tag string from the registry descriptor.
Skip if span contains COMPLETION-POS.

Name is extracted via `scan-sexps'.  Value is attempted via `read'
with silent fallback to nil.

Return one-element alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL)
or nil.

Used for `dolist', `dotimes'.
Called by `let-completion--extract-shape'."
  (if (<= start completion-pos end)
      nil
    (save-excursion
      (goto-char (1+ start))
      (skip-chars-forward " \t\n")
      (let ((name-start (point))
            (name-end (ignore-errors (scan-sexps (point) 1))))
        (when name-end
          (let* ((name (buffer-substring-no-properties
                        name-start name-end))
                 (value (condition-case nil
                            (progn
                              (goto-char name-end)
                              (skip-chars-forward " \t\n")
                              (when (< (point) (1- end))
                                (let* ((vs (point))
                                       (ve (scan-sexps (point) 1)))
                                  (when ve
                                    (car (read-from-string
                                          (buffer-substring-no-properties
                                           vs ve)))))))
                          ;; if read or scan-sexps failed, return nil
                          (error nil))))
            (list (cons name (cons tag value)))))))))

(defun let-completion--extract-shape-error-var (start end completion-pos tag)
  "Extract one name from a bare symbol between START and END.
TAG is the base tag string from the registry descriptor.
Skip if span contains COMPLETION-POS.

Return one-element alist of (NAME-STRING TAG-STRING . nil) or nil.

Used for `condition-case'.
Called by `let-completion--extract-shape'."
  (if (<= start completion-pos end)
      nil
    (let ((name (string-trim
                 (buffer-substring-no-properties start end))))
      (unless (or (string-empty-p name) (string= name "nil"))
        (list (cons name (cons tag nil)))))))

;;; Custom Extractor Functions

(defun let-completion--extract-flet (pos completion-pos tag)
  "Extract function names from a flet-like form at POS.
COMPLETION-POS is point.  TAG is the annotation label from the
registry descriptor.

Walk the binding list at index 1.  Each entry has the structure
\(FUNC ARGLIST BODY...).  Extract FUNC as name via `scan-sexps'.
Values are nil.  Scope check requires COMPLETION-POS past the
binding list end.  Skip entries whose span contains COMPLETION-POS.

Return alist of (NAME-STRING TAG-STRING . nil) or nil.

Used for `cl-flet', `cl-labels', `cl-macrolet'.
Called by `let-completion--extract-bindings-at' via `:extractor'."
  (save-excursion
    (goto-char (1+ pos))
    (skip-chars-forward " \t\n")
    ;; -- Navigate: skip head symbol.
    (let ((head-end (ignore-errors (scan-sexps (point) 1))))
      (when head-end
        (goto-char head-end)
        (skip-chars-forward " \t\n")
        ;; -- Navigate: now at binding list.
        (let ((list-start (point))
              (list-end (ignore-errors (scan-sexps (point) 1))))
          ;; -- Scope: binding list must end before completion-pos.
          (when (and list-end
                     (> completion-pos list-end))
            (goto-char (1+ list-start))
            ;; -- Walk: iterate entries in binding list.
            (let (result)
              (while (progn (skip-chars-forward " \t\n")
                            (< (point) (1- list-end)))
                (let ((entry-start (point)))
                  (condition-case nil
                      (let ((entry-end (scan-sexps (point) 1)))
                        ;; -- Entry: skip if not a list or contains point.
                        (when (and (eq (char-after entry-start) ?\()
                                   (not (<= entry-start
                                             completion-pos entry-end)))
                          (save-excursion
                            (goto-char (1+ entry-start))
                            (skip-chars-forward " \t\n")
                            ;; -- Entry: extract name (first element).
                            (let ((name-start (point))
                                  (name-end (ignore-errors
                                              (scan-sexps (point) 1))))
                              (when name-end
                                (let ((name (buffer-substring-no-properties
                                             name-start name-end)))
                                  (push (cons name (cons tag nil))
                                        result))))))
                        (goto-char entry-end))
                    (error (goto-char list-end)))))
              result)))))))

(defun let-completion--extract-letf (pos completion-pos tag)
  "Extract symbol-place bindings from a letf-like form at POS.
COMPLETION-POS is point.  TAG is the annotation label from the
registry descriptor.

Walk the binding list at index 1.  Each entry has the structure
\(PLACE VALUE).  Only entries where PLACE is a bare symbol (not a
generalized place like (symbol-function \\='foo)) produce bindings.
Value is extracted via `read-from-string' with silent fallback to nil.

Return alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL) or nil.

Used for `cl-letf', `cl-letf*'.
Called by `let-completion--extract-bindings-at' via `:extractor'."
  (save-excursion
    (goto-char (1+ pos))
    (skip-chars-forward " \t\n")
    ;; -- Navigate: skip head symbol.
    (let ((head-end (ignore-errors (scan-sexps (point) 1))))
      (when head-end
        (goto-char head-end)
        (skip-chars-forward " \t\n")
        ;; -- Navigate: now at binding list.
        (let ((list-start (point))
              (list-end (ignore-errors (scan-sexps (point) 1))))
          ;; -- Scope: binding list must end before completion-pos.
          (when (and list-end
                     (> completion-pos list-end))
            (goto-char (1+ list-start))
            ;; -- Walk: iterate entries in binding list.
            (let (result)
              (while (progn (skip-chars-forward " \t\n")
                            (< (point) (1- list-end)))
                (let ((entry-start (point)))
                  (condition-case nil
                      (let ((entry-end (scan-sexps (point) 1)))
                        ;; -- Entry: skip if not a list or contains point.
                        (when (and (eq (char-after entry-start) ?\()
                                   (not (<= entry-start
                                             completion-pos entry-end)))
                          (save-excursion
                            (goto-char (1+ entry-start))
                            (skip-chars-forward " \t\n")
                            ;; -- Entry: read PLACE position.
                            (let ((place-start (point))
                                  (place-end (ignore-errors
                                               (scan-sexps (point) 1))))
                              (when place-end
                                ;; -- Entry: only bare symbols, skip
                                ;;    generalized places like (elt v 0).
                                (unless (eq (char-after place-start) ?\()
                                  (let* ((name (buffer-substring-no-properties
                                                place-start place-end))
                                         ;; -- Entry: extract value via read.
                                         (value
                                          (condition-case nil
                                              (progn
                                                (goto-char place-end)
                                                (skip-chars-forward " \t\n")
                                                (when (< (point)
                                                         (1- entry-end))
                                                  (let* ((vs (point))
                                                         (ve (scan-sexps
                                                              (point) 1)))
                                                    (when ve
                                                      (car
                                                       (read-from-string
                                                        (buffer-substring-no-properties
                                                         vs ve)))))))
                                            (error nil))))
                                    (push (cons name (cons tag value))
                                          result)))))))
                        (goto-char entry-end))
                    (error (goto-char list-end)))))
              result)))))))


;;;; Dispatcher

(defun let-completion--extract-bindings-at (pos completion-pos)
  "Extract bindings from form at POS using registry descriptor.
POS is the opening paren of the form.  COMPLETION-POS is point.
Look up the head symbol in the registry, then dispatch to the
appropriate shape extractor.

If the descriptor contains an `:extractor' key, call that function
with (POS COMPLETION-POS TAG) where TAG is resolved from
`let-completion-tag-alist' first, then the `:tag' key.
Otherwise dispatch via `let-completion--extract-by-spec'.

Return alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL) or nil.

Called by `let-completion--binding-values'."
  (save-excursion
    (goto-char (1+ pos))
    (skip-chars-forward " \t\n")
    ;; -- Navigate: read head symbol.
    (let* ((head-start (point))
           (head-end (ignore-errors (scan-sexps (point) 1))))
      (when head-end
        ;; -- Navigate: look up registry descriptor.
        (let* ((head-str (buffer-substring-no-properties
                          head-start head-end))
               (head-sym (intern-soft head-str))
               (spec (when head-sym
                       (let-completion--lookup-spec head-sym))))
          (when spec
            ;; -- Resolve: tag override from defcustom alist.
            (let ((tag (or (alist-get head-sym let-completion-tag-alist)
                           (plist-get spec :tag))))
              ;; -- Dispatch: extractor function or standard plist.
              (let ((extractor (plist-get spec :extractor)))
                (if extractor
                    (funcall extractor pos completion-pos tag)
                  (let-completion--extract-by-spec
                   pos completion-pos head-end
                   (plist-put (copy-sequence spec) :tag tag)))))))))))

(defun let-completion--extract-by-spec (pos completion-pos head-end spec)
  "Extract bindings from form at POS according to SPEC.
HEAD-END is position after the head symbol.
COMPLETION-POS is where point is.
SPEC is the registry descriptor plist.

Navigate to the sexp at `:bindings-index', check `:scope' against
COMPLETION-POS, dispatch on `:binding-shape' with `:tag' as
the base tag string.

Return alist of (NAME-STRING TAG-STRING . VALUE-OR-NIL) or nil.

Called by `let-completion--extract-bindings-at'."
  (save-excursion
    (goto-char head-end)
    (let ((idx (plist-get spec :bindings-index))
          (shape (plist-get spec :binding-shape))
          (scope (plist-get spec :scope))
          (tag (plist-get spec :tag)))
      ;; Navigate forward to the binding sexp.
      ;; idx 1 means the next sexp after head, idx 2 means skip one more.
      (condition-case nil
          (dotimes (_ (1- idx))
            (skip-chars-forward " \t\n")
            (forward-sexp 1))
        (scan-error nil))
      (skip-chars-forward " \t\n")
      (let ((bindings-start (point))
            (bindings-end (ignore-errors (scan-sexps (point) 1))))
        (when (and bindings-end
                   (let-completion--scope-visible-p
                    pos bindings-end completion-pos scope))
          (let-completion--extract-shape
           shape bindings-start bindings-end completion-pos tag))))))

;;;; Top-Level Binding Walker

(defun let-completion--binding-values ()
  "Return alist of (NAME-STRING . RAW-SEXP) for enclosing bindings.
Walk enclosing paren positions from `syntax-ppss', look up each
form's head symbol in the binding form registry, and extract
bindings via the registered descriptor.

Innermost binding for a given name appears first so `assoc'
finds the correct shadowing.

Called by `let-completion--advice'."
  (let ((completion-pos (point))
        result)
    (dolist (pos (nth 9 (syntax-ppss)))
      (let ((bindings
             (let-completion--extract-bindings-at pos completion-pos)))
        (dolist (b bindings)
          (push b result))))
    result))

;;;; Doc Buffer

(defvar let-completion--doc-buffer nil
  "Reusable buffer for pretty-printed binding values.
Created on first use by the function `let-completion--doc-buffer'.
Consumed by corfu-popupinfo via `:company-doc-buffer'.")

(defun let-completion--doc-buffer ()
  "Return reusable doc buffer with `emacs-lisp-mode' initialized.
The buffer is created once and reused across calls.  Mode setup
runs via function `delay-mode-hooks' to avoid triggering user hooks.

Called by `let-completion--advice' for `:company-doc-buffer'."
  (or (and (buffer-live-p let-completion--doc-buffer)
           let-completion--doc-buffer)
      (setq let-completion--doc-buffer
            (with-current-buffer (get-buffer-create " *let-completion-doc*")
              (delay-mode-hooks (emacs-lisp-mode))
              (current-buffer)))))

;;;; Completion Table Wrapper

(defun let-completion--make-table (table sort-fn local-names)
  "Wrap TABLE to inject LOCAL-NAMES and SORT-FN into completion.
Merge LOCAL-NAMES into all completion actions so candidates found
by the parser but missed by `elisp--local-variables' appear in
results.  Inject `display-sort-function' into the metadata
response via SORT-FN.  Pass `boundaries' actions through unchanged.

Called by `let-completion--advice'."
  (lambda (string pred action)
    (cond
     ((eq action 'metadata)
      (let ((md (if (functionp table)
                    (funcall table string pred 'metadata)
                  '(metadata))))
        `(metadata (display-sort-function . ,sort-fn)
          ,@(assq-delete-all
             'display-sort-function
             (cdr md)))))
     ((eq (car-safe action) 'boundaries)
      (complete-with-action action table string pred))
     (t
      (let ((local-table (lambda (str _pred _flag)
                           (all-completions str local-names))))
        (complete-with-action action
                              (completion-table-merge table local-table)
                              string pred))))))

;;;; Advice

(defun let-completion--advice (orig-fn)
  "Enrich the capf result from ORIG-FN with let-binding metadata.
Wrap the completion table to merge extracted local names into the
candidate pool and inject `display-sort-function' into the table's
metadata response, promoting locals to the top.  Inject
`:annotation-function' to show tags and values per
`let-completion-annotation-format', `let-completion-annotation-format-tag',
and `let-completion-annotation-fallback'.  Inject `:company-doc-buffer'
to provide full pretty-printed values.  Both fall back to the
original plist functions for non-local candidates.

Installed as `:around' advice on `elisp-completion-at-point' by
`let-completion-mode'.  Removed by disabling the mode."
  (let ((result (funcall orig-fn)))
    (when (and result (listp result) (>= (length result) 3))
      (let* ((vals (let-completion--binding-values))
             (local-names (mapcar #'car vals)))
        (when vals
          (let* ((plist (nthcdr 3 result))
                 (orig-ann (plist-get plist :annotation-function))
                 (orig-doc (plist-get plist :company-doc-buffer))
                 (sort-fn (lambda (cands)
                            (let ((seen (make-hash-table :test #'equal))
                                  local other)
                              (dolist (c cands)
                                (unless (gethash c seen)
                                  (puthash c t seen)
                                  (if (member c local-names)
                                      (push c local)
                                    (push c other))))
                              (nconc (nreverse local) (nreverse other))))))
            (setq result
                  (append
                   (list (nth 0 result) (nth 1 result)
                         (let-completion--make-table (nth 2 result) sort-fn local-names)
                         :annotation-function
                         (lambda (c)
                           (let ((cell (assoc c vals)))
                             (if cell
                                 (let* ((tag (cadr cell))
                                        (val (cddr cell))
                                        ;; 1. Alist refinement.
                                        (tag (or (cdr (assoc (cons tag (car-safe val))
                                                             let-completion-tag-refine-alist))
                                                 tag))
                                        ;; 2. Function refinement.
                                        (tag (if let-completion-tag-refine-function
                                                 (or (funcall let-completion-tag-refine-function
                                                              c tag val)
                                                     tag)
                                               tag))
                                        (short
                                         (and let-completion-inline-max-width
                                              val
                                              (let ((s (prin1-to-string val)))
                                                (and (<= (length s)
                                                         let-completion-inline-max-width)
                                                     s))))
                                        (tag-str
                                         (and let-completion-annotation-format-tag
                                              tag
                                              (format
                                               let-completion-annotation-format-tag
                                               tag))))
                                   (cond
                                    ((and tag-str short)
                                     (concat tag-str
                                             (format
                                              let-completion-annotation-format
                                              short)))
                                    (tag-str tag-str)
                                    (short
                                     (format let-completion-annotation-format
                                             short))
                                    (t
                                     (format let-completion-annotation-format
                                             let-completion-annotation-fallback))))
                               (when orig-ann (funcall orig-ann c)))))
                         :company-doc-buffer
                         (lambda (c)
                           (let ((cell (assoc c vals)))
                             (if cell
                                 (let* ((val (cddr cell))
                                        (buf (let-completion--doc-buffer)))
                                   (with-current-buffer buf
                                     (let ((inhibit-read-only t)
                                           (print-level nil)
                                           (print-length nil))
                                       (erase-buffer)
                                       (when val
                                         (let* ((oneline (prin1-to-string val))
                                                (text (if (> (length oneline) fill-column)
                                                          (pp-to-string val)
                                                        oneline)))
                                           (insert text)))
                                       (font-lock-ensure)))
                                   buf)
                               (when orig-doc (funcall orig-doc c))))))
                   (cl-loop for (k v) on plist by #'cddr
                            unless (memq k '(:annotation-function
                                             :company-doc-buffer
                                             :display-sort-function))
                            nconc (list k v))))))))
    result))

;;;; Minor Mode

;;;###autoload
(define-minor-mode let-completion-mode
  "Enrich Elisp completion with let-binding values.
When enabled, install `let-completion--advice' around
`elisp-completion-at-point'.  When disabled, remove it.

Also see `let-completion-inline-max-width'."
  :lighter nil
  :group 'let-completion
  (if let-completion-mode
      (advice-add 'elisp-completion-at-point :around
                  #'let-completion--advice)
    (advice-remove 'elisp-completion-at-point #'let-completion--advice)))

(provide 'let-completion)
;;; let-completion.el ends here
