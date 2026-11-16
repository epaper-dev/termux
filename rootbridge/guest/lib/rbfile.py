#!/usr/bin/env python3
"""rbfile - edit the block of a text file that the installers mark with a BEGIN and an END line
("# >>> termux-rootbridge >>>" ... "# <<< termux-rootbridge <<<"), and leave everything outside of it alone.

  rbfile.py set   SRC OUT BEGIN END CONTENT_FILE   OUT = SRC with the block replaced by the content (at the end of the
                                                   file, after an empty line, if there is no block yet)
  rbfile.py drop  FILE BEGIN END                   remove the block from FILE (in place)
  rbfile.py other FILE BEGIN END REGEX             exit 0 if a line OUTSIDE the block matches REGEX (re.match), else 1

Used by install.sh, uninstall.sh and guest/install-guest.sh (~/.bashrc, ~/.tmux.conf, termux.properties).
Python >= 3.8, standard library only.
"""
import re
import sys


def outside(lines, begin, end):
    """The lines that are not part of the block (the marker lines belong to it). A block without an END line runs to
    the end of the file."""
    inside = False
    for line in lines:
        if line.strip() == begin:
            inside = True
        elif inside:
            if line.strip() == end:
                inside = False
        else:
            yield line


def drop_block(text, begin, end):
    return "\n".join(outside(text.split("\n"), begin, end)).rstrip("\n") + "\n"


def set_block(text, begin, end, content):
    body = "\n".join(outside(text.split("\n"), begin, end)).rstrip("\n")
    return (body + "\n\n" if body else "") + begin + "\n" + content.rstrip("\n") + "\n" + end + "\n"


def has_line_outside(text, begin, end, pattern):
    return any(re.match(pattern, line) for line in outside(text.split("\n"), begin, end))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def main(argv):
    try:
        command, args = argv[0], argv[1:]
        if command == "set" and len(args) == 5:
            src, out, begin, end, content_file = args
            write(out, set_block(read(src), begin, end, read(content_file)))
        elif command == "drop" and len(args) == 3:
            path, begin, end = args
            write(path, drop_block(read(path), begin, end))
        elif command == "other" and len(args) == 4:
            path, begin, end, pattern = args
            return 0 if has_line_outside(read(path), begin, end, pattern) else 1
        else:
            raise IndexError
    except IndexError:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
