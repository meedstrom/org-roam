;;; org-roam.el --- A database abstraction layer for Org-mode -*- coding: utf-8; lexical-binding: t; -*-

;; Copyright © 2020-2025 Jethro Kuan <jethrokuan95@gmail.com>

;; Author: Jethro Kuan <jethrokuan95@gmail.com>
;; URL: https://github.com/org-roam/org-roam
;; Keywords: org-mode, roam, convenience
;; Version: 2.3.1
;; Package-Requires: ((emacs "26.1") (compat "30.1") (dash "2.13") (org "9.6") (emacsql "4.1.0") (magit-section "3.0.0"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;;
;; Org-roam is a Roam Research inspired Emacs package and is an addition to
;; Org-mode to have a way to quickly process complex SQL-like queries over a
;; large set of plain text Org-mode files. To achieve this Org-roam provides a
;; database abstraction layer, the capabilities of which include, but are not
;; limited to:
;;
;; - Link graph traversal and visualization.
;; - Instantaneous SQL-like queries on headlines
;;   - What are my TODOs, scheduled for X, or due by Y?
;; - Accessing the properties of a node, such as its tags, refs, TODO state or
;;   priority.
;;
;; All of these functionality is powered by this layer. Hence, at its core
;; Org-roam's primary goal is to provide a resilient dual representation of
;; what's already available in plain text, while cached in a binary database,
;; that is cheap to maintain, easy to understand, and is as up-to-date as it
;; possibly can. For users who would like to perform arbitrary programmatic
;; queries on their Org files Org-roam also exposes an API to this database
;; abstraction layer.
;;
;; -----------------------------------------------------------------------------
;;
;; In order for the package to correctly work through your interactive session
;; it's mandatory to add somewhere to your configuration the next form:
;;
;;     (org-roam-db-autosync-mode)
;;
;; The form can be called both, before or after loading the package, which is up
;; to your preferences. If you call this before the package is loaded, then it
;; will automatically load the package.
;;
;; -----------------------------------------------------------------------------
;;
;; This package also comes with a set of officially supported extensions that
;; provide extra features. You can find them in the "extensions/" subdirectory.
;; These extensions are not automatically loaded with `org-roam`, but they still
;; will be lazy-loaded through their own `autoload's.
;;
;; Org-roam also has other extensions that don't come together with this package.
;; Such extensions are distributed as their own packages, while also
;; authored and maintained by different people on distinct repositories. The
;; majority of them can be found at https://github.com/org-roam and MELPA.
;;
;;; Code:
(require 'dash)

(require 'rx)
(require 'seq)
(require 'cl-lib)

(require 'compat)

(require 'magit-section)

(require 'emacsql)
;; REVIEW: is this require needed?
;; emacsql-sqlite provides a common interface to an emacsql SQLite backend (e.g. emacs-sqlite-builtin)
;; not to be confused with a backend itself named emacsql-sqlite that existed in emacsql < 4.0.
(require 'emacsql-sqlite)

(require 'org)
(require 'org-attach)                   ; To set `org-attach-id-dir'
(require 'org-id)
(require 'ol)
(require 'org-element)
(require 'org-capture)

(require 'ansi-color) ; to strip ANSI color codes in `org-roam--list-files'

(eval-when-compile
  (require 'subr-x))

;;; Options
(defgroup org-roam nil
  "A database abstraction layer for Org-mode."
  :group 'org
  :prefix "org-roam-"
  :link '(url-link :tag "Github" "https://github.com/org-roam/org-roam")
  :link '(url-link :tag "Online Manual" "https://www.orgroam.com/manual.html"))

(defgroup org-roam-faces nil
  "Faces used by Org-roam."
  :group 'org-roam
  :group 'faces)

(defcustom org-roam-verbose t
  "Echo messages that are not errors."
  :type 'boolean
  :group 'org-roam)

(defcustom org-roam-directory (expand-file-name "~/org-roam/")
  "Default path to Org-roam files.
All Org files, at any level of nesting, are considered part of the Org-roam."
  :type 'directory
  :group 'org-roam)

(defcustom org-roam-find-file-hook nil
  "Hook run when an Org-roam file is visited."
  :group 'org-roam
  :type 'hook)

(defcustom org-roam-post-node-insert-hook nil
  "Hook run when an Org-roam node is inserted as an Org link.
Each function takes two arguments: the id of the node, and the link description."
  :group 'org-roam
  :type 'hook)

(defcustom org-roam-file-extensions '("org")
  "List of file extensions to be included by Org-Roam.
While a file extension different from \".org\" may be used, the
file still needs to be an `org-mode' file, and it is the user's
responsibility to ensure that."
  :type '(repeat string)
  :group 'org-roam)

(defcustom org-roam-file-exclude-regexp (list org-attach-id-dir)
  "Files matching this regexp or list of regexps are excluded from Org-roam."
  :type '(choice
          (repeat
           (string :tag "Regular expression matching files to ignore"))
          (string :tag "Regular expression matching files to ignore")
          (const :tag "Include everything" nil))
  :group 'org-roam)

(defcustom org-roam-list-files-commands
  (if (member system-type '(windows-nt ms-dos cygwin))
      nil
    '(find fd fdfind rg))
  "Commands that will be used to find Org-roam files.

It should be a list of symbols or cons cells representing any of
the following supported file search methods.

The commands will be tried in order until an executable for a
command is found. The Elisp implementation is used if no command
in the list is found.

  `find'

    Use find as the file search method.
    Example command:
      find /path/to/dir -type f \
        \( -name \"*.org\" -o -name \"*.org.gpg\" -name \"*.org.age\" \)

  `fd'

    Use fd as the file search method.
    Example command:
      fd /path/to/dir/ --type file -e \".org\" -e \".org.gpg\" -e \".org.age\"

  `fdfind'

    Same as `fd'. It's an alias that used in some OSes (e.g. Debian, Ubuntu)

  `rg'

    Use ripgrep as the file search method.
    Example command:
       rg /path/to/dir/ --files -g \"*.org\" -g \"*.org.gpg\" -g \"*.org.age\"

By default, `executable-find' will be used to look up the path to
the executable. If a custom path is required, it can be specified
together with the method symbol as a cons cell. For example:
\\='(find (rg . \"/path/to/rg\"))."
  :type '(set
          (const :tag "find" find)
          (const :tag "fd" fd)
          (const :tag "fdfind" fdfind)
          (const :tag "rg" rg)
          (const :tag "elisp" nil)))

;;; Options and faces only used by org-roam-mode.el

;; Because org-roam-mode was always required in the past, users never had to
;; require it in the initfiles.  And that's good -- but it means that if
;; defcustoms stay there, they may be undefined by the time the user tries to
;; modify them in the initfiles.

;; It may be a good principle anyway to make all options and faces accessible
;; for customization without having loaded the file.

(defcustom org-roam-mode-sections (list 'org-roam-backlinks-section
                                        'org-roam-reflinks-section)
  "A list of sections for the `org-roam-mode' based buffers.
Each section is a function that is passed the `org-roam-node'
for which the section will be constructed as the first
argument. Normally this node is `org-roam-buffer-current-node'.
The function may also accept other optional arguments. Each item
in the list is either:

1. A function, which is called only with the `org-roam-node' as the argument
2. A list, containing the function and the optional arguments.

For example, one can add

    (org-roam-backlinks-section :unique t)

to the list to pass :unique t to the section-rendering function."
  :group 'org-roam
  :type `(repeat (choice (symbol :tag "Function")
                         (list :tag "Function with arguments"
                               (symbol :tag "Function")
                               (repeat :tag "Arguments" :inline t (sexp :tag "Arg"))))))

(defcustom org-roam-buffer-postrender-functions (list)
  "Functions to run after the Org-roam buffer is rendered.
Each function accepts no arguments, and is run with the Org-roam
buffer as the current buffer."
  :group 'org-roam
  :type 'hook)

(defcustom org-roam-preview-function 'org-roam-preview-default-function
  "The preview function to use to populate the Org-roam buffer.

The function takes no arguments, but the point is temporarily set
to the exact location of the backlink."
  :group 'org-roam
  :type 'function)

(defcustom org-roam-preview-postprocess-functions (list #'org-roam-strip-comments)
  "A list of functions to postprocess the preview content.

Each function takes a single argument, the string for the preview
content, and returns the post-processed string. The functions are
applied in order of appearance in the list."
  :group 'org-roam
  :type 'hook)

(defface org-roam-header-line
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "DarkGoldenrod4"
     :weight bold)
    (((class color) (background  dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :foreground "LightGoldenrod2"
     :weight bold))
  "Face for the `header-line' in some Org-roam modes."
  :group 'org-roam-faces)

(defface org-roam-title
  '((t :weight bold))
  "Face for Org-roam titles."
  :group 'org-roam-faces)

(defface org-roam-olp
  '((((class color) (background light)) :foreground "grey60")
    (((class color) (background  dark)) :foreground "grey40"))
  "Face for the OLP of the node."
  :group 'org-roam-faces)

(defface org-roam-preview-heading
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey80"
     :foreground "grey30")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey25"
     :foreground "grey70"))
  "Face for preview headings."
  :group 'org-roam-faces)

(defface org-roam-preview-heading-highlight
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey75"
     :foreground "grey30")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :background "grey35"
     :foreground "grey70"))
  "Face for current preview headings."
  :group 'org-roam-faces)

(defface org-roam-preview-heading-selection
  `((((class color) (background light))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit org-roam-preview-heading-highlight
     :foreground "salmon4")
    (((class color) (background dark))
     ,@(and (>= emacs-major-version 27) '(:extend t))
     :inherit org-roam-preview-heading-highlight
     :foreground "LightSalmon3"))
  "Face for selected preview headings."
  :group 'org-roam-faces)

(defface org-roam-preview-region
  `((t :inherit bold
       ,@(and (>= emacs-major-version 27)
              (list :extend (ignore-errors (face-attribute 'region :extend))))))
  "Face used by `org-roam-highlight-preview-region-using-face'.

This face is overlaid over text that uses other hunk faces,
and those normally set the foreground and background colors.
The `:foreground' and especially the `:background' properties
should be avoided here.  Setting the latter would cause the
loss of information.  Good properties to set here are `:weight'
and `:slant'."
  :group 'org-roam-faces)

(defface org-roam-dim
  '((((class color) (background light)) :foreground "grey60")
    (((class color) (background  dark)) :foreground "grey40"))
  "Face for the dimmer part of the widgets."
  :group 'org-roam-faces)

;;; Library
(defun org-roam-file-p (&optional file)
  "Return t if FILE is an Org-roam file, nil otherwise.
If FILE is not specified, use the current buffer's file-path.

FILE is an Org-roam file if:
- It's located somewhere under `org-roam-directory'
- It has a matching file extension (`org-roam-file-extensions')
- It doesn't match excluded regexp (`org-roam-file-exclude-regexp')"
  (when (or file (buffer-file-name (buffer-base-buffer)))
    (let* ((path (or file (buffer-file-name (buffer-base-buffer))))
           (relative-path (file-relative-name path org-roam-directory))
           (ext (org-roam--file-name-extension path))
           (ext (if (or (string= ext "gpg")
                        (string= ext "age"))
                    (org-roam--file-name-extension (file-name-sans-extension path))
                  ext))
           (org-roam-dir-p (org-roam-descendant-of-p path org-roam-directory))
           (valid-file-ext-p (member ext org-roam-file-extensions))
           (match-exclude-regexp-p
            (cond
             ((not org-roam-file-exclude-regexp) nil)
             ((stringp org-roam-file-exclude-regexp)
              (string-match-p org-roam-file-exclude-regexp relative-path))
             ((listp org-roam-file-exclude-regexp)
              (let (is-match)
                (dolist (exclude-re org-roam-file-exclude-regexp)
                  (setq is-match (or is-match (string-match-p exclude-re relative-path))))
                is-match)))))
      (save-match-data
        (and
         path
         org-roam-dir-p
         valid-file-ext-p
         (not match-exclude-regexp-p))))))

;;;###autoload
(defun org-roam-list-files ()
  "Return a list of all Org-roam files under `org-roam-directory'.
See `org-roam-file-p' for how each file is determined to be as
part of Org-Roam."
  (org-roam--list-files (expand-file-name org-roam-directory)))

(defun org-roam-buffer-p (&optional buffer)
  "Return t if BUFFER is for an Org-roam file.
If BUFFER is not specified, use the current buffer."
  (let ((buffer (or buffer (current-buffer)))
        path)
    (with-current-buffer buffer
      (and (derived-mode-p 'org-mode)
           (setq path (buffer-file-name (buffer-base-buffer)))
           (org-roam-file-p path)))))

(defun org-roam-buffer-list ()
  "Return a list of buffers that are Org-roam files."
  (--filter (org-roam-buffer-p it)
            (buffer-list)))

(defun org-roam--file-name-extension (filename)
  "Return file name extension for FILENAME.
Like `file-name-extension', but does not strip version number."
  (save-match-data
    (let ((file (file-name-nondirectory filename)))
      (if (and (string-match "\\.[^.]*\\'" file)
               (not (eq 0 (match-beginning 0))))
          (substring file (+ (match-beginning 0) 1))))))

(defun org-roam--list-files (dir)
  "Return all Org-roam files located recursively within DIR.
Use external shell commands if defined in `org-roam-list-files-commands'."
  (let (path exe)
    (cl-dolist (cmd org-roam-list-files-commands)
      (pcase cmd
        (`(,e . ,path)
         (setq path (executable-find path)
               exe  (symbol-name e)))
        ((pred symbolp)
         (setq path (executable-find (symbol-name cmd))
               exe (symbol-name cmd)))
        (wrong-type
         (signal 'wrong-type-argument
                 `((consp symbolp)
                   ,wrong-type))))
      (when path (cl-return)))
    (if-let* ((files (when path
                       (let ((fn (intern (concat "org-roam--list-files-" exe))))
                         (unless (fboundp fn) (user-error "%s is not an implemented search method" fn))
                         (funcall fn path (format "\"%s\"" dir)))))
              (files (seq-filter #'org-roam-file-p files))
              (files (mapcar #'expand-file-name files))) ; canonicalize names
        files
      (org-roam--list-files-elisp dir))))

(defun org-roam--shell-command-files (cmd)
  "Run CMD in the shell and return a list of files.
If no files are found, an empty list is returned."
  (--> cmd
       (shell-command-to-string it)
       (ansi-color-filter-apply it)
       (split-string it "\n")
       (seq-filter (lambda (s)
                     (not (or (null s) (string= "" s)))) it)))

(defun org-roam--list-files-search-globs (exts)
  "Given EXTS, return a list of search globs.
E.g. (\".org\") => (\"*.org\" \"*.org.gpg\")"
  (cl-loop for e in exts
           append (list (format "\"*.%s\"" e)
                        (format "\"*.%s.gpg\"" e)
                        (format "\"*.%s.age\"" e))))

(defun org-roam--list-files-find (executable dir)
  "Return all Org-roam files under DIR, using \"find\", provided as EXECUTABLE."
  (let* ((globs (org-roam--list-files-search-globs org-roam-file-extensions))
         (names (string-join (mapcar (lambda (glob) (concat "-name " glob)) globs) " -o "))
         (command (string-join `(,executable "-L" ,dir "-type f \\(" ,names "\\)") " ")))
    (org-roam--shell-command-files command)))

(defun org-roam--list-files-fd (executable dir)
  "Return all Org-roam files under DIR, using \"fd\", provided as EXECUTABLE."
  (let* ((globs (org-roam--list-files-search-globs org-roam-file-extensions))
         (extensions (string-join (mapcar (lambda (glob) (concat "-e " (substring glob 2 -1))) globs) " "))
         (command (string-join `(,executable "-L" "--type file" ,extensions "." ,dir) " ")))
    (org-roam--shell-command-files command)))

(defalias 'org-roam--list-files-fdfind #'org-roam--list-files-fd)

(defun org-roam--list-files-rg (executable dir)
  "Return all Org-roam files under DIR, using \"rg\", provided as EXECUTABLE."
  (let* ((globs (org-roam--list-files-search-globs org-roam-file-extensions))
         (command (string-join `(
                                 ,executable "-L" ,dir "--files"
                                 ,@(mapcar (lambda (glob) (concat "-g " glob)) globs)) " ")))
    (org-roam--shell-command-files command)))

(declare-function org-roam--directory-files-recursively "org-roam-compat")

(defun org-roam--list-files-elisp (dir)
  "Return all Org-roam files under DIR, using Elisp based implementation."
  (let ((regex (concat "\\.\\(?:"(mapconcat
                                  #'regexp-quote org-roam-file-extensions
                                  "\\|" )"\\)\\(?:\\.gpg\\|\\.age\\)?\\'"))
        result)
    (dolist (file (org-roam--directory-files-recursively dir regex nil nil t) result)
      (when (and (file-readable-p file)
                 (org-roam-file-p file))
        (push file result)))))

;;; Package bootstrap
(provide 'org-roam)

(cl-eval-when (load eval)
  (require 'org-roam-compat)
  (require 'org-roam-utils)
  (require 'org-roam-db)
  (require 'org-roam-node)
  (require 'org-roam-id)
  (require 'org-roam-capture)
  (require 'org-roam-log))

;;; org-roam.el ends here
