;;; counsel-gtags.el --- ivy for GNU global -*- lexical-binding: t; -*-

;; Copyright (C) 2016 by Syohei YOSHIDA

;; Author: Syohei YOSHIDA <syohex@gmail.com>
;;         Felipe Lema <felipelema@mortemale.org>
;; URL: https://github.com/FelipeLema/emacs-counsel-gtags
;; Version: 0.01
;; Package-Requires: ((emacs "25.1") (counsel "0.8.0") (seq "1.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `counsel-gtags.el' provides `ivy' interface of GNU GLOBAL.

;;; Code:

(require 'counsel)
(require 'cl-lib)
(require 'rx)
(require 'seq)

(declare-function cygwin-convert-file-name-from-windows "cygw32.c")
(declare-function cygwin-convert-file-name-to-windows "cygw32.c")
(declare-function tramp-file-name-localname "tramp")
(declare-function tramp-dissect-file-name "tramp")

(defgroup counsel-gtags nil
  "`counsel' for GNU Global"
  :group 'counsel)

(defcustom counsel-gtags-ignore-case nil
  "Whether to ignore case in search pattern."
  :type 'boolean)

(defconst counsel-gtags-path-style-alist '(through relative absolute abslib))

(defcustom counsel-gtags-path-style 'through
  "Path style of candidates.
The following values are supported:
- `through'     Show path from root of current project.
- `relative' Show path from current directory.
- `absolute' Show absolute path.
- `abslib' Show absolute path for libraries (GTAGSLIBPATH) and relative path for the rest."
  :type '(choice (const :tag "Root of the current project" through)
                 (const :tag "Relative from the current directory" relative)
                 (const :tag "Absolute path" absolute)
                 (const :tag "Absolute path for libraries (GTAGSLIBPATH) and relative path for the rest" abslib)))

(defcustom counsel-gtags-auto-update nil
  "Whether to update the tag database when a buffer is saved to file."
  :type 'boolean)

(defcustom counsel-gtags-simule-xref t
  "Whether we substitute xref commands."
  :type 'boolean)

(defcustom counsel-gtags-update-interval-second 60
  "Update tag database after this many seconds have passed.
If nil, the tags are updated every time a buffer is saved to file."
  :type '(choice (integer :tag "Update after this many seconds")
                 (boolean :tag "Update every time" nil)))

(defcustom counsel-gtags-use-input-at-point t
  "Whether to use input at point.
If non-nil, the symbol at point is used as default value when
searching for a tag."
  :type 'boolean)

(defcustom counsel-gtags-global-extra-update-options-list nil
  "List of extra arguments passed to global when updating database."
  :type 'list)

(defcustom counsel-gtags-gtags-extra-update-options-list nil
  "List of extra arguments passed to gtags when updating database."
  :type 'list)

(defcustom counsel-gtags-prefix-key (kbd "C-c g")
  "Key binding used for `counsel-gtags-mode-map'.
This variable does not have any effect unless
`counsel-gtags-use-suggested-key-map' is non-nil."
  :type 'string)

(defcustom counsel-gtags-use-suggested-key-map t
  "Whether to use the suggested key bindings.
This variable must be set before enabling the mode"
  :type 'boolean)

(defconst counsel-gtags--prompts
  '((definition . "Find Definition: ")
    (file      . " Find File: ")
    (pattern    . "Find Pattern: ")
    (reference  . "Find Reference: ")
    (symbol     . "Find Symbol: ")))

(defconst counsel-gtags--complete-options
  '((definition . "-d")
    (file      . "-P")
    (pattern   . "-g")
    (reference . "-r")
    (symbol    . "-s")))

(defvar counsel-gtags--last-update-time 0)
(defvar counsel-gtags--context nil)
(defvar counsel-gtags--other-window nil
  "Helper global variable to implement other window functions.")
(defvar counsel-gtags--original-default-directory nil
  "Last `default-directory' where command is invoked.")

(defvar-local counsel-gtags--context-position 0)
(defvar-local counsel-gtags--get-grep-command nil)

(defconst counsel-gtags--grep-commands '("rg" "ag" "grep")
  "List of grep-like commands to filter candidates.
The first command available is used to do the filtering.  `grep-command', if
non-nil and available, has a higher priority than any entries in this list.
Use `counsel-gtags--grep-options' to specify the options
to suppress colored output.")

(defconst counsel-gtags--grep-options
  '(("rg" . "--color never")
    ("ag" . "--nocolor")
    ("grep" . "--color=never"))
  "List of grep-like commands with their options to suppress colored output.")

(defconst counsel-gtags--labels
  '("default" "native" "ctags" "pygments")
  "List of valid values for gtags labels.")

(defconst counsel-gtags--include-regexp
  "\\`\\s-*#\\(?:include\\|import\\)\\s-*[\"<]\\(?:[./]*\\)?\\(.*?\\)[\">]")

(defun counsel-gtags--command-options (type extra-options)
  "Get list with options for global command according to TYPE.

Prepend EXTRA-OPTIONS.  If \"--result=.\" is in EXTRA-OPTIONS, it will have
precedence over default \"--result=grep\"."
  (let* ((extra (or (and (stringp extra-options) extra-options)
		    " "))
	 (options (concat
		   (and (getenv "GTAGSLIBPATH") "-T ")
		   (and current-prefix-arg "-l ")
		   (and counsel-gtags-ignore-case "-i ")
		   (and (memq counsel-gtags-path-style counsel-gtags-path-style-alist)
			(format "--path-style=%s " (symbol-name counsel-gtags-path-style)))
		   (assoc-default type counsel-gtags--complete-options) " "
		   (unless (string-match-p "--result=" extra)
		     "--result=grep ")
		   extra)))
    options))

(defun counsel-gtags--get-grep-command-find ()
  "Get a grep command to be used to filter candidates.

Returns a command without arguments.
Otherwise, returns nil if couldn't find any.

Use `counsel-gtags--grep-commands' to specify a list of commands to be
checked for availability."
  (or counsel-gtags--get-grep-command        ;; Search only the first time
      (setq counsel-gtags--get-grep-command
	    (catch 'path
	      (mapc (lambda (exec)
		      (let ((path (executable-find exec)))
			(when path
			  (throw 'path
				 (concat path " "
					 (cdr (assoc-string exec counsel-gtags--grep-options)))))))
		    counsel-gtags--grep-commands)
	      nil))))

(defun counsel-gtags--build-command-to-collect-candidates (query)
  "Build command to collect condidates filtering by QUERY.

Used in `counsel-gtags--async-tag-query'.  Call global \"list all tags\"
\(with EXTRA-ARGS\), forward QUERY to grep command (provided by
`counsel-gtags--get-grep-command-find') to filter.  We use grep command because using
ivy's default filter `counsel--async-filter' is too slow with lots of tags."
  (concat
   "global -c "
   (counsel-gtags--command-options 'definition "--result=ctags")
   " | "
   (counsel-gtags--get-grep-command-find)
   " "
   (shell-quote-argument (counsel--elisp-to-pcre (ivy--regex query)))))


(defun counsel-gtags--async-tag-query-process (query)
  "Add filter to tag query command.

Input for searching is QUERY.

Since we can't look for tags by regex, we look for their definition and filter
the location, giving us a list of tags with no locations."
  (let ((command (counsel-gtags--build-command-to-collect-candidates query)))
    (counsel--async-command command)))

(defun counsel-gtags--async-tag-query (query)
  "Gather the object names asynchronously for `ivy-read'.

Use global flags according to TYPE.

Forward QUERY to global command to be treated as regex.

Because «global -c» only accepts letters-and-numbers, we actually search for
tags matching QUERY, but filter the list.

Inspired on ivy.org's `counsel-locate-function'."
  (or (ivy-more-chars)
      (progn
	(counsel-gtags--async-tag-query-process query)
	'("" "Filtering …"))))

(defun counsel-gtags--file-and-line (candidate)
  "Return list with file and position per CANDIDATE.

Candidates are supposed to be strings of the form \"file:line\" as returned by
global. Line number is returned as number (and not string)."
  (if (and (memq system-type '(windows-nt ms-dos))  ;; in MS windows
           (string-match-p "\\`[a-zA-Z]:" candidate)) ;; Windows Driver letter
      (when (string-match "\\`\\([^:]+:[^:]+:\\):\\([^:]+\\)" candidate)
        (list (match-string-no-properties 1)
              (string-to-number (match-string-no-properties 2))))
    (let ((fields (split-string candidate ":")))
      (list (car fields) (string-to-number (or (cadr fields) "1"))))))

(defun counsel-gtags--resolve-actual-file-from (file-candidate)
  "Resolve actual file path from CANDIDATE taken from a global cmd query.

Note: candidates are handled as ⎡file:location⎦ and ⎡(file . location)⎦.
     FILE-CANDIDATE is supposed to be *only* the file part of a candidate."
  (let ((file-path-per-style
	 (concat
	  (pcase counsel-gtags-path-style
	    ((or 'relative 'absolute 'abslib) "")
	    ('through (file-name-as-directory
		       (counsel-gtags--default-directory)))
	    (_ (error
		"Unexpected counsel-gtags-path-style: %s"
		(symbol-name counsel-gtags-path-style))))
	  file-candidate)))
    (file-truename file-path-per-style)))

(defun counsel-gtags--jump-to (candidate &optional push)
  "Call `find-file' and `forward-line' on file location from CANDIDATE .

Calls `counsel-gtags--push' at the end if PUSH is non-nil.
Returns (buffer line)"
  (cl-multiple-value-bind (file-path line)
      (counsel-gtags--file-and-line candidate)
    (let* ((default-directory (file-name-as-directory
			       (or counsel-gtags--original-default-directory
				   default-directory)))
	   (file (counsel-gtags--resolve-actual-file-from file-path))
	   (opened-buffer (if counsel-gtags--other-window
			      (find-file-other-window file)
			    (find-file file))))
      ;; position correctly within the file
      (goto-char (point-min))
      (forward-line (1- line))
      (back-to-indentation)
      (if (and push
	       (not counsel-gtags--other-window))
	  (counsel-gtags--push 'to))
      `(,opened-buffer ,line))))

(defun counsel-gtags--find-file (candidate)
  "Open file-at-position per CANDIDATE using `find-file'.
This is the `:action' callback for `ivy-read' calls."
  (with-ivy-window
    (swiper--cleanup)
    (counsel-gtags--push 'from))
  (counsel-gtags--jump-to candidate 'push))

(defun counsel-gtags--find-file-other-window (candidate)
  "Open file-at-position per CANDIDATE using `find-file-other-window'.
This is the alternative `:action' callback for `ivy-read' calls."
  (let ((counsel-gtags--other-window t))
    (counsel-gtags--find-file candidate)))

(defmacro counsel-gtags--read-tag (type)
  "Prompt the user for selecting a tag using `ivy-read'.

Returns selected tag
Use TYPE ∈ '(definition reference symbol) for defining global parameters.
If `counsel-gtags-use-input-at-point' is non-nil, will use symbol at point as
initial input for `ivy-read'.

See `counsel-gtags--async-tag-query' for more info."
  `(ivy-read ,(alist-get type counsel-gtags--prompts)
	     #'counsel-gtags--async-tag-query
	     :initial-input (and counsel-gtags-use-input-at-point
				 (ivy-thing-at-point))
	     :unwind (lambda ()
		       (counsel-delete-process)
		       (swiper--cleanup))
	     :dynamic-collection t
	     :caller 'counsel-gtags--read-tag))

;; (counsel-gtags--read-tag definition)

(defun counsel-gtags--process-lines (command args)
  "Like `process-lines' on COMMAND and ARGS, but using `process-file'.

`process-lines' does not support Tramp because it uses `call-process'.  Using
`process-file' makes Tramp support auto-magical."
  ;; Space before buffer name to make it "invisible"
  (let ((global-run-buffer (get-buffer-create (format " *global @ %s*" default-directory))))
    ;; The buffer needs to be cleared, this can be done after split-string,
    ;; but for now it is better to keep it like this for debugging purposed
    ;; between calls
    (with-current-buffer global-run-buffer
      (erase-buffer)
      (apply #'process-file command
	     nil    ;; no input file
	     t      ;;Current BUFFER
	     nil    ;;DISPLAY
	     (split-string args))

      (split-string (buffer-string) "\n" t))))

(defun counsel-gtags--collect-candidates (type tagname encoding extra-options)
  "Collect lines for ⎡global …⎦ using TAGNAME as query.

TAGNAME may be nil, suggesting a match-any query.
Use TYPE to specify query type (tag, file).
Use ENCODING to specify encoding.
Use EXTRA-OPTIONS to specify encoding.

This is for internal use and not for final user."
  (let* ((options (counsel-gtags--command-options type extra-options))
         (default-directory default-directory)
         (coding-system-for-read encoding)
         (coding-system-for-write encoding)
	 (query-as-list (pcase tagname
			  ((pred null) '())
			  ("" '())
			  (`definition '())
			  (_ (shell-quote-argument tagname))))
	 (global-args (concat options query-as-list)))
    (counsel-gtags--process-lines "global" global-args)))

(defsubst counsel-gtags--select-file-collection (type tagname extra-options)
  "Candidated collection for counsel-gtags--select-file."
  (counsel-gtags--collect-candidates
   type tagname buffer-file-coding-system extra-options))

(defun counsel-gtags--select-file (type tagname
					&optional extra-options auto-select-only-candidate)
  "Prompt the user to select a file_path:position according to query.

Use TYPE ∈ '(definition reference symbol) for defining global parameters.
Use TAGNAME for global query.
Use AUTO-SELECT-ONLY-CANDIDATE to skip `ivy-read' if have a single candidate.
Extra command line parameters to global are forwarded through EXTRA-OPTIONS."
  (let* ((default-directory (counsel-gtags--default-directory))
	 (collection (counsel-gtags--select-file-collection type tagname extra-options))
	 (ivy-auto-select-single-candidate t)
	 (first (cadr collection)))
    (if (and auto-select-only-candidate (= (length collection) 1))
        (counsel-gtags--find-file (car first))
      (ivy-read "Pattern: "
		collection
		:action #'counsel-gtags--find-file
		:caller 'counsel-gtags--select-file))))

(ivy-set-actions
 'counsel-gtags--select-file
 '(("j" counsel-gtags--find-file-other-window "other window")))

;;;###autoload
(defun counsel-gtags-find-definition (tagname)
  "Search for TAGNAME definition in tag database.
Prompt for TAGNAME if not given."
  (interactive
   (list (counsel-gtags--read-tag definition)))
  (counsel-gtags--select-file 'definition tagname))

;;;###autoload
(defun counsel-gtags-find-reference (tagname)
  "Search for TAGNAME reference in tag database.
Prompt for TAGNAME if not given."
  (interactive
   (list (counsel-gtags--read-tag reference)))
  (counsel-gtags--select-file 'reference tagname))

;;;###autoload
(defun counsel-gtags-find-symbol (tagname)
  "Search for TAGNAME symbol in tag database.
Prompt for TAGNAME if not given."
  (interactive
   (list (counsel-gtags--read-tag symbol)))
  (counsel-gtags--select-file 'symbol tagname))

;; Other window Commands

(defun counsel-gtags-find-definition-other-window (tagname)
  "Search for TAGNAME definition in tag database in other window.
Prompt for TAGNAME if not given."
  (interactive
   (list (counsel-gtags--read-tag definition)))
  (let ((counsel-gtags--other-window t))
    (counsel-gtags--select-file 'definition tagname)))

;;;###autoload
(defun counsel-gtags-find-reference-other-window (tagname)
  "Search for TAGNAME reference in tag database in other window.
Prompt for TAGNAME if not given."
  (interactive
   (list (counsel-gtags--read-tag reference)))
  (let ((counsel-gtags--other-window t))
    (counsel-gtags--select-file 'reference tagname)))

;;;###autoload
(defun counsel-gtags-find-symbol-other-window (tagname)
  "Search for TAGNAME symbol in tag database in other window.
Prompt for TAGNAME if not given."
  (interactive
   (list (counsel-gtags--read-tag symbol)))
  (let ((counsel-gtags--other-window t))
    (counsel-gtags--select-file 'symbol tagname)))

(defun counsel-gtags--include-file ()
  "Get ⎡#include …⎦ from first line."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (when (string-match counsel-gtags--include-regexp line)
      (match-string-no-properties 1 line))))

(defun counsel-gtags--default-directory ()
  "Return default directory per `counsel-gtags-path-style'.

Useful for jumping from a location when using global commands (like with
\"--from-here\")."
  (setq counsel-gtags--original-default-directory
        (cl-case counsel-gtags-path-style
          ((relative absolute) default-directory)
          (through (or (getenv "GTAGSROOT")
		       (locate-dominating-file default-directory "GTAGS")
		       ;; If file doesn't exist create it
		       (if (yes-or-no-p "File GTAGS not found. Run 'gtags'? ")
			   (interactive-call counsel-gtags-create-tags)
			 (error "Abort generating tag files")))))))

(defsubst counsel-gtags--find-file-collection()
  "Candidated for counsel-gtags-find-file."
  (counsel-gtags--collect-candidates
   'file nil buffer-file-coding-system "--result=path "))

;;;###autoload
(defun counsel-gtags-find-file (&optional filename)
  "Search/narrow for FILENAME among tagged files."
  (interactive)
  (let* ((initial-input (or filename (counsel-gtags--include-file)))
         (collection (counsel-gtags--find-file-collection)))
    (ivy-read "Find File: " collection
	      :initial-input initial-input
	      :action #'counsel-gtags--find-file
	      :caller 'counsel-gtags-find-file)))

(defun counsel-gtags-find-file-other-window (&optional filename)
  (interactive)
  "Search/narrow for FILENAME among tagged files in other window."
  (let ((counsel-gtags--other-window t))
    (call-interactively #'counsel-gtags-find-file filename)))

(ivy-set-actions
 'counsel-gtags-find-file
 '(("j" counsel-gtags--find-file-other-window "other window")))

(defun counsel-gtags--goto (position)
  "Go to POSITION in context stack.
Return t on success, nil otherwise."
  (let ((context (nth position counsel-gtags--context)))
    (when (and context
               (cond
                ((plist-get context :file)
                 (find-file (plist-get context :file)))
                ((and (plist-get context :buffer)
                      (buffer-live-p (plist-get context :buffer)))
                 (switch-to-buffer (plist-get context :buffer)))
                (t nil)))
      (goto-char (point-min))
      (forward-line (1- (plist-get context :line)))
      t)))

;;;###autoload
(defun counsel-gtags-go-backward ()
  "Go to previous position in context stack."
  (interactive)
  (unless counsel-gtags--context
    (user-error "Context stack is empty"))
  (catch 'exit
    (let ((position counsel-gtags--context-position)
          (num-entries (length counsel-gtags--context)))
      (while (< (cl-incf position) num-entries)
        (when (counsel-gtags--goto position)
          (setq counsel-gtags--context-position position)
          (throw 'exit t))))))

;;;###autoload
(defun counsel-gtags-go-forward ()
  "Go to next position in context stack."
  (interactive)
  (unless counsel-gtags--context
    (user-error "Context stack is empty"))
  (catch 'exit
    (let ((position counsel-gtags--context-position))
      (while (>= (cl-decf position) 0)
        (when (counsel-gtags--goto position)
          (setq counsel-gtags--context-position position)
          (throw 'exit t))))))

(defun counsel-gtags--push (direction)
  "Add new entry to context stack.

  DIRECTION ∈ '(from, to)."
  (let ((new-context (list :file (and (buffer-file-name)
                                      (file-truename (buffer-file-name)))
                           :buffer (current-buffer)
                           :line (line-number-at-pos)
                           :direction direction)))
    (setq counsel-gtags--context
          (nthcdr counsel-gtags--context-position counsel-gtags--context))
    ;; We do not want successive entries with from-direction,
    ;; so we remove the old one.
    (let ((prev-context (car counsel-gtags--context)))
      (if (and (eq direction 'from)
               (eq (plist-get prev-context :direction) 'from))
          (pop counsel-gtags--context)))
    (push new-context counsel-gtags--context)
    (setq counsel-gtags--context-position 0)))

(defun counsel-gtags--make-gtags-sentinel (action)
  "Return default sentinel that messages success/failed exit.

  Message printed has ACTION as detail."
  (lambda (process _event)
    (when (eq (process-status process) 'exit)
      (if (zerop (process-exit-status process))
          (message "Success: %s TAGS" action)
        (message "Failed: %s TAGS(%d)" action (process-exit-status process))))))

;;;###autoload
(defun counsel-gtags-create-tags (rootdir label)
  "Create tag database in ROOTDIR.
LABEL is passed as the value for the environment variable GTAGSLABEL.
Prompt for ROOTDIR and LABEL if not given.  This command is asynchronous."
  (interactive
   (list (read-directory-name "Root Directory: " nil nil t)
         (ivy-read "GTAGSLABEL: " counsel-gtags--labels)))
  (let* ((default-directory rootdir)
         (proc-buf (get-buffer-create " *counsel-gtags-tag-create*"))
         (proc (start-file-process
                "counsel-gtags-tag-create" proc-buf
                "gtags" "-q" (concat "--gtagslabel=" label))))
    (set-process-sentinel
     proc
     (counsel-gtags--make-gtags-sentinel 'create))))

(defun counsel-gtags--remote-truename (&optional file-path)
  "Return real file name for file path FILE-PATH in remote machine.

  If file is local, return its `file-truename'

  FILE-PATH defaults to current buffer's file if it was not provided."
  (let ((filename (or file-path
                      (buffer-file-name)
                      (error "This buffer is not related to any file")))
	(default-directory (file-name-as-directory default-directory)))
    (if (file-remote-p filename)
        (tramp-file-name-localname (tramp-dissect-file-name filename))
      (file-truename filename))))

(defun counsel-gtags--read-tag-directory ()
  "Get directory for tag generation from user."
  (let ((dir (read-directory-name "Directory tag generated: " nil nil t)))
    ;; On Windows, "gtags d:/tmp" work, but "gtags d:/tmp/" doesn't
    (directory-file-name (expand-file-name dir))))

(defun counsel-gtags--update-tags-command (how-to)
  "Build global command line to update commands.
HOW-TO ∈ '(entire-update generate-other-directory single-update)
per (user prefix)."
  (cl-case how-to
    (entire-update
     (concat "global -u " counsel-gtags-global-extra-update-options-list))
    (generate-other-directory
     (concat "gtags "
	     counsel-gtags-global-extra-update-options-list
	     counsel-gtags--read-tag-directory))
    (single-update
     (concat "global --single-update "
	     counsel-gtags-global-extra-update-options-list
	     counsel-gtags--remote-truename))))

(defun counsel-gtags--update-tags-p (how-to interactive-p current-time)
  "Should we update tags now?.

  Will update if being called interactively per INTERACTIVE-P.
  If HOW-TO equals 'single-update, will update only if
  `counsel-gtags-update-interval-second' seconds have passed up to CURRENT-TIME."
  (or interactive-p
      (and (eq how-to 'single-update)
           (buffer-file-name)
           (or (not counsel-gtags-update-interval-second)
               (>= (- current-time counsel-gtags--last-update-time)
                   counsel-gtags-update-interval-second)))))

;;;###autoload
(defun counsel-gtags-update-tags ()
  "Update tag database for current file.
Changes in other files are ignored.  With a prefix argument, update
tags for all files.  With two prefix arguments, generate new tag
database in prompted directory."
  (interactive)
  (let ((how-to (cl-case (prefix-numeric-value current-prefix-arg)
		  (4 'entire-update)
		  (16 'generate-other-directory)
		  (otherwise 'single-update)))
        (interactive-p (called-interactively-p 'interactive))
        (current-time (float-time (current-time)))
	cmds proc)
    (when (counsel-gtags--update-tags-p how-to interactive-p current-time)
      (let* ((cmds (counsel-gtags--update-tags-command how-to))
             (proc (apply #'start-file-process "counsel-gtags-update-tag" nil
			  (split-string cmds))))
        (if (not proc)
            (message "Failed: %s" cmds)
          (set-process-sentinel proc (counsel-gtags--make-gtags-sentinel 'update))
          (setq counsel-gtags--last-update-time current-time))))))

(defun counsel-gtags--from-here (tagname)
  "Try to open file by querying TAGNAME and \"--from-here\"."
  (let* ((line (line-number-at-pos))
         (root (counsel-gtags--remote-truename (counsel-gtags--default-directory)))
         (file (counsel-gtags--remote-truename))
         (from-here-opt (format "--from-here=%d:%s " line (file-relative-name file root))))
    (counsel-gtags--select-file 'from-here tagname from-here-opt t)))

;;;###autoload
(defun counsel-gtags--references-dwim ()
  "Find definition or reference of thing at point (Do What I Mean).
If point is at a definition, find its references, otherwise, find
its definition."
  (interactive)
  (let ((cursor-symbol (thing-at-point 'symbol t))
	(ivy-auto-select-single-candidate t))
    (call-interactively 'counsel-gtags-find-definition)))

(defun counsel-gtags-dwim ()
  "Find definition or reference of thing at point (Do What I Mean).
If point is at a definition, find its references, otherwise, find
its definition."
  (interactive)
  (let ((cursor-symbol (thing-at-point 'symbol t)))
    (if (and (buffer-file-name) cursor-symbol)
        (counsel-gtags--from-here cursor-symbol)
      (call-interactively 'counsel-gtags-find-definition))))

(defvar counsel-gtags-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'counsel-gtags-dwim)
    (define-key map (kbd "d") #'counsel-gtags-find-definition)
    (define-key map (kbd "r") #'counsel-gtags-find-reference)
    (define-key map (kbd "s") #'counsel-gtags-find-symbol)
    (define-key map (kbd "n") #'counsel-gtags-go-forward)
    (define-key map (kbd "p") #'counsel-gtags-go-backward)
    (define-key map (kbd "c") #'counsel-gtags-create-tags)
    (define-key map (kbd "u") #'counsel-gtags-update-tags)
    (define-key map (kbd "f") #'counsel-gtags-find-file)
    (define-key map (kbd "4 d") #'counsel-gtags-find-definition-other-window)
    (define-key map (kbd "4 r") #'counsel-gtags-find-reference-other-window)
    (define-key map (kbd "4 s") #'counsel-gtags-find-symbol-other-window)
    (define-key map (kbd "4 f") #'counsel-gtags-find-file-other-window)
    map))

(defvar counsel-gtags-mode-map (make-sparse-keymap)
  (let ((map (make-sparse-keymap)))
    (when counsel-gtags-use-suggested-key-map
      (when counsel-gtags-prefix-key
	(define-key map counsel-gtags-prefix-key 'counsel-gtags-command-map))
      (when counsel-gtags-simule-xref
	(define-key map [remap xref-pop-marker-stack] #'counsel-gtags-go-backward)
	(define-key map [remap xref-find-definitions] #'counsel-gtags-dwim)
	(define-key map [remap xref-find-references] #'counsel-gtags--references-dwim)
	))
    map))

;;;###autoload
(define-minor-mode counsel-gtags-mode ()
  "Minor mode of counsel-gtags.
  If `counsel-gtags-update-tags' is non-nil, the tag files are updated
  after saving buffer."
  :init-value nil
  :global     nil
  :keymap     counsel-gtags-mode-map
  (if counsel-gtags-mode
      (when counsel-gtags-auto-update
        (add-hook 'after-save-hook 'counsel-gtags-update-tags nil t))
    (when counsel-gtags-auto-update
      (remove-hook 'after-save-hook 'counsel-gtags-update-tags t))))

(provide 'counsel-gtags)

;;; counsel-gtags.el ends here
