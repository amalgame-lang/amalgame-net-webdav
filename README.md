# amalgame-net-webdav

A **WebDAV server** for the Amalgame / Mosaic stack — expose a filesystem
directory over HTTP/WebDAV (the Apache `mod_dav` slice). Mount it on a
Mosaic host or a `WebApp` route and a directory becomes a read/write
network drive: macOS Finder, Windows Explorer, GNOME Files, `cadaver`,
`rclone`, and `curl` can all browse and edit it.

```amalgame
import Amalgame.Net.WebDav

// serve /srv/share at the URL prefix /dav, with locking on
let dav = WebDav.New("/srv/share", "/dav").WithLocks()

// the handler is a pure HttpRequest -> HttpResponse function
let resp = dav.Dispatch(req)
```

`Dispatch` is a plain `HttpRequest -> HttpResponse`, so it drops onto
`MosaicServer.AddHandler(host, closure)` (a whole host as a DAV share) or
a `WebApp` catch-all route (`router.Add("PROPFIND", "/dav/*p", …)` etc.),
and it is unit-testable without opening a socket.

## What it does

| Verb | Behaviour |
|---|---|
| `OPTIONS`  | advertises `DAV: 1` (or `1, 2` with locks) + `Allow` |
| `PROPFIND` | `Depth: 0` (the resource) / `1` (a collection's children) → `207 Multi-Status` XML (displayname, resourcetype, getcontentlength, getcontenttype, getlastmodified) |
| `GET`      | file bytes (binary-safe — see below); a collection returns a plain-text child listing |
| `HEAD`     | headers only |
| `PUT`      | create / overwrite a file (`201` / `204`); `409` if the parent collection is missing |
| `DELETE`   | recursive delete (`204`) |
| `MKCOL`    | create a collection (`201`); `405` if it exists, `409` if the parent is missing |
| `COPY`     | file or whole tree, honours `Destination` + `Overwrite` (`201` / `204` / `412`) |
| `MOVE`     | rename, honours `Destination` + `Overwrite` |
| `LOCK` / `UNLOCK` | exclusive write locks (opt-in, `WithLocks()`) — Class 2 |
| `PROPPATCH` | `207` (property persistence is a tracked follow-up) |

## Security — wired in by default

- **No path traversal.** The served root is fixed by the operator and
  never derived from client input; the URL prefix is stripped and any
  `..` segment is rejected with `403` *before* a path touches the disk —
  a request can never escape the served root.
- **Read-only mode.** `.ReadOnly()` rejects every mutating verb (`PUT`,
  `DELETE`, `MKCOL`, `COPY`, `MOVE`, `PROPPATCH`, `LOCK`) with `403`.
- **Locks fail closed.** With `.WithLocks()`, mutating a locked resource
  without presenting its token in the `If:` header returns `423 Locked`.

## Binary-safety

- **GET** ships bytes straight off disk via net-http's File mode
  (`H1Conn_RespondFile`, explicit `Content-Length`) — PNG / PDF / WASM /
  anything with NUL bytes is served byte-for-byte.
- **PUT** writes the raw request body buffer (`BodyPtr` / `BodyLen`)
  verbatim, and **COPY** streams through libc — uploads and copies are
  not strlen-truncated.

## Builder API

```amalgame
WebDav.New(root: string, prefix: string) : WebDav
  .ReadOnly()        // reject all mutating verbs (default: writable)
  .WithLocks()       // enable Class 2 LOCK / UNLOCK + 423 enforcement
  .Dispatch(req: HttpRequest) : HttpResponse
```

## Dependencies

- `amalgame-net-http`      — `HttpRequest` / `HttpResponse`
- `amalgame-io-filesystem` — directory enumeration + recursive ops
- `amalgame-datetime`      — RFC 1123 `getlastmodified`

## Limitations (v0.1.0 — honest scope)

- **PROPFIND** returns a fixed, useful property set; an explicit `<prop>`
  request list isn't parsed (extra properties are tolerated by clients),
  and `Depth: infinity` is treated as `Depth: 1` (no deep walk).
- **PROPPATCH** does not persist dead properties yet — it answers `207`
  with `403 Forbidden` per property (spec-clean, not a silent lie).
- **Locks** are exclusive-write, in-memory (single process), and the
  `If:` header is matched by token substring (not the full RFC 4918
  tagged-list grammar). Lock timeout is advertised but not swept.
- **COPY** of a tree recreates files and their parent directories;
  empty sub-directories are not copied.
- `MOVE` is a `rename(2)` — cross-volume moves return `409`.

## Build & test

```bash
./tests/run_tests.sh        # 24 checks: every verb, traversal, RO, locks
```

The runner resolves sibling checkouts of `amalgame-net-http`,
`amalgame-tls`, `amalgame-async`, `amalgame-datetime`, and
`amalgame-io-filesystem` (or `$AMALGAME_*` overrides). Tests drive
`WebDav.Dispatch` against a real temp directory — no socket required.

## License

Apache-2.0.
