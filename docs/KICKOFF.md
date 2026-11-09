# localidraw — kick-off

A self-hostable, browser-based whiteboard in the spirit of Excalidraw: minimal UI, hotkeys for basic shapes, hand-drawn look, arrows that magnetically attach to shapes.

## Goals

- Simple interface, keyboard-first.
- Runs in the browser, hosted locally as a single binary.
- Starts single-user; Google OAuth is the target for sign-in.
- Later: multiple users editing the same scene concurrently.
- Background is always light (white).

## Features (v1 scope)

**Tools and hotkeys**

| Tool | Key |
|---|---|
| Hand (pan) | `H` (or hold `Space`) |
| Select | `V` |
| Rectangle | `R` |
| Diamond (romb) | `D` |
| Ellipse / circle | `O` |
| Arrow | `A` |
| Line | `L` |
| Text | `T` |
| Note | `N` |

**Style options**

- Color picker for stroke and background (preset swatches plus a hex input).
- Edges: sharp or rounded.
- Sloppiness: architect, artist, cartoonist.
- Stroke style: solid line, dashed, dotted.
- Fill: hachure, cross-hatch, solid.

**Arrangement**

- Align left/center/right/top/middle/bottom.
- Distribute horizontally/vertically.
- Snap guides while dragging (nice to have).

**Magnetic attach**

- Arrow endpoints bind to shapes and follow them when the shapes move or resize.

**Import / export**

