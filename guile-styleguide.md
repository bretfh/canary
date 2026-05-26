# Guile style

Most of what follows is opinionated. Style is not science. The rules are the
author's, but the rationale is the part that matters; if you understand why a
rule exists, you can decide intelligently when to break it. A rule without
rationale is superstition.

## Principles

Three of them, in descending order of importance.

1. **A program describes an idea, not the mechanics of executing it.**
   The intent of the code should be on the page; how the machine
   actually carries it out should be peripheral. This is why we choose
   meaningful names, prefer composition over deep nesting, and explain
   the *why* of a non-obvious passage rather than the *what*.

2. **The sum of the parts is easier to understand than the whole.**
   Small definitions composed together fit in a human head; one large
   definition that does five things does not. Split things up. Give the
   parts names. Humans are good at local reasoning and bad at global
   reasoning; your code should play to that strength.

3. **Aesthetics matters.** Nobody enjoys reading ugly code. The reader
   is going to spend more time with the program than the writer did;
   their experience determines whether it gets maintained or rotted.
   Care about the typography.

These principles inform everything else here. When a rule looks arbitrary, check
it against the principles it almost always reduces to one of the three.

## Files

Every `.scm` file opens with a project header, copyright lines (one per
contributor, year-range collapsed), and the license boilerplate. Guix
uses three semicolons:

```scheme
```

Three semi colors for the same block.

Below the header and module declaration, mark the start of code with
Emacs Lisp-style markers:

```scheme
;;; Commentary:
;;;
;;; One paragraph describing what this module is for, who uses it,
;;; and any non-obvious invariants.
;;;
;;; Code:
```

The `Commentary:` block is where interface documentation belongs. A
reader who only wants to use the module should be able to read the top
of the file and be done; they shouldn't have to wade through the
implementation to discover what the module offers. Implementation
comments belong further down, near the code they explain.

Separate logical sections inside a file with a three-line banner:

```scheme

;;;
;;; Filtering & pipes.
;;;
```

Give every file a concise but descriptive title at the top, and keep
the file's contents related to that title. A file that grows to cover
two unrelated concerns is a file that wants to be split.

## Modules

One module per file. `(define-module (a b c))` lives at `a/b/c.scm`.
The module name matches the file path with no exceptions.

The standard shape of a `define-module` form:

```scheme
(define-module (guix packages)
  #:autoload   (guix build utils) (compressor tarball?)
  #:use-module (guix utils)
  #:use-module (guix records)
  #:use-module ((guix diagnostics)
                #:select (formatted-message define-with-syntax-properties))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9 gnu)
  #:re-export (%current-system
               %current-target-system)
  #:replace ((define-public* . define-public))
  #:export (content-hash
            content-hash?
            content-hash-algorithm
            …))
```

One `#:use-module` per line. Use `#:autoload` for modules touched in a
single code path; it keeps startup cheap. Use `#:select` to narrow the
imported surface, especially when names would otherwise collide. Use
`#:prefix foo:` when the imported module exports many names that would
clash, and reference them as `foo:bar`. Use `#:hide` to drop names that
conflict with Guile's core; Fibers' own `sleep` is the canonical
example. `#:renamer` exists for one-off rebindings, but try `#:select`
or `#:prefix` first. `#:re-export` is for facade modules that bundle a
public surface. `#:replace` is for shadowing core forms intentionally.

`#:export` goes last, one identifier per line. Group related
identifiers with a blank line. Trailing margin comments are fine:

```scheme
#:export (prepend                      ;syntactic keyword
          content-hash
          content-hash?)
```

The fewer modules a file depends on, the easier it is to understand in
isolation. If a module pulls in twenty others, the reader needs to know
twenty others before they can read the file. Minimise the imports.
When a module starts to depend on too much, that's a signal it wants to
be split. Write a facade that re-exports the pieces if the public
surface needs to stay the same.

### Module name spaces

From the Guix manual:

- `(guix …)`: core library, host-side. Must not depend on `(gnu …)`.
- `(guix build …)`: build-side. May not refer to other host-side
  Guix or GNU modules (different runtime environment).
