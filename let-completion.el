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
;; are promoted to the top of the candidate list and annotated
;; with a two-column display: a detail column showing the binding
;; value (or kind hint or enclosing function context) and a tag
;; column showing the provenance of the binding (e.g. "let",
;; "arg", "iter").  Full pretty-printed fontified expressions
;; appear in corfu-popupinfo or any completion UI that reads
;; `:company-doc-buffer'.
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
;; Customize `let-completion-inline-max-width' to control the
;; threshold for inline value display.  Customize
;; `let-completion-tag-kind-alist' to map value heads to kind
;; strings.  Customize `let-completion-detail-functions' for full
;; control over the detail column content.
;;; Code:

(require 'cl-lib)


;;;; Faces

(defface let-completion-tag '((t :inherit font-lock-keyword-face
       :weight normal
       :slant italic))
  "Face for provenance tag annotations (right column).
Applied to the formatted tag string.  Overridden on a per-tag
basis by `let-completion-tag-face-alist'."
  :group 'let-completion)

(defface let-completion-value '((t :inherit font-lock-string-face
       :weight normal
       :slant normal))
  "Face for inline value annotations in the detail column.
Applied when the detail column shows a short printed value."
  :group 'let-completion)

(defface let-completion-kind '((t :inherit font-lock-function-name-face
       :weight normal
       :slant normal))
  "Face for kind suffix annotations in the detail column.
Applied when the detail column shows a kind string from
`let-completion-tag-kind-alist'."
  :group 'let-completion)

