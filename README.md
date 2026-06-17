# amalgame-net-webdav

A **WebDAV server** for the Amalgame / Mosaic stack — expose a filesystem
directory over HTTP/WebDAV (the Apache `mod_dav` slice). Mount it on a
Mosaic host or a `WebApp` route and a directory becomes a read/write
network drive: macOS Finder, Windows Explorer, GNOME Files, `cadaver`,
`rclone`, and `curl` can all browse and edit it.

```amalgame
import Amalgame.Net.WebDav
import Amalgame.Auth

// Single share: serve /srv/share at the URL prefix /dav, with locking.
// WebDav is auth-agnostic — gate it with amalgame-auth's BasicAuth.
let dav  = WebDav.New("/srv/share", "/dav").WithLocks()
let auth = BasicAuth.ForCredentials("Files", new Credentials().AddPassword("alice", "s3cret"))

let denied = auth.Reject(req)              // null = ok, else a 401
let resp   = (denied != null) ? denied : dav.Dispatch(req)

// Multi-user NAS: per-user /home + a common /shared, one login each.
let nas = WebDavNas.New("/srv/users", "/srv/shared", "/dav").WithLocks()
    .AddUser("alice", aliceScryptHash)     // hashes from config / KeePass
    .AddUser("bob",   bobScryptHash)
let resp2 = nas.Dispatch(req)              // authenticates + routes by user
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

## Multi-user NAS (`WebDavNas`)

`WebDavNas` turns one URL prefix into a small NAS: every request is
HTTP-Basic-authenticated against a user store, then routed to the
caller's **own** space or a **shared** space:

| URL | Maps to | Who |
|---|---|---|
| `/<prefix>/`        | a listing of `home` + `shared` | any authenticated user |
| `/<prefix>/home/…`  | `usersDir/<user>/…` | the authenticated user only (per-user isolation) |
| `/<prefix>/shared/…`| `sharedDir/…` | everyone |

```amalgame
let nas = WebDavNas.New("/srv/users", "/srv/shared", "/dav")
    .WithLocks()
    .Realm("Family NAS")
    .AddUser("alice", aliceScryptHash)   // crypto Password.Hash, from config/KeePass
    .AddUser("bob",   bobScryptHash)
let resp = nas.Dispatch(req)
```

Each space is a cached single-root `WebDav` engine, so locks persist and
every verb / binary-safety guarantee above applies. A user's `/home` dir
is created on first access. No valid login → `401`.

## Authentication

`WebDav` itself is **auth-agnostic**; authentication lives in the
dedicated [`amalgame-auth`](https://github.com/amalgame-lang/amalgame-auth)
package (so this package doesn't drag in the whole web framework).
`WebDavNas` uses it internally; for a single `WebDav` share, gate it
yourself:

```amalgame
import Amalgame.Auth

let auth = BasicAuth.ForCredentials("Files",
    new Credentials().AddPassword("alice", "s3cret")).WithAllowPrivate()

let denied = auth.Reject(req)          // null = ok, else a 401
if (denied != null) { return denied }
return dav.Dispatch(req)
```

HTTP Basic is the **WebDAV-native** scheme, so it works with essentially
every client — Android WebDAV apps (Solid Explorer, CX File Explorer,
FolderSync, RaiDrive, DavX5, …), macOS Finder, Windows Explorer,
`davfs2`, `rclone`, `curl -u`. `.WithAllowPrivate()` lets loopback/RFC1918
clients in without a password (trusted-LAN convenience).

> **Deploy behind TLS.** Basic sends the password base64-encoded, *not*
> encrypted. Terminate HTTPS at the Mosaic host (ACME/Let's Encrypt) so
> credentials and file contents are never sent in clear.

## Security — wired in by default

- **Auth (via amalgame-auth) fails closed** — no/invalid credentials →
  `401`, before any path handling (`WebDavNas`, or your `BasicAuth.Reject`).
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
  .ReadOnly()                    // reject all mutating verbs (default: writable)
  .WithLocks()                   // enable Class 2 LOCK / UNLOCK + 423 enforcement
  .Dispatch(req: HttpRequest) : HttpResponse        // auth-agnostic

WebDavNas.New(usersDir, sharedDir, prefix) : WebDavNas
  .ReadOnly() / .WithLocks() / .Realm(name)
  .AddUser(name, scryptHash)     // crypto Password.Hash; repeatable
  .Dispatch(req: HttpRequest) : HttpResponse        // authenticates + routes
```

## Dependencies

- `amalgame-net-http`      — `HttpRequest` / `HttpResponse`
- `amalgame-io-filesystem` — directory enumeration + recursive ops
- `amalgame-datetime`      — RFC 1123 `getlastmodified`
- `amalgame-auth`          — Basic auth + multi-user scrypt credentials

## Limitations (v0.3.0 — honest scope)

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
- **Auth** is HTTP Basic (via `amalgame-auth`): multi-user with scrypt
  hashes, but no Digest and no token/OIDC. For those, gate with a
  different middleware. Always run over TLS.

## Build & test

```bash
./tests/run_tests.sh        # 31 checks: every verb, traversal, RO, locks, NAS auth
```

The runner resolves sibling checkouts of `amalgame-net-http`,
`amalgame-tls`, `amalgame-async`, `amalgame-datetime`,
`amalgame-io-filesystem`, `amalgame-crypto`, and `amalgame-auth` (or
`$AMALGAME_*` overrides). Tests drive `WebDav.Dispatch` / `WebDavNas`
against a real temp directory — no socket required.

## License

Apache-2.0.