- `(gnu …)`: broader-distro layer; may use `(guix …)`.

Mirror this for your own projects: a `<project>` namespace for the
core library, `<project>/build` for build-side or sandboxed code,
`<project>/scripts` for CLI entry points.

### Cyclic dependencies

Guile tolerates module cycles, but they break compilation order and
make modules impossible to load in isolation. Don't introduce a cycle;
if you must, document it inline at both ends. See *Cyclic Module
Dependencies* in `contributing.texi`.

## Names

Naming is simultaneously trivial and supremely important. Trivial
because a thing is unaffected by what we call it; important because the
name is what the reader sees, and the reader's understanding is what
the program is for. A full discussion would fill a library. The rules
below distil what's actionable.

Symbolic names are English words separated by hyphens. Scheme folds
the case of names, so camelCase looks ridiculous; it's also ugly.
Underscores are unacceptable except for names borrowed directly from a
foreign language without translation.

| Kind              | Form                                          |
|-------------------|-----------------------------------------------|
| Procedure         | `lower-kebab-case`                            |
| Predicate         | `name?`                                       |
| Mutator           | `name!`                                       |
| Accessor          | `<type>-<field>` (no `get-` prefix)           |
| Record type       | `<angle-brackets>`                            |
| Constructor       | `make-<type>` or a custom name (`origin`)     |
| Internal/private  | `%name` (leading percent)                     |
| Parameter (fluid) | `%name` or `%current-thing`                   |
| Condition type    | `&name-error` (SRFI-35)                       |
| Condition pred    | `name-error?`                                 |
| Condition field   | `name-error-<field>`                          |
| Conversion        | `from->to` (e.g. `bytevector->string`)        |

A `?` at the end of a procedure name means it returns a boolean and
exists to answer a question. Don't use `?` for a procedure that returns
arbitrary data; readers rely on the suffix to know whether they can use
the result as a test. Read `(pair? object)` aloud as "pair-pee
object"; the `?` is part of the name.

A `!` at the end of a procedure name means destructive update is its
primary purpose. Don't sprinkle `!` on every procedure that has a side
effect; reserve it for procedures that exist *solely* to mutate
(`set-car!`), or to distinguish a mutating variant from a functional
one of the same name (`append!` vs. `append`). Read `(set-car! pair x)`
aloud as "set-car-bang pair x."

`%name` is the Guile/Guix convention for things that aren't part of a
module's public surface: internal helpers, fluid parameters, mutable
globals. Don't use Common Lisp's `*name*` convention for parameters in
Guile code; that's the wrong language's idiom and only confuses
readers familiar with Guix.

`with-foo` is the prefix for any procedure that establishes some
dynamic state and calls a thunk inside it, restoring the state after.
The thunk is the last (and usually only) argument:
`with-output-to-string`, `with-error-to-port`, `with-input-from-file`.
`call-with-foo` is the prefix for any procedure that calls a procedure
with one or more explicit arguments, most commonly a resource the
procedure cleans up after: `call-with-input-file`,
`call-with-output-string`, `call-with-values`. The distinction matters
because the reader infers behaviour from the prefix: a `with-` form
binds dynamic state and takes a thunk; a `call-with-` form provides a
resource and takes a procedure of known arity.

### What not to do

Don't abbreviate. Abbreviating doesn't shorten the concept, only the
screen real estate. The reader still has to decode `frb-desc-rec-subex`
in their head, and they have less to go on. SchMUSE's
`frisk-descriptor-recursive-subexpr-descender-for-frisk-descr-env`
is the cautionary tale: long *and* impenetrable, with abbreviations
inserted halfway through as the author lost patience with themselves.

Don't use single-letter names except in scopes so small the meaning is
obvious. `i` in a tight loop over a vector is fine. `a` and `d` for
the car and cdr of a pair, used immediately, is fine. The moment a
single-letter name escapes the line it was defined on, give it a real
name.

