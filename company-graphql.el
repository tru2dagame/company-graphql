;;; company-graphql.el --- completion for graphql file                     -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Timothy Shiu

;; Author: Timothy Shiu <timoweave@gmail.com>
;; Keywords: company graphql completion
;; Package-Requires: ((emacs "25.2.1") (company "0.9.4"))

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

;; Read README for more details.

;;; Code:

(require 'json)
(require 'subr-x)

(require 's)
(require 'dash)
(require 'company)

(defgroup company-graphql nil
  "Completion backends for commit templates."
  :tag "company-graphql"
  :group 'company)

(defconst company-graphql-schema-root "__GRAPHQL_SCHEMA_ROOT__"
  "Schema Root.")

(defconst company-graphql-schema-args "__GRAPHQL_SCHEMA_ARGS__"
  "Schema Argument.")

(defvar-local company-graphql-schema-filename nil
  "Filename that has graphql schema.")

(defvar-local company-graphql-schema-server nil
  "Server endpoint that has graphql __schema.")

(defvar-local company-graphql-schema-types-cache nil
  "Company Candidates Cache.")

(defun company-graphql--jsonify-hashtable (hashtable &optional buffer-name)
  "Debug json"
  (and hashtable
       (with-current-buffer (get-buffer-create (or buffer-name "*company-graphql*"))
	 (erase-buffer)
	 (json-mode)
	 (ignore-errors
	   (insert (json-encode hashtable))
	   (replace-string ":" ": " nil (point-min) (point-max))
	   (replace-string "," ",\n" nil (point-min) (point-max))
	   (replace-string "{" "{\n" nil (point-min) (point-max))
	   (replace-string "}" "\n}" nil (point-min) (point-max))
	   (replace-string "[" "[\n" nil (point-min) (point-max))
	   (replace-string "]" "\n]" nil (point-min) (point-max))
	   (indent-region (point-min) (point-max))))))

(defun company-graphql--schema-type (hashtables parent)
  "Get hashtables."
  (let ((type (cl-find-if
	       (lambda (hashtable)
		 (let ((name (gethash "name" hashtable)))
		   (string= parent name)))
	       hashtables)))
    type))

(defun company-graphql--schema-type-field-name (field)
  "Get the type without container [] nor constrianted !."
  (or (and (gethash "type" field)  (gethash "name" (gethash "type" field)))
      (and (gethash "type" field)  (gethash "name" (gethash "ofType" (gethash "type" field))))
      nil))

(defun company-graphql--schema-type-fields (hashtable)
  "List of (Field . Type) Pairs. where Field has :annotation and :meta"
  (let ((fields '())
	(names '()))
    (push (gethash "fields" hashtable) fields)
    (dolist (field (car fields))
      (let* ((text (gethash "name" field))
	     (annotation (company-graphql--schema-type-field-name field))
	     (meta "TBD")
	     (name (propertize text :annotation annotation :meta meta)))
	(push (cons name annotation) names)))
    names))

(defun company-graphql--schema-visit-dfs (items)
  "Visit the lookup table in DFS manner and print each field."
  (dolist (item items)
    (let ((name (gethash "name" item))
	  (fields (gethash "fields" item))
	  (keys '()))
      (if (not (listp fields))
	  (setq fields "")
	(mapcar
	 (lambda (field)
	   (and field
		(push (cons
		       (gethash "name" field)
		       (company-graphql--schema-type-field-name field)) keys)))
	 fields)
	(setq fields keys))
      fields)))

(defun company-graphql--schema-add-subroot (schema type name)
  "Make operation into type."
  (let* ((operation-type (gethash type schema))
	 (operation (make-hash-table :test 'equal)))
    (and operation-type
	 (progn
	   (puthash "kind" "Object" operation-type)
	   (puthash "ofType" nil operation-type)
	   (puthash "name" name operation)
	   (puthash "fields" nil operation)
	   (puthash "type" operation-type operation)
	   operation))))

(defun company-graphql--schema-add-root (schema)
  "Make operation into type."
  (let ((operations '())
	(query (company-graphql--schema-add-subroot
		schema "queryType" "query"))
	(mutation (company-graphql--schema-add-subroot
		   schema "mutationType" "mutation"))
	(subscription (company-graphql--schema-add-subroot
		       schema "subscriptionType" "subscription")))
    (let ((json-object-type 'hash-table)
	  (json-array-type 'list)
	  (json-key-type 'string)
	  (root (make-hash-table :test 'equal)))
      (when query (push query operations))
      (when mutation (push mutation operations))
      (when subscription (push subscription operations))
      (puthash "name" company-graphql-schema-root root)
      (puthash "fields" operations root)
      root)))

(defun company-graphql--schema-name-arg (name)
  "Return a name.arg string"
  (format "%s.%s" name company-graphql-schema-args))

(defun company-graphql--schema-add-arg-detail (schema type)
  "Add args detail"
  (let* ((types (gethash "types" schema))
	 (type-def (company-graphql--schema-type types type)))
    (and type-def
	 (let* ((type-fields (gethash "fields" type-def))
		(type-args (mapcar
			    (lambda (type) (let ((name (company-graphql--schema-name-arg (gethash "name" type)))
						 (fields (gethash "args" type))
						 (type-arg (make-hash-table :test 'equal)))
					     (puthash "name" name type-arg)
					     (puthash "fields" fields type-arg)
					     type-arg))
			    type-fields))
		)
	   type-args))))

(defun company-graphql--schema-add-arg-list (schema)
  "Add Query, Mutation, Subscription args."
  (let ((query (company-graphql--schema-add-arg-detail schema "Query"))
	(mutation (company-graphql--schema-add-arg-detail schema "Mutation"))
	(subscription (company-graphql--schema-add-arg-detail schema "Subscription"))
	(types (gethash "types" schema)))
    (when query
      (mapcar (lambda(x) (push x types)) query)
      (puthash "types" types schema))
    (when mutation
      (mapcar (lambda(x) (push x types)) mutation)
      (puthash "types" types schema))
    (when subscription
      (mapcar (lambda(x) (push x types)) subscription)
      (puthash "types" types schema))
    types
    )
  )

(defun company-graphql--schema-types ()
  "Parse GraphQL data.__schema.types JSON into hashtable"
  (or company-graphql-schema-types-cache
      (set 'company-graphql-schema-types-cache
	   (let* ((json-object-type 'hash-table)
		  (json-array-type 'list)
		  (json-key-type 'string)
		  (json (json-read-file company-graphql-schema-filename)))
	     (let* ((data (gethash "data" json))
		    (schema (gethash "__schema" data))
		    (types (gethash "types" schema))
		    (root (company-graphql--schema-add-root schema))
		    (args (company-graphql--schema-add-arg-list schema))
		    )
	       (push root types)
	       (mapcar (lambda (arg) (push arg types)) args)
	       types)))))

(defun company-graphql--path-head ()
  "Path root, query, mutation, subscription, where anynomous is query"
  (let ((op company-graphql-schema-root)
	(name nil)
	(begin (point))
	(end (point))
	(op-name "\\(query\\|mutation\\|subscription\\)[ \t\n\r]*\\([^ \t\n\r\(\{]+\\)?")
	(sub-string nil))
    (save-excursion
      (condition-case nil
	  (progn
	    (search-backward "}")
	    (forward-char)
	    (setq begin (point)))
	(error (progn (setq begin (point-min)))))
      (condition-case nil
	  (progn
	    (setq sub-string (buffer-substring-no-properties begin end))
	    (when (string-match op-name sub-string)
	      (setq op (match-string 1 sub-string))
	      (setq name (match-string 2 sub-string))))
	(error nil))
      )
    (list op name)))

(defun company-graphql--path-lexemify (long-string)
  "Lexemify sub-expression into partial grammar"
  (let ((sub-list
         (-remove
          (lambda (str) (s-blank? str))
          (-flatten
           (mapcar
            (lambda(x) (if (string-prefix-p "(" x) x (s-split " " (s-replace-all '((":" .  " : ") ("{" . " {")) x))))
            (mapcar
             's-trim
             (-flatten
              (mapcar
               (lambda (x) (s-slice-at "(" x))
               (mapcar
                's-trim
                (mapcar 'reverse (reverse (s-slice-at ")" (reverse long-string)))))))))))))
    (when (not (string-prefix-p "(" (nth 1 (reverse sub-list))))
      (setq sub-list (reverse (-insert-at 1 nil (reverse sub-list)))))
    sub-list))

(defun company-graphql--schema-hashtable (&optional root)
  "Get GraphQL schema fields hashtable."
  (company-graphql--schema-type-fields
   (company-graphql--schema-type
    (company-graphql--schema-types)
    (or root company-graphql-schema-root))))

(defun company-graphql--path-names ()
  "Get path names of query/mutation/subscription."
  (save-excursion
    (let ((lexems nil)
	  (sub-string nil)
	  (path '())
	  (last-points '())
	  (last-substrings '()))
      (and (not (looking-back ")[ \t\n\r]*"))
	   (condition-case nil
	       (while t
		 (backward-up-list)
		 (push (point) last-points))
	     (error (push (car (company-graphql--path-head)) last-substrings))))
      (while (> (cl-list-length last-points) 1)
	(setq sub-string (buffer-substring-no-properties (1+ (nth 0 last-points)) (1+ (nth 1 last-points))))
	(setq sub-string (replace-regexp-in-string "[ \n\t]+" " " sub-string))	
	(setq lexems (reverse (company-graphql--path-lexemify sub-string)))
	(when (nth 2 lexems)
	  (push (nth 2 lexems) last-substrings))
	(when (string= "(" (nth 0 lexems))
	  (push (company-graphql--schema-name-arg (nth 2 lexems)) last-substrings))
	(pop last-points))
      (setq last-substrings (reverse last-substrings))
      last-substrings)))

(defun company-graphql--path-get-type (name lookup)
  "Zip given name with its GraphQL type."
  (let* ((type (or (cdr (assoc name lookup))
		   (and (string-suffix-p company-graphql-schema-args name) name)))
	 (ans (cons name type)))
    (setq lookup (company-graphql--schema-hashtable type))
    (cons ans lookup)))

(defun company-graphql--path-types (&optional path-names)
  "Build name and type pair for a given path."
  (let ((table (company-graphql--schema-hashtable))
	(name-types '())
	(path (or path-names (company-graphql--path-names))))
    (mapcar
     (lambda(name)
       (let ((next (company-graphql--path-get-type name table)))
	 (setq table (cdr next))
	 (if (null table)
	     (cons (car (car next)) (car (car next)))
	   (car next))))
     path)))

(defun company-graphql--prefix ()
  "Company-GraphQL Prefix."
  (company-grab-symbol-cons "\\.\\|->" 1))

(defun company-graphql--annotation (candidate)
  "Company-GraphQL Annotation."
  (format " %s" (get-text-property 0 :annotation candidate)))

(defun company-graphql--meta (candidate)
  "Company-GraphQL Meta."
  ;; TBD
  (format "" (get-text-property 0 :meta candidate)))

(defun company-graphql--candidates (prefix)
  "Company-GraphQL Candidates"
  (let* ((text (substring-no-properties prefix))
	 (path (company-graphql--path-names))
	 (tail (cdr (car (reverse (company-graphql--path-types path)))))
	 (scope (if (string= company-graphql-schema-root (car path))
		    company-graphql-schema-root tail))
	 (fields (company-graphql--schema-hashtable scope))
	 (filtered (cl-remove-if-not
		    (lambda (item) (string-prefix-p text (car item)))
		    fields))
	 (answer (cl-mapcar (lambda (x) (car x)) filtered)))
    answer))

(defun company-graphql (command &optional arg &rest ignored)
  "Company-GraphQL entry command."
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend 'company-graphql))
    (prefix (company-graphql--prefix))
    (candidates (company-graphql--candidates arg))
    (annotation (company-graphql--annotation arg))
    (meta (company-graphql--meta arg))
    (ignore-case t)
    (no-cache t)))

(provide 'company-graphql)
;;; company-graphql.el ends here
