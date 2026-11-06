#!/usr/bin/env python3
# =============================================================================
# chunk_runbooks.py  (run by 03_load_runbooks.sh)
#
# Splits every runbook (runbooks/*.md) into chunks, one per "## " section,
# and prints the SQL that loads them into RUNBOOK_CHUNKS. Each chunk is one
# line and starts with its runbook's title and section, so it still makes
# sense on its own: the search returns chunks, not whole runbooks.
#
# Deterministic: files in name order, sections in file order, no randomness.
# Plain Python, no extra packages. Changes nothing itself.
# =============================================================================

# argparse: options. pathlib: the runbook files. sys: exit codes.
import argparse
import pathlib
import sys

# Characters that can delimit an Oracle q-quoted literal (q'~...~'); the first
# one not followed by "'" in the text is used, so no escaping is ever needed.
QUOTE_CHARS = "~^!#%"
# A chunk must fit a VARCHAR2(4000) column, with room to spare.
MAX_BYTES = 3500


def q_literal(text: str) -> str:
    """The text as an Oracle q-quoted literal."""
    for c in QUOTE_CHARS:
        if f"{c}'" not in text:
            return f"q'{c}{text}{c}'"
    sys.exit("ERROR: no usable quote character for a chunk")


def chunks(path: pathlib.Path) -> list[tuple[str, str]]:
    """(section heading, chunk text) for each '## ' section of one runbook."""
    lines = path.read_text(encoding="utf-8").splitlines()
    # The runbook's title: its first "# " line.
    title = next((l[2:].strip() for l in lines if l.startswith("# ")), path.stem)
    out, heading, body = [], None, []
    for line in lines + ["## "]:
        if line.startswith("## "):
            # A section ends where the next one starts (the sentinel closes the last).
            if heading is not None:
                # One line: "<title> - <heading>: <the section's text>". A single
                # line can't be cut short by SQL*Plus (a blank line ends a statement
                # there, a line starting with "#" is read as a command).
                text = f"{title} - {heading}: " + " ".join(l.strip() for l in body if l.strip())
                if len(text.encode("utf-8")) > MAX_BYTES:
                    sys.exit(f"ERROR: {path.name}, section '{heading}' is longer than {MAX_BYTES} bytes")
                out.append((heading, text))
            heading, body = line[3:].strip(), []
        elif heading is not None:
            body.append(line)
    return out


def main() -> int:
    """Print the INSERT statements for every chunk of every runbook."""
    p = argparse.ArgumentParser(description="Chunk the runbooks and print the SQL that loads them.")
    p.add_argument("runbooks_dir")
    args = p.parse_args()
    files = sorted(pathlib.Path(args.runbooks_dir).glob("*.md"))
    if not files:
        sys.exit(f"ERROR: no runbooks in {args.runbooks_dir}")
    n = 0
    for f in files:
        for heading, text in chunks(f):
            # The chunk's id: its position, 1, 2, 3... (files in name order,
            # sections in file order), so it's the same on every load.
            n += 1
            line = (f"insert into runbook_chunks (id, runbook, section, chunk_text) values "
                    f"({n}, {q_literal(f.stem)}, {q_literal(heading)}, {q_literal(text)});")
            # SQL*Plus refuses input lines over 2,499 characters (SP2-0027).
            if len(line) > 2400:
                sys.exit(f"ERROR: {f.name}, section '{heading}': too long for one SQL*Plus line; split the section")
            print(line)
    print(f"prompt CHUNKS={n} RUNBOOKS={len(files)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