Don't use functional combinators or the point-free style. `(compose foo
(project 2 bar))` is shorter than `(lambda (a b) (foo (bar b)))` by
about three characters and longer by an order of magnitude in cognitive
load: the reader now has to find the definitions of `foo`, `bar`,
`project`, and `compose`, and reconstruct the call graph in their head,
to learn what the explicit form spells out directly. The exception is
where composition is the *point*: a symbolic differentiator, an
algebraic library. Anywhere else, write the lambda.

Don't call ignored parameters `_` or `ignored`. Give them a meaningful
name and an `;ignore` margin comment. A future maintainer reading the
procedure should be able to see what arguments are available without
grepping for call sites:

```scheme
(define (foo x y z)
  x z                           ;ignore
  (frobnitz y))
```

Don't prefix top-level bindings with their module name (`foo:bar` for
`bar` exported by module `foo`). Guile has a module system; let it do
the disambiguation. The prefix-in-the-name approach only works until
two modules pick the same prefix, which is when you're back to needing
a module system anyway.

## Data

### Records

Three record-type constructors, picked by need:

- **`define-record-type`** (SRFI-9): plain data, no defaults.
- **`define-immutable-record-type`** (SRFI-9 gnu): when no field
  should ever be mutated; gives functional-update setters.
- **`define-record-type*`** (`(guix records)`): when you need field
  defaults, sanitizers, `delayed` or `thunked` fields, ABI checking,
  or a smart constructor usable like a literal:

  ```scheme
  (origin
    (uri "https://…")
    (method url-fetch)
    (hash  (content-hash "…" sha256)))
  ```

Keep the record type descriptor private. Export the predicate, the
constructor, and the field accessors. Never export the RTD itself.
Exposing it lets callers match by field position, which pins your field
order as part of the ABI; it also lets them forge values that skipped
your sanitizers. The RTD is an implementation detail; treat it that
way.

Customize printing with `(set-record-type-printer! <type> proc)` so
the REPL shows something meaningful when a record turns up in a
backtrace.

### Pattern matching

Use `(ice-9 match)` for destructuring lists and records. Reach for
`car`/`cdr`/`cadr` only when the locality is so tight the chain is
unambiguous; past two levels of `cadr` the reader is counting commas in
their head.

For records, prefer `match-record` from `(guix records)` over plain
`match`. `match-record` verifies the field names at expansion time, so
typos surface at compile time rather than as runtime "match failed":

```scheme
(match-record origin <origin> (uri method hash)
  (do-something uri method hash))
