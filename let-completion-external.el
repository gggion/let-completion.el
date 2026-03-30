;;; let-completion-external.el --- Extra binding form registrations -*- lexical-binding: t -*-

;; Author: Gino Cornejo <gggion123@gmail.com>
;; Maintainer: Gino Cornejo <gggion123@gmail.com>
;; URL: https://github.com/gggion/let-completion.el
;; Keywords: lisp, completion

;; This file is part of let-completion.

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

;; Extra binding form registrations for `let-completion-mode'.
;; Registers forms from third-party packages that use standard
;; binding shapes.  Registrations are inert when the registered
;; symbol never appears as a form head in user code.
;;
;; Usage:
;;
;;     (require 'let-completion-external)

;;; Code:

(require 'let-completion)

;;;; cond-let

;; Strict (SYMBOL VALUEFORM) pairs, no bare symbols.
;; The standard `list' shape extractor handles these directly.
;; `cond-let--and$', `cond-let--when$', and `cond-let--and>' bind
;; the fixed name `$' without a user-written symbol and are not
;; registered.  `cond-let*' and `cond-let' use vector clause syntax
;; requiring a custom extractor and are deferred.

;; body scope: bindings visible in all body forms.
(let-completion-register-binding-form 'cond-let--and-let*
  '(:bindings-index 1 :binding-shape list :scope body :tag "cond-and-let*"))
(let-completion-register-binding-form 'cond-let--and-let
  '(:bindings-index 1 :binding-shape list :scope body :tag "cond-and-let"))
(let-completion-register-binding-form 'cond-let--when-let*
  '(:bindings-index 1 :binding-shape list :scope body :tag "cond-when-let*"))
(let-completion-register-binding-form 'cond-let--when-let
  '(:bindings-index 1 :binding-shape list :scope body :tag "cond-when-let"))
(let-completion-register-binding-form 'cond-let--while-let*
  '(:bindings-index 1 :binding-shape list :scope body :tag "cond-while-let*"))
(let-completion-register-binding-form 'cond-let--while-let
  '(:bindings-index 1 :binding-shape list :scope body :tag "cond-while-let"))

;; then scope: bindings visible only in the first form after bindings.
(let-completion-register-binding-form 'cond-let--if-let*
  '(:bindings-index 1 :binding-shape list :scope then :tag "cond-if-let*"))
(let-completion-register-binding-form 'cond-let--if-let
  '(:bindings-index 1 :binding-shape list :scope then :tag "cond-if-let"))

(provide 'let-completion-external)
;;; let-completion-external.el ends here