- Scene as JSON (`.localidraw`): export and import.
- PNG export of the whole scene; later, of the selection only.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Frontend | TypeScript + Vite + Preact or React (UI chrome only) | Small toolbar and panels; the canvas stays framework-free |
| Rendering | HTML Canvas 2D + [rough.js](https://roughjs.com) | Gives the hand-drawn look and covers the style options directly |
| State | One plain array of elements plus an undo stack of snapshots | Easy to save as JSON and easy to sync later |
| Local storage | IndexedDB, autosaving | Phase 1 needs no backend |
| Backend | Go, single binary with the frontend built in via `embed.FS` | Easy to host locally: one file to run |
| Database | SQLite (`modernc.org/sqlite`, no cgo) | Holds users and scenes |
| Auth | `golang.org/x/oauth2` + `coreos/go-oidc` (Google), session cookie | |
| Real-time (later) | WebSocket (`coder/websocket`) with a room per scene | Uses the element versioning described below |

How rough.js maps to the style options:

| Option | rough.js setting |
|---|---|
| Sloppiness | `roughness`: 0 = architect, 1 = artist, 2 = cartoonist |
| Fill | `fillStyle`: `'hachure' \| 'cross-hatch' \| 'solid'` |
| Stroke style | `strokeLineDash`: `[]` solid, `[8,8]` dashed, `[1.5,6]` dotted |
| Stable wobble | each element stores a fixed `seed`, so its shape doesn't change on re-render |

## Data model

The multi-user fields are part of the model from day one, even while there is only one user.

```ts
type Element = {
  id: string;
  type: 'rectangle' | 'diamond' | 'ellipse' | 'arrow' | 'line' | 'text' | 'note';
  x: number; y: number; width: number; height: number; angle: number;

  strokeColor: string;
  backgroundColor: string;
  fillStyle: 'hachure' | 'cross-hatch' | 'solid';
  strokeStyle: 'solid' | 'dashed' | 'dotted';
  roughness: 0 | 1 | 2;
  roundness: 'sharp' | 'round';
  seed: number;

  points?: [number, number][];                 // arrow/line, relative to x,y
  startBinding?: Binding | null;
  endBinding?: Binding | null;
  boundElements?: { id: string; type: 'arrow' | 'text' }[];

  text?: string;
  fontSize?: number;
  containerId?: string | null;                 // text inside a note/shape

  // sync fields
  version: number;        // incremented on every change
  versionNonce: number;   // random, breaks ties between equal versions
  isDeleted: boolean;     // deletion keeps the element
  updated: number;        // ms timestamp
};

type Binding = { elementId: string; focus: number; gap: number };

type Scene = {
  version: 1;
  elements: Element[];
  appState: { viewBackgroundColor: '#ffffff' };
};
```

Merge rule, used for collaboration and for importing into an open scene: for each element `id`, the copy with the higher `version` wins; when versions are equal, the higher `versionNonce` wins. This is per-element last-writer-wins, the scheme Excalidraw uses. It is much simpler than a CRDT and good enough for a whiteboard, and it lets the server be a plain relay.

## How each feature works

**Viewport**
- State is `{scrollX, scrollY, zoom}`.
- One helper converts between screen and scene coordinates.
- Wheel or pinch zooms; `H` or `Space`+drag pans.

**Tools**
- Each tool is a small state machine handling pointer down, move and up.

**Rendering**
- One full redraw per animation frame when something changed.
- rough.js drawables are cached per element, keyed by `id` + `version`.

**Hit-testing**
- Basic geometry: point in rectangle, diamond or ellipse; distance to a line segment.
- The pointer is first rotated back by the element's `angle`.

**Magnetic attach (arrow binding)**
1. While an arrow end is dragged, find shapes whose outline is within `10px / zoom` and highlight the closest.
2. On release, set `startBinding`/`endBinding` on the arrow and add the arrow to the shape's `boundElements`.
3. When a bound shape moves or resizes, recompute the arrow's endpoint: the intersection of the shape's outline with the line from the arrow's other end towards the shape's center, offset by `gap`.

**Sharp or rounded corners**
- Rounded rectangles are an SVG path with arcs, drawn with `rough.path`.
- Rounded diamonds use quadratic curves at each vertex.

**Text and notes**
- Text is edited in an absolutely positioned `<textarea>` over the canvas and drawn to the canvas when editing ends.
- A note is a rectangle with a solid yellow fill and a bound text element (`containerId`), with text wrapping.

**Arrangement**
- Align and distribute operate on the current selection's bounding boxes.
- Snap guides compare the dragged element's edges and centers with nearby elements.

## Import / export

**JSON**
- Download the `Scene` as a `.localidraw` file.
- Import by file picker or drag-and-drop; check the file with `zod` before loading it.

**PNG**
1. Compute the bounding box of the elements to export (all of them now, the selection later; the same code path).
2. Draw them on an offscreen canvas at 2× scale, with padding and a white background.
3. Call `canvas.toBlob()` and download the result.

**PNG round-trip (bonus)**
- Write the scene JSON into a PNG `tEXt` chunk. Dropping that PNG back onto the canvas restores the editable scene.

## Project layout

```
localidraw/
  web/                 # Vite + TS
    src/scene/         # types, mutations (bump version), undo/redo
    src/render/        # canvas + rough.js, shape cache keyed by id+version
    src/tools/         # one file per tool
    src/geometry/      # hit-tests, bindings, bounds
    src/ui/            # toolbar, style panel, color picker
    src/io/            # json/png export/import, IndexedDB
  server/              # Go
    main.go            # serves embedded web/dist, /api, /ws
    auth/              # Google OIDC, sessions
    scenes/            # CRUD on SQLite
    collab/            # websocket rooms, merge, broadcast
  docs/
```

## API sketch (Phase 5+)

| Method | Path | Purpose |
|---|---|---|
| GET | `/auth/google/login` | Start the OAuth flow |
| GET | `/auth/google/callback` | Finish OAuth, set the session cookie |
| POST | `/auth/logout` | |
| GET | `/api/me` | Current user |
| GET | `/api/scenes` | List the user's scenes |
| POST | `/api/scenes` | Create a scene |
| GET | `/api/scenes/:id` | Load a scene |
| PUT | `/api/scenes/:id` | Save a scene (merged by element version) |
| DELETE | `/api/scenes/:id` | |
| GET (WS) | `/ws/scenes/:id` | Live collaboration room |

WebSocket messages:

```jsonc
{ "type": "elements", "elements": [ /* changed elements */ ] } // saved + broadcast
{ "type": "pointer",  "x": 0, "y": 0, "user": "..." }          // broadcast only, never saved
{ "type": "presence", "users": [ /* ... */ ] }                 // sent by the server
```

## Phases

| # | Phase | Delivers |
|---|---|---|
| 1 | Canvas core | Viewport, rectangle/diamond/ellipse/line/arrow, select/move/resize, hotkeys, undo/redo, IndexedDB autosave |
| 2 | Styling | Style panel (colors, fill, stroke style, sloppiness, corners), text and notes, align/distribute |
| 3 | Binding | Magnetic arrow attach; arrows follow moved shapes |
| 4 | I/O | JSON export/import, PNG export with the scene embedded |
| 5 | Server | Go binary, Google OAuth, scenes in SQLite, list of drawings |
| 6 | Collaboration | WebSocket rooms, merge by version, live cursors |

Phase 1 is the most code. Once the scene, renderer and tool structure are in place, everything after it is incremental.

## Alternative considered: self-hosting Excalidraw

Excalidraw can be self-hosted, but the official image gives you less than excalidraw.com.

**What `docker run -p 8080:80 excalidraw/excalidraw` gives you**
- The full editor: all tools, styles, binding, and export/import of PNG, SVG and `.excalidraw` JSON.
- One drawing per browser, kept in that browser's localStorage. There is no list of drawings, no server-side storage and no sign-in.
- To keep several drawings you save and open `.excalidraw` files by hand.

**What it doesn't give you**
- **Multiple drawings:** the dashboard/workspace with many scenes is Excalidraw+ (paid, cloud-only), not part of the open-source app.
- **Live collaboration:** the image's collaboration and "shareable link" features point at excalidraw.com's own servers (a room server, Firebase and a JSON store). The URLs are set at build time, so self-hosted collaboration means rebuilding the frontend with your own URLs and running `excalidraw/excalidraw-room` next to it. Even then, rooms are temporary and nothing is stored on your server.
- **Auth:** none.

### Docker Compose stacks (collaboration + storage)

These run Excalidraw's live collaboration and share links on your own server. They do **not** add a list of drawings or user accounts.

**Typical services**

| Service | Image | Role |
|---|---|---|
| Frontend | `excalidraw/excalidraw` rebuilt, or `alswl/excalidraw` | The editor, built to use your own servers instead of excalidraw.com's |
| Room server | `excalidraw/excalidraw-room` or `ghcr.io/kitsteam/excalidraw-room` | WebSocket (Socket.IO) relay for live sessions; stores nothing |
| Storage backend | `kitsteam/excalidraw-storage-backend` (PostgreSQL); older: `alswl/…`, `kiliandeca/…` | Replaces excalidraw.com's share-link store and Firebase: saved scenes, collaboration rooms, images |
| Optional | nginx / Traefik, PostgreSQL, MongoDB, Redis | Depends on the project |

**Frontend configuration is fixed at build time**
- The frontend reads its server addresses from Vite variables while it is being built, so the stock image can't simply be configured at runtime:
  - `VITE_APP_WS_SERVER_URL`: public URL of the room server.
  - `VITE_APP_STORAGE_BACKEND=http`
  - `VITE_APP_HTTP_STORAGE_BACKEND_URL`: public URL of the storage backend.
- Projects therefore ship their own frontend image, or patch the built files when the container starts.
- One guide reports a collaboration URL (`oss-collab.excalidraw.com`) hardcoded in the stock build that has to be patched.

**Projects**

| Project | Notes |
|---|---|
| [alswl/excalidraw-collaboration](https://awesome.ecosyste.ms/projects/github.com%2Falswl%2Fexcalidraw-collaboration) | The usual reference setup; MIT. Basic compose plus an nginx mode. S3 storage and SSO are on its roadmap, not built yet. Its storage image ([alswl/excalidraw-storage-backend](https://hub.docker.com/r/alswl/excalidraw-storage-backend)) hasn't been updated in 2+ years. |
| [kitsteam/excalidraw-storage-backend](https://github.imc.re/kitsteam/excalidraw-storage-backend) | Maintained PostgreSQL storage backend (scenes, rooms, files). Used with kitsteam's room server in newer templates, e.g. [Railway](https://railway.com/deploy/excalidraw-collaborator-support). |
| [kiliandeca/excalidraw-storage-backend](https://hub.docker.com/r/kiliandeca/excalidraw-storage-backend) | The original that kitsteam forked; about 4 years stale. |
| [Someone0nEarth/excalidraw-self-hosted](https://backiee.wasmer.app/http_github_com/Someone0nEarth/excalidraw-self-hosted) | Traefik + MongoDB variant. |

**What you get**
- Live collaboration by sharing a room link.
- "Share link" scenes stored on your own server.
- Images inside drawings saved on your server.
- Data encrypted in the browser before it is stored, depending on configuration.

**What you don't get**
- **A list of drawings.** A drawing is a link with its key in the URL; nothing on the server lists or owns scenes.
- **User accounts.** `oauth2-proxy` with Google in front of the stack can block the whole site, but nothing knows which user owns which drawing.
- **A light setup.** Three or four containers plus a custom frontend build, and parts of the ecosystem are stale.

### Other community options (not evaluated)

- **ExcaliDash** ([Railway template](https://railway.com/deploy/excalidash.md), [fork](https://github.com/mfiros/excalidash)): a self-hosted dashboard for managing many drawings. The only project found that adds a drawing list.
- **excalidraw-complete**: a single Go binary bundling Excalidraw with its own storage and collaboration. Not yet verified.
- **Editor plugins (VS Code, Obsidian)**: treat `.excalidraw` files as normal files, so a folder of files acts as the drawing list.

### Takeaway

No self-hosted option combines Google sign-in, per-user drawing lists and collaboration in one easy-to-run piece. A single Go binary (with the editor built from scratch or embedded from `@excalidraw/excalidraw`) replaces the 3–4 container stack and avoids the build-time URL problem.

### Embedding `@excalidraw/excalidraw` (MIT) in our own app

- Our Go server provides OAuth, SQLite storage, the scene list and WebSocket sync.
- The component's `onChange` returns elements that already carry `version`/`versionNonce`, and `reconcileElements` handles merging.
- Estimated at 1–2 weeks to reach the same goals as this plan.

## Open decisions

- [ ] Build the editor from scratch (this plan) or embed `@excalidraw/excalidraw` and build only the server side.
- [ ] Preact or React for the UI chrome.
- [ ] Note color presets and font (hand-drawn font such as Virgil/Excalifont vs. a free alternative).

## References

- [alswl/excalidraw-collaboration](https://awesome.ecosyste.ms/projects/github.com%2Falswl%2Fexcalidraw-collaboration)
- [kitsteam/excalidraw-storage-backend](https://github.imc.re/kitsteam/excalidraw-storage-backend)
- [Self-Hosting Excalidraw (selfhosted.sh)](https://selfhosted-sh.pages.dev/excalidraw-collaborative-whiteboard)
- [Self-Hosting Excalidraw the Easy Way (sliplane)](https://sliplane.io/blog/self-hosting-excalidraw-the-easy-way)
- [excalidraw/excalidraw issue #1772: self-hosting discussion](https://github.com/excalidraw/excalidraw/issues/1772)