```

## Procedures

### Docstrings

Every top-level procedure carries a docstring. This is a hard rule.

A docstring is a string literal placed immediately after the formals;
it becomes part of the procedure object. It's retrievable at runtime
via `procedure-documentation`, surfaced in the REPL by `,d`, and used
by editor tooling. It is *not* a comment, and a comment is not a
substitute for it. The docstring is data the program ships with;
treat it that way.

Capitalise the first word. Refer to parameters in `UPPERCASE`. Write
full sentences ending in periods. Document the return value when it
isn't obvious from the name. For destructive procedures, say so.

```scheme
(define* (package-full-name package #:optional (delimiter "@"))
  "Return the full name of PACKAGE--i.e., `NAME@VERSION'.  By specifying
DELIMITER (a string), you can customize what will appear between the
name and the version.  By default, DELIMITER is \"@\"."
  …)
```

### Arity

Use at most four positional parameters. Past four, switch to `define*`
with `#:key` arguments. The reason is that a procedure call with five
positional arguments stops looking like a procedure call and starts
looking like a data structure; the reader has to count argument
positions instead of reading names.

Use `#:optional` for one or two trailing optionals; otherwise `#:key`.
Default values go inline: `#:optional (delimiter "@")`,
`#:key (system (%current-system))`.

### Internal definitions

Inside a procedure, prefer `define` over `let` for helpers, so the body
reads top-down:

```scheme
(define (origin-actual-file-name origin)
  "Return the file name of ORIGIN, …"
  (define (uri->file-name uri) …)
  (or (origin-file-name origin)
      (match (origin-uri origin) …)))
```

A nested `let` chain that introduces five bindings before doing
anything reads as a wall; sequenced internal `define`s read like a
small module.

## Errors

Three layers, cheapest to most structured. Pick the lowest tier that
distinguishes the error the way callers need it distinguished.

1. **`(error "message" datum ...)`**: internal invariants and places
   the user shouldn't reach. Cheap, untyped, prints a message.
2. **`(raise (formatted-message (G_ "…") arg …))`**: user-facing
   error with i18n. Lives in `(guix diagnostics)`.
3. **SRFI-35 condition types**: typed errors callers must
   distinguish programmatically.

```scheme
(define-condition-type &package-error &error
  package-error?
  (package package-error-package))

(define-condition-type &package-input-error &package-error
  package-input-error?
  (input package-error-invalid-input))
```

Catch with SRFI-34 `guard`:

```scheme
(guard (c ((package-license-error? c)
           (package-error-invalid-license c)))
  (do-thing))
```

Don't return `#f` to signal an error the caller is supposed to
distinguish from a successful but absent result. Doing so overloads the
boolean channel, and every caller now has to disambiguate "not found"
from "broken" out-of-band. Either return a typed result or raise.

## Macros

Choose the lowest tier that does the job:

- **`define-syntax-rule`**: one-clause hygienic macros.
- **`syntax-rules`**: multi-clause hygienic macros.
- **`syntax-case`**: when you need source-location preservation,
  fenders, or to inspect the literal syntax. Guix uses `syntax-case`
  for `define-record-type*` and `content-hash`.

Wrap definitions needed at expansion time in
`(eval-when (expand load eval) …)`. When emitting an error during
expansion, use `syntax-violation` so the user sees a sensible source
location instead of a stripped-down "syntax error."

Prefer a procedure over a macro unless you genuinely need syntactic
abstraction: binding constructs, control flow, custom evaluation
order, or an embedded DSL. A procedure can be passed as an argument,
composed, redefined at the REPL, traced, and tested in isolation. A
macro can do none of these. The cost of a macro is paid every time a
reader has to model the expansion in their head; charge it only when
you're buying something a procedure can't give you.

## Formatting

### Indentation

Standard Lisp two-space body indent. The leading-argument rules below
are the ones that aren't obvious; they come from
`guix/read-print.scm`'s `%special-forms` table.

| Form                       | Lead args |
|----------------------------|-----------|
| `define`, `define*`, `define-public` | 2 |
| `define-syntax`, `define-syntax-rule` | 2 |
| `define-module`, `define-record-type` | 2 |
| `define-record-type*`      | 4 |
| `let`, `let*`, `letrec`, `letrec*` | 2 |
| `lambda`, `lambda*`        | 2 |
| `match`, `match-lambda`, `match-lambda*` | 2/1/1 |
| `match-record`             | 3 |
| `when`, `unless`           | 2 |
| `package`, `origin`, `channel` | 1 |
| `modify-inputs`, `modify-phases`, `modify-services` | 2 |
| `add-after`, `add-before` (inside `modify-phases`) | 3 |
| `replace` (inside `modify-phases`) | 2 |
| `parameterize`             | 2 |
| `substitute*`              | 2 |
| `call-with-input-file`, `with-output-to-file`, etc. | 2 |
| `with-directory-excursion` | 1 |

When you introduce a new special form, register it in `.dir-locals.el`
and any other editor configuration you ship; otherwise the next reader
gets bad indentation, and bad indentation hides structure.

### Alignment

When the second subform of a call sits on the same line as the first,
align the rest of the subforms with the second:

```scheme
(+ (sqrt -1)
   (* x y)
   (+ p q))
```

When the second subform sits on the line below, align all subforms
with the first:

```scheme
(+
 (sqrt -1)
 (* x y)
 (+ p q))
```

Columnar alignment lets a reader scan operands by following a vertical
line. Misaligned indentation obscures structure and forces the reader
to count parens to figure out what's an operand of what.

### Parentheses

Closing parens stack at the end of the last line of the form. Never
put `)` on its own line.

```scheme
(define (factorial x)
  (if (< x 2)
      1
      (* x (factorial (- x 1)))))
```

Not:

```scheme
(define (factorial x)
  (if (< x 2)
      1
      (* x (factorial (- x 1
                      )
           )
      )
  )
)
```

A Lisp programmer reads structure, not brackets. The parentheses are
lexical tokens; placing them prominently on their own lines is jarring
in the same way that capitalising every noun in English prose would
be: the eye snags on the typography instead of following the meaning.
"The parentheses grow lonely if their closing brackets are all kept
separated and segregated," in Riastradh's phrasing.

The exception is large literal data lists under version control, where
breaking after the opening paren and before the closing paren makes
diffs cleaner:

```scheme
(define colour-names
  '(
    blue
    cerulean
    green
    magenta
    purple
    red
    scarlet
    turquoise
    ))
```

That's the only exception. Code never gets this treatment.

### Round and square brackets

Some Scheme implementations let you use `[ ]` interchangeably with
`( )`. Don't. The square-bracket extension is non-standard, so it's
non-portable; it draws the reader's attention to the lexical tokens
instead of the structure; and the conventions for *when* to use square
brackets are inconsistent across the projects that allow it. The
distinction `(let ([x 5]) …)` versus `(let ((x 5)) …)` is a difference
without a difference: a syntactic distinction that expresses no
semantic distinction. Skip it.

### Long lists

Lists longer than five elements break to one element per line. Short
lists may stay on one line. The pretty-printer in `(guix read-print)`
uses `long-list 5` as its threshold.

### Whitespace

One blank line between top-level forms. Multiple blank lines collapse
to one (`guix style` enforces this). One trailing newline at end of
file. Don't put blank lines inside a procedure body except to separate
internal `define`s; if a procedure feels like it wants blank lines for
"sections," it wants to be split into smaller procedures instead.

## Comments

Comments aren't docstrings. The rules for docstrings are above and are
unaffected by anything in this section.

Default to no comment. Reach for one only when the *why* is non-obvious
and the code can't express it: a hidden constraint, a workaround for a
specific bug, an invariant that doesn't show up in the types. Don't
restate what the code does. Don't reference PR numbers, ticket IDs, or
"used by X"; both rot the moment the code is touched.

If the code is so often incapable of explaining itself that comments
are everywhere, the language being used to write it is too
inexpressive. Build a combinator. Define a macro. Name the intermediate
value. Literate programming is the logical conclusion of
inexpressiveness: a direct concession that the only way for a human
to understand the program is to have it rewritten in human language.
Don't pursue that conclusion; expand the program's vocabulary instead.

Semicolon count carries meaning. Four levels, each with its use:

- `;`: *margin comment*, same line as code, single leading space.
- `;;`: *line comment*, on its own line, aligned with the code it
  annotates. Comments out a block, or annotates a line that needs more
  than a margin allows.
- `;;;`: *section or header*, used in file headers and banner
  separators.
- `;;;;`: *chapter heading*, rare; reserved for the largest groupings
  inside a long file.

Only margin comments may omit the space after the semicolon.

Translator hints to xgettext go on a `;; TRANSLATORS: …` line
immediately above the string they explain. Use S-expression comments
(`#;`) to comment out whole expressions when your editor supports them;
fall back to line comments when it doesn't.

## Synopses and descriptions

For packages or any other place where a user sees a one-line summary
followed by a paragraph:

The **synopsis** starts with a capital letter, has no terminating
period, no leading "a" or "the." It says what the thing *is* or
*does*. Make it meaningful to a wide audience: not "Manipulate
alignments in the SAM format" but "Manipulate nucleotide sequence
alignments."

The **description** is five to ten lines of full sentences. No
marketing copy. "Industrial-strength," "next-generation,"
"world-leading," "robust," and the rest of the genre are forbidden;
they communicate nothing and waste the reader's attention. Plain
factual statements with use cases. Texinfo markup is fine: `@code{}`,
`@dfn{}`, bullets, hyperlinks.

Synopses and descriptions must be literal strings (no
`string-append`, no `format`) so xgettext can extract them for
translation.

## Tests

SRFI-64. One test file per module, under `tests/`, with its own
`(define-module (tests <area>))`:

```scheme
(define-module (tests packages)
  #:use-module (guix tests)
  #:use-module (guix packages)
  #:use-module (srfi srfi-64)
  …)

(test-begin "packages")

(test-equal "license type checking"
  'bad-license
  (guard (c ((package-license-error? c)
             (package-error-invalid-license c)))
    (dummy-package "foo" (license 'bad-license))))

(test-assert "hidden-package"
  (and (hidden-package? (hidden-package (dummy-package "foo")))
       (not (hidden-package? (dummy-package "foo")))))

(test-end "packages")

;;; Local Variables:
;;; eval: (put 'dummy-package 'scheme-indent-function 1)
;;; End:
```

Test name strings describe the *behaviour*, not the API. When a test
fails, the report should tell you what broke ("license type
checking"), not which procedure was called. The procedure name lives
in the source; the test name is for the failure report.

One assertion per behaviour. Related assertions group together. A
file-local `Local Variables:` block at end-of-file is appropriate when
the tests use custom forms that need custom indentation.

## Commit messages

Guix uses the ChangeLog format. Its commit-msg hook installs a
`Change-Id` trailer for traceability; preserve the trailer across
rebases.

Subject, capped at about seventy-two characters:

```
gnu: wesnoth: Update to 1.19.18.
```

The pattern is `area: subject: Summary.`: capitalised summary,
period-terminated. For library code:

```
guix: packages: Allow origins with delayed patches.
```

The body is ChangeLog entries, one per file or identifier touched:

```
* gnu/packages/games.scm (wesnoth): Update to 1.19.18.

Change-Id: I1353f7a425a0ca84b2e76b24cf10ab20f232450a
Signed-off-by: …
```

One coherent change per commit. Don't bundle a package update with a
fix to that package. The fix and the update have different
justifications, and bisecting will appreciate having them separate.
Use singular "they" in commit prose anywhere a pronoun is needed.
Sign off when contributing upstream. Don't `--amend`-then-resend; use
`git send-email -vREVISION` so reviewers can see what changed.

The ChangeLog format is the Guix idiom. Projects outside Guix should
still pick a single commit-message format and hold to it; the failure
mode is mixed styles, not the wrong style.

## Tooling

- **`guix style PACKAGE`**: auto-format. Runs the pretty-printer in
  `(guix read-print)` with the rules above.
- **`guix lint PACKAGE`**: catches synopsis/description issues,
  unused imports, broken inputs.
- **`guild compile foo.scm`**: compile-time warnings, especially for
  undefined references and arity mismatches.
- **`.dir-locals.el`**: ship one. Set `indent-tabs-mode nil` and
  whatever `scheme-indent-function` properties your special forms
  need. Without this, every contributor's editor produces a different
  diff.

## Defaults you can paste in

`.dir-locals.el`:

```elisp
((scheme-mode
  . ((indent-tabs-mode . nil)
     (eval . (put 'your-special-form 'scheme-indent-function 1)))))
```

Module skeleton:

```scheme
;;; <project> --- <tag line>
;;; Copyright © <year> <you> <<email>>
;;;
;;; <license header>

(define-module (<project> <area>)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:export (foo
            foo?
            foo-bar))

;;; Commentary:
;;;
;;; <what this module is for>.
;;;
;;; Code:

(define-record-type <foo>
  (make-foo bar)
  foo?
  (bar foo-bar))

(define (foo bar)
  "Return a new <foo> wrapping BAR."
  (make-foo bar))
```

## Attribution

Riastradh's *Lisp Style Rules* (Taylor R. Campbell, 2007-2011) supplied
the philosophy, the predicate/mutator/with/call-with conventions, the
naming polemic, and the anti-square-bracket and anti-point-free
positions. Used here under CC BY-NC-SA 3.0. The Guile/Guix-specific
rules, module shape, record-type tiers, error layering, macro tiers,
the ChangeLog commit format, and the tooling, all come from the Guix
source tree, Shepherd, and the GNU Coding Standards.
