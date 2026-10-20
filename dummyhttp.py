#!/usr/bin/env python3
"""
Dummy HTTP server that serves fixed content for GET and HEAD.

Content (-c):
    FILE     serve the contents of FILE (buffered in memory at startup)
    -        serve stdin (buffered until EOF)
    (none)   serve 204 No Content
    A FILE that is /dev/null is treated the same as no -c: 204 No Content.

Listening (-l, required, repeatable):
    [host][:port][/path]
    port defaults to 8080. An empty host means all addresses
    (both :: and 0.0.0.0 when available). The optional /path is used
    both to infer a MIME type from its extension and, if present,
    as the target of 302 redirects: requests for any other path are
    redirected to /path (the query string is preserved).

    If port is 0 and a -l spec resolves to multiple bind addresses
    (wildcard host, or a hostname resolving to both ::1 and 127.0.0.1),
    the OS-assigned port from the first successful bind is reused for
    the others, so all of them share the same port.

MIME type:
    -M TYPE overrides auto-detection.  Otherwise the type is inferred
    from the /path suffix of -l, then from the extension of -c, then
    by sniffing the body (NUL byte -> application/octet-stream;
    valid UTF-8 -> text/plain).  text/* responses get
    "; charset=utf-8" when the body is valid UTF-8.

Methods:
    GET and HEAD are supported; anything else gets 405.
    A 204 response is served for every path (redirects are skipped).

Logging:
    -q suppresses the per-request access log.
    -v adds detail to stderr: at startup, per-listener MIME resolution
    (chosen type, charset and the reason for each); per request, the
    method, path, status, content-type, charset and body length.
"""

import argparse
import http.server
import mimetypes
import os
import socket
import socketserver
import sys
import threading


class DummyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    body = b''
    content_type = None
    base_content_type = None
    content_type_reason = None
    charset = None
    charset_reason = None
    redirect_path = None
    no_content = False
    quiet = False
    verbose = False

    def do_GET(self):
        self._serve(head=False)

    def do_HEAD(self):
        self._serve(head=True)

    def _unsupported(self):
        self.send_response(405)
        self.send_header('Allow', 'GET, HEAD')
        self.send_header('Content-Length', '0')
        self.end_headers()
        self._vlog(f'{self.command} {self.path} -> 405 (allowed: GET, HEAD)')

    do_POST = do_PUT = do_DELETE = do_OPTIONS = _unsupported
    do_PATCH = do_TRACE = do_CONNECT = _unsupported

    def _vlog(self, msg):
        if self.verbose:
            sys.stderr.write(f'[verbose] {msg}\n')
            sys.stderr.flush()

    def _serve(self, head):
        raw = self.path
        if '?' in raw:
            req_path, _, query = raw.partition('?')
        else:
            req_path = raw
            query = ''

        if self.no_content:
            self.send_response(204)
            self.end_headers()
            self._vlog(f'{self.command} {req_path} -> 204 (no content)')
            return

        if self.redirect_path is not None and req_path != self.redirect_path:
            target = self.redirect_path
            if query:
                target += '?' + query
            self.send_response(302)
            self.send_header('Location', target)
            self.send_header('Content-Length', '0')
            self.end_headers()
            self._vlog(f'{self.command} {req_path} -> 302 | Location: {target}')
            return

        self.send_response(200)
        if self.content_type:
            self.send_header('Content-Type', self.content_type)
        self.send_header('Content-Length', str(len(self.body)))
        self.end_headers()
        if not head:
            self.wfile.write(self.body)

        if self.verbose:
            parts = []
            if self.base_content_type:
                parts.append(f'content-type: {self.base_content_type} '
                             f'({self.content_type_reason})')
            else:
                parts.append('content-type: (none)')
            if self.charset_reason:
                parts.append(f'charset: {self.charset} '
                             f'({self.charset_reason})')
            parts.append(f'length: {len(self.body)}')
            self._vlog(f'{self.command} {req_path} -> 200 | '
                       + ' | '.join(parts))

    def log_message(self, fmt, *args):
        if self.quiet:
            return
        super().log_message(fmt, *args)


class _ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class Server4(_ThreadingServer):
    address_family = socket.AF_INET


