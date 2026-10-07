"""Remove comments from Lua source without changing its tokens.

Strings (quoted and long-bracket) are copied verbatim; comments are dropped
but their newlines are kept, so line numbers in error messages still match the
full source. Trailing whitespace is removed. `keep_first_line` preserves a
leading declaration comment (the HD2-Addon line addon discovery reads).
"""
import re

_LONG = re.compile(r'\[(=*)\[')


def strip(text, keep_first_line=False):
    out = []
    i, n = 0, len(text)
    if keep_first_line:
        end = text.find('\n')
        end = n if end < 0 else end + 1
        out.append(text[:end])
        i = end
    while i < n:
        c = text[i]
        if c == '-' and text.startswith('--', i):
            m = _LONG.match(text, i + 2)
            if m:
                close = ']' + m.group(1) + ']'
                j = text.find(close, m.end())
                if j < 0:
                    raise ValueError('unterminated long comment at %d' % i)
                out.append('\n' * text.count('\n', i, j) or ' ')  # never glue two tokens
                i = j + len(close)
            else:
                j = text.find('\n', i)
                i = n if j < 0 else j
            continue
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c:
                if text[j] == '\\':
                    j += 1
                elif text[j] == '\n':
                    raise ValueError('unterminated string at %d' % i)
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
            continue
        if c == '[':
            m = _LONG.match(text, i)
            if m:
                close = ']' + m.group(1) + ']'
                j = text.find(close, m.end())
                if j < 0:
                    raise ValueError('unterminated long string at %d' % i)
                out.append(text[i:j + len(close)])
                i = j + len(close)
                continue
        out.append(c)
        i += 1
    return '\n'.join(line.rstrip() for line in ''.join(out).split('\n'))