(defface let-completion-detail '((t :inherit completions-annotations))
  "Base face for the detail column (middle column).
Serves as the default for `let-completion-context-face'.
Users may also inherit from this face when defining custom
faces for `let-completion-detail-functions' return values."
  :group 'let-completion)

;;;; Customization

(defgroup let-completion nil
  "Show let-binding values in Elisp completion."
  :group 'lisp
  :prefix "let-completion-")

(defcustom let-completion-annotation-format "%s"
  "Format string for inline value annotation.
Receives one string argument: the printed binding value or the
fallback label from `let-completion-annotation-fallback'.

Also see `let-completion-annotation-format-tag' and
`let-completion-inline-max-width'."
  :type 'string)

(defcustom let-completion-annotation-format-tag " %s"
  "Format string for tag annotation (right column).
Receives one string argument: the provenance tag label
\(e.g. \"&optional\", \"fn\", \"let\").

Set to nil to disable tag annotations entirely.

Also see `let-completion-annotation-format'."
  :type '(choice string (const :tag "Disable" nil)))

(defcustom let-completion-annotation-fallback "local"
  "Label shown when binding value is absent or too wide to display.
Used when `let-completion-inline-max-width' is exceeded or value
is nil, and tag annotations are disabled.

Also see `let-completion-annotation-format' and
`let-completion-annotation-format-tag'."
  :type 'string)

(defcustom let-completion-tag-context-format "%s"
  "Format string for context in the detail column.
Receives one string argument: the context string (e.g. the
enclosing function name).  Applied when the detail column shows
context as the lowest-priority fallback.

When nil, context is never shown in the detail column.  Context
is still available to `let-completion-detail-functions' and
`let-completion-tag-refine-functions' via their CONTEXT argument.

Also see `let-completion-context-max-width' and
`let-completion-context-face'."
  :type '(choice string (const :tag "Disable" nil))
  :group 'let-completion)

(defcustom let-completion-inline-max-width 12
  "Max printed width for inline value annotation, or nil to disable.
Only binding values whose `prin1-to-string' form fits within this
many characters appear inline next to the candidate.  Longer values
fall back to the kind string from `let-completion-tag-kind-alist'
or the context string.  The popupinfo buffer always shows the
full value regardless of this setting.

Also see `let-completion-detail-functions'."
  :type '(choice natnum (const :tag "Disable" nil)))

(defcustom let-completion-context-max-width 10
  "Max width for context string in the detail column, or nil to disable.
When the context string exceeds this width, it is truncated from
the left, preserving the rightmost characters and prepending an
ellipsis.

Elisp function names follow the convention PACKAGE-VERB-NOUN,
so left truncation preserves the most meaningful portion.

Example: \"really-long-prefix-erases-buffer\" truncated to 10
becomes \"…es-buffer\".

Set to nil to disable truncation.

Also see `let-completion-tag-context-format'."
  :type '(choice natnum (const :tag "Disable" nil))
  :group 'let-completion)

(defcustom let-completion-tag-refine-alist nil
  "Alist mapping (HEAD-SYMBOL . VALUE-HEAD) to replacement tag strings.
Each key is a cons of (SYMBOL . SYMBOL-OR-NIL) where the car is
the binding form head symbol (e.g. `let*', `defun') and the cdr
is the `car-safe' of the binding value.  When a binding's head
symbol and value head match a key, the associated string replaces
the provenance tag in the right column.

Consulted after `let-completion-tag-alist' and before
`let-completion-tag-refine-functions'.  First match wins.

Example:

    \\='(((let* . lambda) . \"l*λ\")
      ((defun . nil)   . \"fn\"))

Also see `let-completion-tag-refine-functions' and
`let-completion-detail-functions'."
  :type '(alist :key-type (cons symbol symbol)
                :value-type string))

(defcustom let-completion-tag-alist nil
  "Alist mapping binding form symbols to replacement tag strings.
Each entry is (SYMBOL . TAG-STRING).  When a binding form's head
symbol matches SYMBOL, TAG-STRING replaces the tag from the
registry descriptor before any refinement via
`let-completion-tag-refine-alist' or
`let-completion-tag-refine-functions'.

Example:

    \\='((cond-let--and-let* . \"clet\")
      (dolist . \"each\")
      (condition-case . \"rescue\"))"
  :type '(alist :key-type symbol :value-type string))

(defcustom let-completion-tag-kind-alist nil
  "Alist mapping value heads to kind strings for the detail column.
Each entry is (VALUE-HEAD . KIND-STRING) where VALUE-HEAD is the
`car-safe' of the binding value sexp.  When a binding's value
head matches, KIND-STRING appears in the detail column as a type
hint.

Consulted only when `let-completion-detail-functions' returns nil
and the binding value is absent or too wide for inline display
per `let-completion-inline-max-width'.

Example:

    \\='((lambda         . \"λ\")
      (function        . \"𝘧\")
      (make-hash-table . \"#s\")
      (quote           . \"\\='\"))

Also see `let-completion-detail-functions'."
  :type '(alist :key-type symbol :value-type string)
  :group 'let-completion)

(defcustom let-completion-tag-refine-functions nil
  "List of functions to refine provenance tag strings (right column).
Each function receives four arguments: NAME (string), TAG
\(string), VALUE (the raw sexp or nil), and CONTEXT (string or
nil, the enclosing function name).  Return a replacement tag
string, or nil to pass unchanged to the next function.

Functions that accept only three arguments are called with three
arguments via fallback when four-argument invocation signals
`wrong-number-of-arguments'.

Functions run in order.  Each receives the tag as modified by all
previous functions.  The final tag is used for the right column.

This list runs after `let-completion-tag-refine-alist' is
consulted.

Also see `let-completion-tag-refine-alist' and
`let-completion-detail-functions'."
  :type '(repeat function))

(defcustom let-completion-detail-functions nil
  "List of functions to compute detail column content.
Each function receives four arguments: NAME (string), VALUE (the
raw sexp or nil), TAG (the resolved provenance tag string), and
CONTEXT (string or nil, the enclosing function name).

Return a string to use as the detail column content, bypassing
the default value > kind > context priority cascade.  The string
may carry text properties including face.  Return nil to pass to
the next function.

Functions run in order.  First non-nil result wins.  If all
return nil, the default cascade applies:

  1. Short printed value (within `let-completion-inline-max-width')
  2. Kind string from `let-completion-tag-kind-alist'
  3. Context string (when multiple function scopes are visible)

Example that shows Greek letters for lambdas by first parameter:

    (lambda (_name value _tag _context)
      (when (eq (car-safe value) \\='lambda)
        (pcase (car-safe (cadr value))
          (\\='item   \"ƛ∷α\")
          (\\='window \"ƛ∷ϐ\")
          (_        \"ƛ\"))))

Also see `let-completion-tag-kind-alist',
`let-completion-tag-refine-functions', and
`let-completion-inline-max-width'."
  :type '(repeat function)
  :group 'let-completion)

;;;; Customization - Faces

(defcustom let-completion-tag-face 'let-completion-tag
  "Default face for tag annotations.
Applied to the formatted tag string produced by
`let-completion-annotation-format-tag'.  When nil, no face is
applied and the tag inherits whatever face the completion UI
assigns.

Overridden on a per-tag basis by `let-completion-tag-face-alist'.

Also see `let-completion-value-face'."
  :type '(choice face (const :tag "Disable" nil)))

(defcustom let-completion-tag-face-alist nil
  "Alist mapping tag strings to faces.
Each entry is (TAG-STRING . FACE).  TAG-STRING is matched against
the final tag after all refinement stages
\(`let-completion-tag-alist', `let-completion-tag-refine-alist',
`let-completion-tag-refine-functions').

When a tag matches an entry, the associated face is used instead
of `let-completion-tag-face'.  First match wins.

Example:

    \\='((\"let\" . bold)
      (\"err\" . warning)
      (\"arg\" . italic))

Also see `let-completion-tag-face'."
  :type '(alist :key-type string :value-type face))

(defcustom let-completion-value-face 'let-completion-value
  "Face for inline value annotations.
Applied to the formatted value string when displayed inline next
to the candidate.  When nil, no face is applied.

Also see `let-completion-tag-face'."
  :type '(choice face (const :tag "Disable" nil)))

(defcustom let-completion-kind-face 'let-completion-kind
  "Face for kind strings in the detail column.
Applied when the detail column shows a kind string from
`let-completion-tag-kind-alist'.  When nil, no face is applied.

Also see `let-completion-tag-face' and
`let-completion-value-face'."
  :type '(choice face (const :tag "Inherit tag face" nil))
  :group 'let-completion)

(defcustom let-completion-context-face 'let-completion-detail
  "Face for the context string in the detail column.
Applied when the detail column shows the enclosing function name.
When nil, no face is applied.

Also see `let-completion-context-max-width'."
  :type '(choice face (const :tag "Disable" nil))
  :group 'let-completion)

;;;; Binding Form Registry

(defvar-local let-completion-binding-forms nil
  "Buffer-local alist overriding binding form descriptors.
Each entry is (SYMBOL . SPEC) where SPEC is a plist or function.
Takes priority over symbol properties at lookup time.

Set by major mode hooks for non-Elisp Lisp dialects.")

(defun let-completion-register-binding-form (symbol spec)
  "Register SYMBOL as a binding form with descriptor SPEC.

SPEC is a plist describing how to extract variable bindings from
a form headed by SYMBOL.  Two descriptor styles are supported:

Standard descriptor plist keys:

  `:bindings-index': 1-based position of the binding sexp after
    the head symbol.  For `let' this is 1; for `defun' this is 2
    (the arglist follows the function name).

  `:binding-shape': one of `list', `arglist', `single',
    `error-var'.  Controls which shape extractor walks the binding
    sexp.

  `:scope': one of `body', `then', `handlers'.  Controls which
    subsequent forms see the bindings.

  `:tag': string label for the provenance tag column
    (e.g. \"let\", \"arg\", \"iter\", \"err\").

Custom extractor plist keys:

  `:extractor': function receiving (POS COMPLETION-POS TAG).
    Must return a list of entries, each either (NAME TAG VALUE) or
    (NAME TAG VALUE CONTEXT).

  `:tag': string label passed as the TAG argument to the
    extractor.

Store SPEC as symbol property `let-completion--binding-form' on
SYMBOL.  Buffer-local overrides via `let-completion-binding-forms'
take priority at lookup time.

Called at load time for built-in forms.  Third-party macros call
this to opt in.

Also see `let-completion--lookup-spec' and
`let-completion--extract-bindings-at'."
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
  '(:bindings-index 1 :binding-shape list :scope body :tag "sym"))
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
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "gen"))
(let-completion-register-binding-form 'cl-once-only
  '(:bindings-index 1 :binding-shape arglist :scope body :tag "gen"))

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
(let-completion-register-binding-form 'iter-defun
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))
(let-completion-register-binding-form 'cl-iter-defun
  '(:bindings-index 2 :binding-shape arglist :scope body :tag "arg"))

;;;;;; single shape: (VAR EXPR) one binding

(let-completion-register-binding-form 'dolist
  '(:bindings-index 1 :binding-shape single :scope body :tag "iter"))
(let-completion-register-binding-form 'dotimes
  '(:bindings-index 1 :binding-shape single :scope body :tag "iter"))
(let-completion-register-binding-form 'cl-do-symbols
  '(:bindings-index 1 :binding-shape single :scope body :tag "iter"))
(let-completion-register-binding-form 'cl-do-all-symbols
  '(:bindings-index 1 :binding-shape single :scope body :tag "iter"))
(let-completion-register-binding-form 'dolist-with-progress-reporter
  '(:bindings-index 1 :binding-shape single :scope body :tag "iter"))
(let-completion-register-binding-form 'dotimes-with-progress-reporter
  '(:bindings-index 1 :binding-shape single :scope body :tag "iter"))

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
(let-completion-register-binding-form 'cl-flet*
  '(:extractor let-completion--extract-flet :tag "fn*"))
(let-completion-register-binding-form 'cl-labels
  '(:extractor let-completion--extract-flet :tag "fn**"))
(let-completion-register-binding-form 'cl-macrolet
  '(:extractor let-completion--extract-flet :tag "mac"))
(let-completion-register-binding-form 'cl-letf
  '(:extractor let-completion--extract-letf :tag "place"))
(let-completion-register-binding-form 'cl-letf*
  '(:extractor let-completion--extract-letf :tag "place*"))
(let-completion-register-binding-form 'cl-defmethod
  '(:extractor let-completion--extract-defmethod :tag "arg"))


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
            (forward-comment (buffer-size))
            (let ((then-end (ignore-errors (scan-sexps (point) 1))))
              (or (null then-end)
                  (<= completion-pos then-end))))))
    ('handlers
     (save-excursion
       (goto-char bindings-end)
       (forward-comment (buffer-size))
       ;; Skip the protected expression.
       (let ((protected-end (ignore-errors (scan-sexps (point) 1))))
         (and protected-end
              (> completion-pos protected-end)))))
    (_ t)))

;;;; Shape Extractor Utilities
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

(defun let-completion--collect-cl-compound (start end completion-pos current-tag result)
  "Collect bindings from a CL compound arglist spec between START and END.
Walk inner elements of a compound spec like (VAR DEFAULT SVAR).
Bare symbols passing `let-completion--arglist-non-binding-p' are
collected.  Quoted forms and strings are skipped.  Nested lists in
`&key' context are entered via the local helper `collect-key-var'
to extract ((:KEYWORD VAR) ...) specs.

COMPLETION-POS is point.  CURRENT-TAG is the active tag string.
RESULT is the accumulator list, modified destructively via `push'.

Return the updated RESULT.

Called by `let-completion--extract-shape-arglist' and
`let-completion--extract-defmethod'."
  (save-excursion
    (goto-char (1+ start))
    (cl-flet
        ;; Extract VAR from a nested &key spec like ((:KEYWORD VAR) DEFAULT).
        ;; Enter the inner list, skip the keyword element, take the second
        ;; element as variable name.  Return updated RESULT.
        ((collect-key-var (inner-start inner-end)
           (save-excursion
             (goto-char (1+ inner-start))
             ;; Navigate: skip keyword element.
             (forward-comment (buffer-size))
             (ignore-errors (forward-sexp 1))
             ;; Navigate: now at VAR position.
             (forward-comment (buffer-size))
             (when (< (point) (1- inner-end))
               (let* ((var-start (point))
                      (var-end (ignore-errors
                                 (scan-sexps (point) 1))))
                 (when (and var-end
                            (not (eq (char-after var-start) ?\()))
                   (let ((vname (buffer-substring-no-properties
                                 var-start var-end)))
                     (unless (let-completion--arglist-non-binding-p
                              vname)
                       (push (list vname current-tag nil)
                             result)))))))
           result))
      (while (progn (forward-comment (buffer-size))
                    (< (point) (1- end)))
        (let ((inner-start (point)))
          (condition-case nil
              (let ((inner-end (scan-sexps (point) 1)))
                (unless (<= inner-start completion-pos inner-end)
                  (cond
                   ;; Entry: inner list in &key context is
                   ;; ((:KEYWORD VAR) ...).  Enter and take second
                   ;; element as variable name.
                   ((eq (char-after inner-start) ?\()
                    (when (string= current-tag "&key")
                      (setq result (collect-key-var inner-start
                                                    inner-end))))
                   ;; Entry: quoted form or string -- skip.
                   ((memq (char-after inner-start) '(?' ?\"))
                    nil)
                   ;; Entry: bare symbol -- collect if it passes the
                   ;; non-binding filter.
                   (t
                    (let ((name (buffer-substring-no-properties
                                 inner-start inner-end)))
                      (unless (let-completion--arglist-non-binding-p name)
                        (push (list name current-tag nil)
                              result))))))
                (goto-char inner-end))
            (error (goto-char end)))))))
  result)

;;;; Shape Extractors

(defun let-completion--extract-shape (shape start end completion-pos tag)
  "Dispatch extraction on SHAPE between START and END.
COMPLETION-POS is used to skip bindings that contain point.
TAG is the base tag string from the registry descriptor.
SHAPE is one of `list', `arglist', `single', `error-var'.

Return list of (NAME TAG VALUE) entries.

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

Compound entries are processed by the local helper `extract-compound',
which extracts the name via `scan-sexps' and the value via
`read-from-string' with silent fallback to nil.

Return alist of (NAME-STRING TAG-STRING VALUE-OR-NIL) lists.

Used for `let', `let*', `when-let*', `if-let*', `and-let*', `dlet'.
Called by `let-completion--extract-shape'."
  (save-excursion
    (goto-char (1+ start))
    (let (result)
      (cl-flet
          ;; Extract name and value from a compound binding (VAR EXPR)
          ;; between B-START and B-END.  Return (NAME TAG VALUE) or nil.
          ((extract-compound (b-start b-end)
             (save-excursion
               (goto-char (1+ b-start))
               (forward-comment (buffer-size))
               (let ((name-start (point))
                     (name-end (ignore-errors (scan-sexps (point) 1))))
                 (when name-end
                   (let ((name (buffer-substring-no-properties
                                name-start name-end))
                         (value (condition-case nil
                                    (progn
                                      (goto-char name-end)
                                      (forward-comment (buffer-size))
                                      (when (< (point) (1- b-end))
                                        (let ((vs (point))
                                              (ve (scan-sexps (point) 1)))
                                          (when ve
                                            (car (read-from-string
                                                  (buffer-substring-no-properties
                                                   vs ve)))))))
                                  (error nil))))
                     (list name tag value)))))))

        (while (progn (forward-comment (buffer-size))
                      (< (point) (1- end)))
          (let ((b-start (point)))
            (condition-case nil
                (let ((b-end (scan-sexps (point) 1)))
                  (if (<= b-start completion-pos b-end)
                      (goto-char b-end)
                    (cond
                     ;; Entry: (VAR EXPR) -- compound binding.
                     ((eq (char-after b-start) ?\()
                      (when-let* ((binding (extract-compound b-start b-end)))
                        (push binding result)))
                     ;; Entry: bare symbol.
                     (t
                      (push (list (buffer-substring-no-properties
                                   b-start b-end)
                                  tag nil)
                            result)))
                    (goto-char b-end)))
              (error (goto-char end))))))
      result)))

(defun let-completion--extract-shape-arglist (start end completion-pos tag
                                                    &optional specializer-tag
                                                    skip-context)
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

When SPECIALIZER-TAG is non-nil, compound specs where the current
tag equals SPECIALIZER-TAG are treated as specializers: only the
first element is collected as a variable name.  This handles
`cl-defmethod' mandatory parameter specs like (VAR TYPE).

When SKIP-CONTEXT is non-nil, entries after `&context' are skipped
until the next standard lambda-list keyword.  This handles
`cl-defmethod' context specifications.

Return alist of (NAME-STRING TAG-STRING nil) lists.

Used for `defun', `defmacro', `defsubst', `cl-defun', `lambda',
`cl-destructuring-bind', and indirectly by
`let-completion--extract-defmethod'.
Called by `let-completion--extract-shape'."
  (save-excursion
    (goto-char (1+ start))
    (let (result
          (current-tag tag)
          (in-context nil))
      (while (progn (forward-comment (buffer-size))
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
                             (if (and skip-context
                                      (string= name "&context"))
                                 (setq in-context t
                                       current-tag name)
                               (setq in-context nil
                                     current-tag name))
                             t))))
                   ;; Entry: in &context -- skip entirely.
                   (in-context nil)
                   ;; Entry: compound spec in specializer context --
                   ;; take first element only.
                   ((and specializer-tag
                         (eq (char-after sym-start) ?\()
                         (string= current-tag specializer-tag))
                    (save-excursion
                      (goto-char (1+ sym-start))
                      (forward-comment (buffer-size))
                      (when-let* ((var-end (ignore-errors
                                             (scan-sexps (point) 1))))
                        (unless (eq (char-after (point)) ?\()
                          (let ((vname (buffer-substring-no-properties
                                        (point) var-end)))
                            (unless (let-completion--arglist-non-binding-p
                                     vname)
                              (push (list vname current-tag nil)
                                    result)))))))
                   ;; Walk: compound spec -- enter and collect symbols.
                   ((eq (char-after sym-start) ?\()
                    (setq result
                          (let-completion--collect-cl-compound
                           sym-start sym-end completion-pos
                           current-tag result)))
                   ;; Entry: plain parameter name -- collect with current tag.
                   (t
                    (let ((name (buffer-substring-no-properties
                                 sym-start sym-end)))
                      (push (list name current-tag nil) result))))
                  (goto-char sym-end)))
            (error (goto-char end)))))
      result)))

(defun let-completion--extract-shape-single (start end completion-pos tag)
  "Extract one binding from a (VAR EXPR) form between START and END.
TAG is the base tag string from the registry descriptor.
Skip if span contains COMPLETION-POS.

Name is extracted via `scan-sexps'.  Value is attempted via `read'
with silent fallback to nil.

Return one-element alist of (NAME-STRING TAG-STRING VALUE-OR-NIL)
lists or nil.

Used for `dolist', `dotimes'.
Called by `let-completion--extract-shape'."
  (if (<= start completion-pos end)
      nil
    (save-excursion
      (goto-char (1+ start))
      (forward-comment (buffer-size))
      (let ((name-start (point))
            (name-end (ignore-errors (scan-sexps (point) 1))))
        (when name-end
          (let* ((name (buffer-substring-no-properties
                        name-start name-end))
                 (value (condition-case nil
                            (progn
                              (goto-char name-end)
                              (forward-comment (buffer-size))
                              (when (< (point) (1- end))
                                (let* ((vs (point))
                                       (ve (scan-sexps (point) 1)))
                                  (when ve
                                    (car (read-from-string
                                          (buffer-substring-no-properties
                                           vs ve)))))))
                          ;; if read or scan-sexps failed, return nil
                          (error nil))))
            (list (list name tag value))))))))

(defun let-completion--extract-shape-error-var (start end completion-pos tag)
  "Extract one name from a bare symbol between START and END.
TAG is the base tag string from the registry descriptor.
Skip if span contains COMPLETION-POS.

Return one-element alist of (NAME-STRING TAG-STRING nil) lists
or nil.

Used for `condition-case'.
Called by `let-completion--extract-shape'."
  (if (<= start completion-pos end)
      nil
    (let ((name (buffer-substring-no-properties start end)))
      (unless (or (string-empty-p name) (string= name "nil"))
        (list (list name tag nil))))))

;;; Custom Extractor Functions

(cl-defun let-completion--extract-flet (pos completion-pos tag)
  "Extract function names from a flet-like form at POS.
COMPLETION-POS is point.  TAG is the annotation label from the
registry descriptor.

Walk the binding list at index 1.  Each entry has the structure
\(FUNC ARGLIST BODY...).  Extract FUNC as name via `scan-sexps'.
Values are nil.  Scope check requires COMPLETION-POS past the
binding list end.  Skip entries whose span contains COMPLETION-POS.

Return alist of (NAME-STRING TAG-STRING nil) lists or nil.

Used for `cl-flet', `cl-labels', `cl-macrolet'.
Called by `let-completion--extract-bindings-at' via `:extractor'."
  (save-excursion
    (goto-char (1+ pos))
    (forward-comment (buffer-size))
    ;; -- Navigate: skip head symbol.
    (let ((head-end (ignore-errors (scan-sexps (point) 1))))
      (unless head-end (cl-return-from let-completion--extract-flet))
      (goto-char head-end)
      (forward-comment (buffer-size))
      ;; -- Navigate: now at binding list.
      (let ((list-start (point))
            (list-end (ignore-errors (scan-sexps (point) 1))))
        ;; -- Scope: binding list must end before completion-pos.
        (unless (and list-end (> completion-pos list-end))
          (cl-return-from let-completion--extract-flet))
        (goto-char (1+ list-start))
        ;; -- Walk: iterate entries in binding list.
        (let (result)
          (while (progn (forward-comment (buffer-size))
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
                        (forward-comment (buffer-size))
                        ;; -- Entry: extract name (first element).
                        (when-let* ((name-end (ignore-errors
                                                (scan-sexps (point) 1))))
                          (push (list (buffer-substring-no-properties
                                       (point) name-end)
                                      tag nil)
                                result))))
                    (goto-char entry-end))
                (error (goto-char list-end)))))
          result)))))

(cl-defun let-completion--extract-letf (pos completion-pos tag)
  "Extract symbol-place bindings from a letf-like form at POS.
COMPLETION-POS is point.  TAG is the annotation label from the
registry descriptor.

Walk the binding list at index 1.  Each entry has the structure
\(PLACE VALUE).  Only entries where PLACE is a bare symbol (not a
generalized place like (symbol-function \\='foo)) produce bindings.

Entry processing is split into two local helpers: `extract-entry'
navigates into each binding and filters non-symbol places,
`read-value' parses the value via `read-from-string' with silent
fallback to nil.

Return alist of (NAME-STRING TAG-STRING VALUE-OR-NIL) lists or nil.

Used for `cl-letf', `cl-letf*'.
Called by `let-completion--extract-bindings-at' via `:extractor'."
  (save-excursion
    (goto-char (1+ pos))
    (forward-comment (buffer-size))
    ;; -- Navigate: skip head symbol.
    (let ((head-end (ignore-errors (scan-sexps (point) 1))))
      (unless head-end (cl-return-from let-completion--extract-letf))
      (goto-char head-end)
      (forward-comment (buffer-size))
      ;; -- Navigate: now at binding list.
      (let ((list-start (point))
            (list-end (ignore-errors (scan-sexps (point) 1))))
        ;; -- Scope: binding list must end before completion-pos.
        (unless (and list-end (> completion-pos list-end))
          (cl-return-from let-completion--extract-letf))
        (goto-char (1+ list-start))
        ;; -- Walk: iterate entries in binding list.
        (let (result)
          (cl-labels
              ;; Read value sexp after PLACE-END, before ENTRY-END.
              ;; Return parsed value or nil on any failure.
              ((read-value (place-end entry-end)
                 (condition-case nil
                     (progn
                       (goto-char place-end)
                       (forward-comment (buffer-size))
                       (when (< (point) (1- entry-end))
                         (when-let* ((ve (scan-sexps (point) 1)))
                           (car (read-from-string
                                 (buffer-substring-no-properties
                                  (point) ve))))))
                   (error nil)))

               ;; Extract one binding from entry between ENTRY-START
               ;; and ENTRY-END.  Return (NAME TAG VALUE) or nil.
               (extract-entry (entry-start entry-end)
                 (save-excursion
                   (goto-char (1+ entry-start))
                   (forward-comment (buffer-size))
                   (let ((place-start (point))
                         (place-end (ignore-errors
                                      (scan-sexps (point) 1))))
                     ;; -- Entry: only bare symbols, skip generalized
                     ;;    places like (symbol-function 'foo).
                     (when (and place-end
                                (not (eq (char-after place-start) ?\()))
                       (list (buffer-substring-no-properties
                              place-start place-end)
                             tag
                             (read-value place-end entry-end)))))))
            (while (progn (forward-comment (buffer-size))
                          (< (point) (1- list-end)))
              (let ((entry-start (point)))
                (condition-case nil
                    (let ((entry-end (scan-sexps (point) 1)))
                      ;; -- Entry: process if list and not at point.
                      (when (and (eq (char-after entry-start) ?\()
                                 (not (<= entry-start
                                          completion-pos entry-end)))
                        (when-let* ((binding (extract-entry entry-start
                                                            entry-end)))
                          (push binding result)))
                      (goto-char entry-end))
                  (error (goto-char list-end))))))
          result)))))

(cl-defun let-completion--extract-defmethod (pos completion-pos tag)
  "Extract parameter names from a `cl-defmethod' form at POS.
COMPLETION-POS is point.  TAG is the annotation label from the
registry descriptor.

Navigate past the head symbol and method name.  Capture the
method name as context string.  Skip qualifier keywords
\(`:before', `:after', `:around') and `:extra STRING' pairs to
find the arglist.  Delegate the arglist walk to
`let-completion--extract-shape-arglist' with SPECIALIZER-TAG and
SKIP-CONTEXT enabled.

Return alist of (NAME-STRING TAG-STRING nil CONTEXT-OR-NIL) lists
or nil.

Used for `cl-defmethod'.
Called by `let-completion--extract-bindings-at' via `:extractor'."
  (save-excursion
    (goto-char (1+ pos))
    (forward-comment (buffer-size))
    ;; -- Navigate: skip head symbol (cl-defmethod).
    (let ((head-end (ignore-errors (scan-sexps (point) 1))))
      (unless head-end (cl-return-from let-completion--extract-defmethod))
      (goto-char head-end)
      (forward-comment (buffer-size))
      ;; -- Navigate: read method name as context.
      (let* ((name-start (point))
             (name-end (ignore-errors (scan-sexps (point) 1)))
             (context (when name-end
                        (buffer-substring-no-properties
                         name-start name-end))))
        (unless name-end (cl-return-from let-completion--extract-defmethod))
        (goto-char name-end)
        (forward-comment (buffer-size))
        ;; -- Navigate: skip qualifiers and :extra STRING pairs.
        (while (and (not (eq (char-after) ?\())
                    (< (point) (point-max)))
          (let ((q-start (point))
                (q-end (ignore-errors (scan-sexps (point) 1))))
            (unless q-end (cl-return-from let-completion--extract-defmethod))
            (when (string= (buffer-substring-no-properties q-start q-end)
                           ":extra")
              ;; -- Navigate: :extra consumes the next sexp too.
              (goto-char q-end)
              (forward-comment (buffer-size))
              (setq q-end (ignore-errors (scan-sexps (point) 1)))
              (unless q-end
                (cl-return-from let-completion--extract-defmethod)))
            (goto-char q-end)
            (forward-comment (buffer-size))))
        ;; -- Navigate: now at the arglist.
        (let ((arglist-start (point))
              (arglist-end (ignore-errors (scan-sexps (point) 1))))
          (unless (and arglist-end
                       (eq (char-after arglist-start) ?\()
                       (> completion-pos arglist-end))
            (cl-return-from let-completion--extract-defmethod))
          ;; -- Walk: delegate to arglist extractor with defmethod rules.
          (let ((bindings (let-completion--extract-shape-arglist
                           arglist-start arglist-end completion-pos
                           tag tag t)))
            ;; -- Attach: inject context into each entry.
            ;; Arglist extractor returns (NAME TAG nil).
            ;; Convert to (NAME TAG nil CONTEXT).
            (if context
                (mapcar (lambda (entry)
                          (append entry (list context)))
                        bindings)
              bindings)))))))

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

Each returned entry has the structure
\(NAME HEAD-SYM TAG VALUE) or (NAME HEAD-SYM TAG VALUE CONTEXT).
HEAD-SYM is injected by this function; extractors return entries
without it.

Called by `let-completion--binding-values'."
  (save-excursion
    (goto-char (1+ pos))
    (forward-comment (buffer-size))
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
              (let* ((extractor (plist-get spec :extractor))
                     (bindings (if extractor
                                   (funcall extractor pos completion-pos tag)
                                 (let-completion--extract-by-spec
                                  pos completion-pos head-end
                                  (plist-put (copy-sequence spec) :tag tag)))))
                ;; -- Attach: inject head-sym into each entry.
                ;; Extractor returns (NAME TAG VALUE ...).
                ;; Convert to (NAME HEAD-SYM TAG VALUE ...).
                (mapcar (lambda (entry)
                          (cons (car entry)
                                (cons head-sym (cdr entry))))
                        bindings)))))))))

(defun let-completion--extract-by-spec (pos completion-pos head-end spec)
  "Extract bindings from form at POS according to SPEC.
HEAD-END is position after the head symbol.
COMPLETION-POS is where point is.
SPEC is the registry descriptor plist.

Navigate to the sexp at `:bindings-index', check `:scope' against
COMPLETION-POS, dispatch on `:binding-shape' with `:tag' as
the base tag string.

For arglist shapes, capture a context string identifying the
enclosing function.  For bindings-index > 1, context is the
function name at index 1.  For `lambda' at index 1, context
is \"λ\".

Return list of entries.  Each entry is (NAME TAG VALUE) or
\(NAME TAG VALUE CONTEXT) when context is available.

Called by `let-completion--extract-bindings-at'."
  (save-excursion
    (goto-char head-end)
    (let ((idx (plist-get spec :bindings-index))
          (shape (plist-get spec :binding-shape))
          (scope (plist-get spec :scope))
          (tag (plist-get spec :tag))
          (context nil))
      ;; -- Context: capture function name for arglist shapes.
      (when (eq shape 'arglist)
        (if (> idx 1)
            ;; Function name is the first sexp after head symbol.
            (save-excursion
              (forward-comment (buffer-size))
              (let ((s (point))
                    (e (ignore-errors (scan-sexps (point) 1))))
                (when e
                  (setq context (buffer-substring-no-properties s e)))))
          ;; Index 1: check if head is lambda.
          (save-excursion
            (goto-char (1+ pos))
            (forward-comment (buffer-size))
            (let ((s (point))
                  (e (ignore-errors (scan-sexps (point) 1))))
              (when (and e (string= (buffer-substring-no-properties s e)
                                    "lambda"))
                (setq context "λ"))))))
      ;; Navigate forward to the binding sexp.
      ;; idx 1 means the next sexp after head, idx 2 means skip one more.
      (condition-case nil
          (dotimes (_ (1- idx))
            (forward-comment (buffer-size))
            (forward-sexp 1))
        (scan-error nil))
      (forward-comment (buffer-size))
      (let ((bindings-start (point))
            (bindings-end (ignore-errors (scan-sexps (point) 1))))
        (when (and bindings-end
                   (let-completion--scope-visible-p
                    pos bindings-end completion-pos scope))
          (let ((bindings (let-completion--extract-shape
                           shape bindings-start bindings-end
                           completion-pos tag)))
            ;; -- Attach: inject context into each entry when present.
            ;; Shape extractors return (NAME TAG VALUE).
            ;; Convert to (NAME TAG VALUE CONTEXT).
            (if context
                (mapcar (lambda (entry)
                          (append entry (list context)))
                        bindings)
              bindings)))))))

;;;; Top-Level Binding Walker

(defun let-completion--binding-values ()
  "Return alist of bindings from enclosing forms.
Walk enclosing paren positions from `syntax-ppss', look up each
form's head symbol in the binding form registry, and extract
bindings via the registered descriptor.

Each entry has the structure
\(NAME HEAD-SYM TAG VALUE CONTEXT) where VALUE and CONTEXT may
be nil.

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
response via SORT-FN.  Retrieve the original sort function from
TABLE and pass it to SORT-FN as context.  Pass `boundaries'
actions through unchanged.

Called by `let-completion--advice'."
  (lambda (string pred action)
    (cond
     ((eq action 'metadata)
      (let* ((md (if (functionp table)
                     (funcall table string pred 'metadata)
                   '(metadata)))
             (orig-sort (cdr (assq 'display-sort-function (cdr md)))))
        `(metadata (display-sort-function
                    . ,(lambda (cands) (funcall sort-fn cands orig-sort)))
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
  "Enrich ORIG-FN capf result with locally bound variable names and values.
ORIG-FN is `elisp-completion-at-point'.

Wrap the returned completion table to merge local names, inject
`display-sort-function' promoting locals above globals, inject
`:annotation-function' for two-column display, and inject
`:company-doc-buffer' for full pretty-printed values.  Both
annotation and doc-buffer fall back to original plist functions
for non-local candidates.

The annotation uses two right-aligned fixed-width columns: a
detail column (middle) showing value, kind, or context, and a
tag column (right) showing the provenance tag.  Column widths
are computed lazily on the first annotation request.

Uses `let-completion--binding-values' to extract bindings.
Uses `let-completion--make-table' to wrap the completion table.
Uses `let-completion--doc-buffer' for the doc display buffer."
  (let ((result (funcall orig-fn)))
    ;; Capf protocol: (START END COLLECTION . PLIST).
    (when (and result (listp result) (>= (length result) 3))
      (let* ((vals (let-completion--binding-values))
             (local-names (mapcar #'car vals)))
        (when vals
          (let* ((plist (nthcdr 3 result))
                 (orig-ann (plist-get plist :annotation-function))
                 (orig-doc (plist-get plist :company-doc-buffer))
                 ;; Column widths, computed lazily on first annotation call.
                 (col-widths nil))
            (cl-labels
                ;; Run refine functions over TAG in sequence.
                ;; Each function receives (NAME TAG VALUE CONTEXT).
                ;; Fall back to three-argument call when the function
                ;; does not accept four arguments.  Return the final
                ;; tag after all functions have run.
                ((run-refine-fns (c tag val ctx)
                   (dolist (fn let-completion-tag-refine-functions tag)
                     (let ((result (condition-case nil
                                       (funcall fn c tag val ctx)
                                     (wrong-number-of-arguments
                                      (funcall fn c tag val)))))
                       (when result (setq tag result)))))

                 ;; Tag pipeline (right column):
                 ;; Stage 1: tag-alist or registry :tag (already resolved).
                 ;; Stage 2: refine alist on (head-sym . value-head).
                 ;; Stage 3: function list refinement.
                 (refine-tag (head-sym tag val c ctx)
                   (let* ((value-head (car-safe val))
                          (refine-key (cons head-sym value-head))
                          (refined (cdr (assoc refine-key
                                               let-completion-tag-refine-alist)))
                          (tag (or refined tag)))
                     (run-refine-fns c tag val ctx)))

                 ;; Resolve face for a provenance tag string.
                 (face-for-tag (tag)
                   (or (cdr (assoc tag let-completion-tag-face-alist))
                       let-completion-tag-face))

                 ;; Format provenance tag for the right column.
                 ;; Return propertized string or nil if tags are disabled.
                 (make-tag (tag)
                   (and let-completion-annotation-format-tag tag
                        (let ((s (format let-completion-annotation-format-tag tag))
                              (face (face-for-tag tag)))
                          (when face
                            (put-text-property 0 (length s) 'face face s))
                          s)))

                 ;; Short printed value string or nil when too wide or absent.
                 (short-value-str (val)
                   (and let-completion-inline-max-width val
                        (let ((s (prin1-to-string val)))
                          (and (<= (length s)
                                   let-completion-inline-max-width)
                               s))))

                 ;; Truncate context string from the left.
                 ;; Preserve rightmost characters, prepend ellipsis.
                 (truncate-context (ctx)
                   (if (and let-completion-context-max-width
                            (> (length ctx) let-completion-context-max-width))
                       (concat "…"
                               (substring ctx
                                          (- (length ctx)
                                             (1- let-completion-context-max-width))))
                     ctx))

                 ;; Resolve the detail column content for one candidate.
                 ;; Returns (STRING . SOURCE) where SOURCE is one of
                 ;; `custom', `value', `kind', `context', or nil when
                 ;; no detail is available.
                 (detail-cell (c val tag ctx show-ctx)
                   (or (when let-completion-detail-functions
                         (when-let* ((s (cl-loop
                                         for fn in let-completion-detail-functions
                                         thereis (funcall fn c val tag ctx))))
                           (cons s 'custom)))
                       (when-let* ((s (short-value-str val)))
                         (cons s 'value))
                       (when-let* ((s (and val
                                          (cdr (assq (car-safe val)
                                                     let-completion-tag-kind-alist)))))
                         (cons s 'kind))
                       (when-let* ((_ show-ctx)
                                   (_ let-completion-tag-context-format)
                                   (_ ctx))
                         (let ((ctx (truncate-context ctx)))
                           (cons (format let-completion-tag-context-format ctx)
                                 'context)))))

                 ;; Apply face to detail string based on source.
                 ;; Strings that already carry face properties are left alone.
                 (face-detail (s source)
                   (if (text-property-not-all 0 (length s) 'face nil s)
                       s
                     (let ((face (pcase source
                                   ('value   let-completion-value-face)
                                   ('kind    let-completion-kind-face)
                                   ('context let-completion-context-face)
                                   (_        nil))))
                       (if face (propertize s 'face face) s))))

                 ;; Compute column widths and context display decision.
                 ;; Returns (MAX-TAG-WIDTH MAX-DETAIL-WIDTH SHOW-CONTEXT-P).
                 (compute-col-widths ()
                   (let ((max-tag 0)
                         (max-detail 0)
                         (contexts nil))
                     ;; Collect distinct contexts to decide display.
                     (dolist (cell vals)
                       (let ((ctx (nth 4 cell)))
                         (when (and ctx (not (member ctx contexts)))
                           (push ctx contexts))))
                     ;; Show context only when multiple distinct contexts exist.
                     (let ((show-ctx (and let-completion-tag-context-format
                                          (cdr contexts))))
                       (dolist (cell vals)
                         (let* ((c (nth 0 cell))
                                (head-sym (nth 1 cell))
                                (tag (nth 2 cell))
                                (val (nth 3 cell))
                                (ctx (nth 4 cell))
                                (tag (refine-tag head-sym tag val c ctx))
                                (tag-str (make-tag tag))
                                (dc (detail-cell c val tag ctx show-ctx))
                                (detail-str (car dc)))
                           (when tag-str
                             (setq max-tag (max max-tag (length tag-str))))
                           (when detail-str
                             (setq max-detail
                                   (max max-detail (length detail-str))))))
                       (list max-tag max-detail show-ctx))))

                 ;; Ensure column widths are computed.
                 (ensure-col-widths ()
                   (or col-widths
                       (setq col-widths (compute-col-widths))))

                 ;; Assemble the two-column annotation string.
                 ;; Detail column is right-aligned, then tag column
                 ;; is right-aligned.  Both use fixed widths.
                 (format-ann (tag-str detail-str)
                   (let* ((widths (ensure-col-widths))
                          (tag-w (nth 0 widths))
                          (detail-w (nth 1 widths)))
                     (cond
                      ;; Both columns present.
                      ((and tag-str detail-str)
                       (concat " "
                               (make-string
                                (max 0 (- detail-w (length detail-str)))
                                ?\s)
                               detail-str
                               " "
                               (make-string
                                (max 0 (- tag-w (length tag-str)))
                                ?\s)
                               tag-str))
                      ;; Tag only.
                      (tag-str
                       (concat " "
                               (make-string detail-w ?\s)
                               " "
                               (make-string
                                (max 0 (- tag-w (length tag-str)))
                                ?\s)
                               tag-str))
                      ;; Detail only.
                      (detail-str
                       (concat " "
                               (make-string
                                (max 0 (- detail-w (length detail-str)))
                                ?\s)
                               detail-str))
                      ;; Neither present: fallback.
                      (t
                       (format let-completion-annotation-format
                               let-completion-annotation-fallback)))))

                 ;; Render full value into reusable doc buffer.
                 ;; Wide values use pp-to-string for readability.
                 ;; Rebind print-level and print-length to nil to
                 ;; deal with corfu-popupinfo truncating bindings.
                 (render-doc (val)
                   (let ((buf (let-completion--doc-buffer)))
                     (with-current-buffer buf
                       (let ((inhibit-read-only t)
                             (print-level nil)
                             (print-length nil))
                         (erase-buffer)
                         (when val
                           (let ((s (prin1-to-string val)))
                             (insert (if (> (length s) fill-column)
                                        (pp-to-string val)
                                      s))))
                         (font-lock-ensure)))
                     buf)))

              (let ((sort-fn
                     ;; Promote locals above the result of the original sort
                     ;; function (or identity when no original exists).
                     ;; Hash deduplicates; completion-table-merge can produce
                     ;; duplicates when a local shadows a global.
                     (lambda (cands orig-sort)
                       (let ((sorted (funcall (or orig-sort #'identity) cands))
                             (seen (make-hash-table :test #'equal))
                             local other)
                         (dolist (c sorted)
                           (unless (gethash c seen)
                             (puthash c t seen)
                             (if (member c local-names)
                                 (push c local)
                               (push c other))))
                         (nconc (nreverse local) (nreverse other)))))

                    (ann-fn
                     (lambda (c)
                       (if-let* ((cell (assoc c vals)))
                           ;; cell: (NAME HEAD-SYM TAG VALUE CONTEXT)
                           (let* ((head-sym (nth 1 cell))
                                  (tag (nth 2 cell))
                                  (val (nth 3 cell))
                                  (ctx (nth 4 cell))
                                  (show-ctx (nth 2 (ensure-col-widths)))
                                  (tag (refine-tag head-sym tag val c ctx))
                                  (tag-str (make-tag tag))
                                  (dc (detail-cell c val tag ctx show-ctx))
                                  (detail-str (when dc
                                                (face-detail (car dc)
                                                             (cdr dc)))))
                             (format-ann tag-str detail-str))
                         (when orig-ann (funcall orig-ann c)))))

                    (doc-fn
                     (lambda (c)
                       (if-let* ((cell (assoc c vals)))
                           ;; cell: (NAME HEAD-SYM TAG VALUE CONTEXT)
                           (render-doc (nth 3 cell))
                         (when orig-doc (funcall orig-doc c))))))

                ;; nconc is safe: both halves are freshly allocated.
                ;; Filter replaced keys from the original plist.
                (setq result
                      (nconc
                       (list (nth 0 result) (nth 1 result)
                             (let-completion--make-table
                              (nth 2 result) sort-fn local-names)
                             :annotation-function ann-fn
                             :company-doc-buffer doc-fn)
                       (cl-loop for (k v) on plist by #'cddr
                                unless (memq k '(:annotation-function
                                                 :company-doc-buffer
                                                 :display-sort-function))
                                nconc (list k v))))))))))
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