class Server6(_ThreadingServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def _is_dev_null(path):
    try:
        st = os.stat(path)
        null = os.stat(os.devnull)
    except OSError:
        return False
    return (st.st_dev, st.st_ino) == (null.st_dev, null.st_ino)


def get_content(cpath):
    """Return (body, mime_path); body is None for 204 mode."""
    if cpath is None:
        return None, None
    if cpath == '-':
        return sys.stdin.buffer.read(), None
    if _is_dev_null(cpath):
        return None, None
    with open(cpath, 'rb') as f:
        return f.read(), cpath


def _guess_with_encoding(path):
    t, enc = mimetypes.guess_type(path)
    if enc:
        for ext, e in mimetypes.encodings_map.items():
            if e == enc:
                alt = mimetypes.types_map.get(ext)
                if alt:
                    return alt
                break
    return t or None


def _split_charset(ctype):
    """Split 'text/html; charset=utf-8' -> ('text/html', 'utf-8')."""
    if not ctype:
        return ctype, None
    parts = [p.strip() for p in ctype.split(';')]
    charset = None
    keep = [parts[0]]
    for p in parts[1:]:
        if p.lower().startswith('charset='):
            if charset is None:
                charset = p.split('=', 1)[1].strip()
        else:
            keep.append(p)
    return '; '.join(keep), charset


def _auto_charset(ctype, body):
    """Return (charset_or_None, reason_or_None)."""
    if not ctype.lower().startswith('text/'):
        return None, None
    try:
        body.decode('utf-8')
    except UnicodeDecodeError:
        return None, 'omitted (body is not valid UTF-8)'
    return 'utf-8', 'body is valid UTF-8'


def resolve_mime(listen_path, content_path, body, override):
    """Return (base_ctype, ctype_reason, charset, charset_reason)."""
    if override is not None:
        base, explicit_cs = _split_charset(override)
        if explicit_cs:
            return base, 'override (-M)', explicit_cs, 'explicit in -M'
        cs, cs_reason = _auto_charset(base, body)
        return base, 'override (-M)', cs, cs_reason

    ctype = None
    ctype_reason = None
    if listen_path:
        t = _guess_with_encoding(listen_path)
        if t:
            ctype = t
            ctype_reason = f'from -l path {listen_path!r}'
    if ctype is None and content_path:
        t = _guess_with_encoding(content_path)
        if t:
            ctype = t
            ctype_reason = f'from -c path {content_path!r}'
    if ctype is None:
        if b'\x00' in body:
            ctype = 'application/octet-stream'
            ctype_reason = 'sniffed: contains NUL byte'
        else:
            try:
                body.decode('utf-8')
                ctype = 'text/plain'
                ctype_reason = 'sniffed: valid UTF-8'
            except UnicodeDecodeError:
                ctype = 'application/octet-stream'
                ctype_reason = 'sniffed: not valid UTF-8'

    cs, cs_reason = _auto_charset(ctype, body)
    return ctype, ctype_reason, cs, cs_reason


DEFAULT_PORT = 8080


def _parse_port(s, spec):
    if s == '':
        return DEFAULT_PORT
    if not s.isdigit():
        raise ValueError(f"invalid port {s!r} in -l {spec!r}")
    p = int(s)
    if p > 65535:
        raise ValueError(f"port out of range in -l {spec!r}")
    return p


def parse_listen(spec):
    """Parse '[host][:port][/path]' -> (host, port, path_or_None)."""
    if spec == '':
        raise ValueError("-l value cannot be empty")

    if '/' in spec:
        i = spec.index('/')
        path = spec[i:]
        hostport = spec[:i]
    else:
        path = None
        hostport = spec

    if hostport.startswith('['):
        end = hostport.find(']')
        if end < 0:
            raise ValueError(f"unterminated '[' in -l {spec!r}")
        host = hostport[1:end]
        rest = hostport[end + 1:]
        if rest == '':
            port = DEFAULT_PORT
        elif rest.startswith(':'):
            port = _parse_port(rest[1:], spec)
        else:
            raise ValueError(f"unexpected {rest!r} after ']' in -l {spec!r}")
    elif ':' in hostport:
        host, _, pstr = hostport.partition(':')
        port = _parse_port(pstr, spec)
    elif hostport.isdigit():
        host = ''
        port = _parse_port(hostport, spec)
    elif hostport == '':
        host = ''
        port = DEFAULT_PORT
    else:
        host = hostport
        port = DEFAULT_PORT

    return host, port, path


def resolve_bind_targets(host, port, ipv4_only, ipv6_only):
    """Return list of (bind_host, family). Port coordination is caller's job."""
    if host == '':
        if ipv4_only:
            return [('0.0.0.0', socket.AF_INET)]
        if ipv6_only:
            return [('::', socket.AF_INET6)]
        return [('::', socket.AF_INET6), ('0.0.0.0', socket.AF_INET)]

    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as e:
        raise ValueError(f"cannot resolve {host!r}: {e}") from e

    out = []
    seen = set()
    for fam, _, _, _, sa in infos:
        if fam not in (socket.AF_INET, socket.AF_INET6):
            continue
        if fam in seen:
            continue
        seen.add(fam)
        out.append((sa[0], fam))
    if not out:
        raise ValueError(f"no usable address for {host!r}")
    return out


def format_addr(host, port):
    if ':' in host:
        return f'[{host}]:{port}'
    return f'{host}:{port}'


def create_server(bind_host, family, bind_port, config):
    handler_cls = type('BoundHandler', (DummyHandler,), config)
    server_cls = Server6 if family == socket.AF_INET6 else Server4
    return server_cls((bind_host, bind_port), handler_cls)


def log_listener(srv):
    handler = srv.RequestHandlerClass
    host, port = srv.server_address[:2]
    print(f"listening on {format_addr(host, port)}", file=sys.stderr)
    if not handler.verbose:
        return
    if handler.no_content:
        print("[verbose]   no content (204)", file=sys.stderr)
        return
    bits = []
    if handler.base_content_type:
        bits.append(f"content-type: {handler.base_content_type} "
                    f"({handler.content_type_reason})")
    else:
        bits.append("content-type: (none)")
    if handler.charset_reason:
        bits.append(f"charset: {handler.charset} ({handler.charset_reason})")
    bits.append(f"content-length: {len(handler.body)}")
    if handler.redirect_path is not None:
        bits.append(f"redirect: {handler.redirect_path}")
    print("[verbose]   " + " | ".join(bits), file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
    )
    parser.add_argument('-c', metavar='FILE', action='append', default=None,
                        help="content to serve: FILE, or '-' for stdin; "
                             "if omitted (or FILE is /dev/null) serve 204. "
                             "Repeatable; the last one wins.")
    parser.add_argument('-l', metavar='ADDR', action='append', required=True,
                        help="listen address: [host][:port][/path] "
                             "(port defaults to 8080). Repeatable.")
    parser.add_argument('-M', metavar='TYPE', default=None,
                        help="MIME type override (default: auto).")
    parser.add_argument('-4', dest='ipv4', action='store_true',
                        help="restrict default listeners to IPv4")
    parser.add_argument('-6', dest='ipv6', action='store_true',
                        help="restrict default listeners to IPv6")
    parser.add_argument('-q', '--quiet', action='store_true',
                        help="suppress per-request access log")
    parser.add_argument('-v', '--verbose', action='store_true',
                        help="log MIME resolution and request detail to stderr")

    args = parser.parse_args(argv)

    if args.ipv4 and args.ipv6:
        parser.error("-4 and -6 are mutually exclusive")

    cpath = args.c[-1] if args.c else None
    try:
        body, mime_path = get_content(cpath)
    except OSError as e:
        print(f"error: cannot read content: {e}", file=sys.stderr)
        return 1

    no_content = body is None
    if no_content:
        body = b''

    servers = []
    warnings = []

    for spec in args.l:
        try:
            host, port, path = parse_listen(spec)
            targets = resolve_bind_targets(host, port, args.ipv4, args.ipv6)
        except ValueError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2

        if no_content:
            base_ct, ct_reason, cs, cs_reason = None, None, None, None
            wire_ct = None
        else:
            base_ct, ct_reason, cs, cs_reason = resolve_mime(
                path, mime_path, body, args.M)
            wire_ct = base_ct
            if cs:
                wire_ct = f'{base_ct}; charset={cs}'

        config = {
            'body': body,
            'content_type': wire_ct,
            'base_content_type': base_ct,
            'content_type_reason': ct_reason,
            'charset': cs,
            'charset_reason': cs_reason,
            'redirect_path': path,
            'no_content': no_content,
            'quiet': args.quiet,
            'verbose': args.verbose,
        }

        actual_port = port
        for bind_host, family in targets:
            try:
                srv = create_server(bind_host, family, actual_port, config)
            except OSError as e:
                warnings.append(
                    f"cannot bind {format_addr(bind_host, actual_port)}: {e}")
                continue
            if actual_port == 0:
                actual_port = srv.server_address[1]
            servers.append(srv)

    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)

    if not servers:
        print("error: no listeners could be created", file=sys.stderr)
        return 1

    for srv in servers:
        log_listener(srv)

    threads = []
    for srv in servers:
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        threads.append(t)

    try:
        threads[0].join()
    except KeyboardInterrupt:
        pass
    finally:
        for srv in servers:
            srv.shutdown()
        for t in threads:
            t.join(timeout=2)
        for srv in servers:
            srv.server_close()

    return 0


if __name__ == '__main__':
    sys.exit(main())
