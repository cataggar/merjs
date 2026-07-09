// dispatch.zig — request dispatch: route matching → render → layout wrapping.
// Extracted from router.zig so the Router struct stays focused on routing data
// structures (init/deinit/findRoute/matchRoute).

const std = @import("std");
const mer = @import("mer");
const Router = @import("router.zig").Router;
const Route = @import("router.zig").Route;
const matchRoute = @import("router.zig").matchRoute;

/// Match a URL path to a route and call its render function.
pub fn dispatch(router: Router, req: mer.Request) mer.Response {
    var meta: mer.Meta = .{};
    var params_buf: [8]mer.Param = undefined;

    var response: mer.Response = blk: {
        // 1. O(1) exact match via hash map.
        if (router.exact_map.get(req.path)) |idx| {
            meta = router.routes[idx].meta;
            break :blk router.routes[idx].render(req);
        }

        // 2. Dynamic pattern match (only routes with `:param` segments).
        for (router.dynamic_routes) |route| {
            if (matchRoute(route.path, req.path, &params_buf)) |n| {
                meta = route.meta;
                var dyn_req = req;
                dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                break :blk route.render(dyn_req);
            }
        }

        // 3. Trailing-slash normalisation (except root).
        if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
            const trimmed = req.path[0 .. req.path.len - 1];
            if (router.exact_map.get(trimmed)) |idx| {
                meta = router.routes[idx].meta;
                break :blk router.routes[idx].render(req);
            }
            for (router.dynamic_routes) |route| {
                if (matchRoute(route.path, trimmed, &params_buf)) |n| {
                    meta = route.meta;
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                    break :blk route.render(dyn_req);
                }
            }
        }

        if (router.not_found) |nf| break :blk nf(req);
        break :blk mer.notFound();
    };

    // Auto-wrap HTML responses with layout (skip if response already has <!DOCTYPE).
    if (router.layout) |wrap| {
        if (response.content_type == .html and response.body.len > 0) {
            if (!std.mem.startsWith(u8, response.body, "<!")) {
                response.body = wrap(req.allocator, req.path, response.body, meta);
            }
        }
    }

    return response;
}

/// Result of a fragment dispatch — the route's raw output, unwrapped by layout,
/// plus its meta (so callers can propagate the title without parsing HTML).
pub const FragmentResult = struct {
    response: mer.Response,
    meta: mer.Meta,
};

/// Like dispatch(), but returns the route's raw output WITHOUT layout
/// wrapping. Used for SSR-shell client-side navigation (`X-Mer-Shell` requests):
/// the client swaps only this fragment into the page's mount element, so
/// wrapping it in the full layout would duplicate the nav/footer chrome.
///
/// If the matched route exports `renderStream`, it is buffered into a single
/// fragment (same approach as dispatchBuffered) rather than falling back to
/// the route's plain `render()` — pages that only put their real content in
/// renderStream (e.g. streaming demos) would otherwise show whatever
/// placeholder `render()` returns instead of the actual page.
pub fn dispatchFragment(router: Router, req: mer.Request) FragmentResult {
    var meta: mer.Meta = .{};
    var params_buf: [8]mer.Param = undefined;

    // Find the matching route + effective (param-populated) request.
    const found: ?struct { route: Route, req: mer.Request } = blk: {
        if (router.exact_map.get(req.path)) |idx| {
            meta = router.routes[idx].meta;
            break :blk .{ .route = router.routes[idx], .req = req };
        }
        for (router.dynamic_routes) |route| {
            if (matchRoute(route.path, req.path, &params_buf)) |n| {
                meta = route.meta;
                var dyn_req = req;
                dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                break :blk .{ .route = route, .req = dyn_req };
            }
        }
        if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
            const trimmed = req.path[0 .. req.path.len - 1];
            if (router.exact_map.get(trimmed)) |idx| {
                meta = router.routes[idx].meta;
                break :blk .{ .route = router.routes[idx], .req = req };
            }
            for (router.dynamic_routes) |route| {
                if (matchRoute(route.path, trimmed, &params_buf)) |n| {
                    meta = route.meta;
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                    break :blk .{ .route = route, .req = dyn_req };
                }
            }
        }
        break :blk null;
    };

    const f = found orelse {
        const response = if (router.not_found) |nf| nf(req) else mer.notFound();
        return .{ .response = response, .meta = meta };
    };

    if (f.route.render_stream) |stream_fn| {
        var ctx = BufCtx{ .alloc = req.allocator };
        var stream = mer.StreamWriter{
            .allocator = req.allocator,
            .ctx = &ctx,
            .writeFn = bufWriteFn,
            .flushFn = bufFlushFn,
        };
        stream_fn(f.req, &stream);
        const body = ctx.list.toOwnedSlice(req.allocator) catch "";
        return .{ .response = .{ .status = .ok, .content_type = .html, .body = body }, .meta = meta };
    }

    return .{ .response = f.route.render(f.req), .meta = meta };
}

/// Result of a streaming dispatch — head/body/tail are separate for chunked flushing.
pub const StreamResult = struct {
    head: []const u8,
    body: []const u8,
    tail: []const u8,
    response: mer.Response,
    is_streaming: bool,
};

/// Dispatch with streaming layout support. If stream_layout is set and the
/// response is HTML, returns head/body/tail separately for chunked flushing.
/// Otherwise falls back to the normal assembled response.
pub fn dispatchStreaming(router: Router, req: mer.Request) StreamResult {
    var meta: mer.Meta = .{};
    var params_buf: [8]mer.Param = undefined;

    var response: mer.Response = blk: {
        if (router.exact_map.get(req.path)) |idx| {
            meta = router.routes[idx].meta;
            break :blk router.routes[idx].render(req);
        }
        for (router.dynamic_routes) |route| {
            if (matchRoute(route.path, req.path, &params_buf)) |n| {
                meta = route.meta;
                var dyn_req = req;
                dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                break :blk route.render(dyn_req);
            }
        }
        if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
            const trimmed = req.path[0 .. req.path.len - 1];
            if (router.exact_map.get(trimmed)) |idx| {
                meta = router.routes[idx].meta;
                break :blk router.routes[idx].render(req);
            }
            for (router.dynamic_routes) |route| {
                if (matchRoute(route.path, trimmed, &params_buf)) |n| {
                    meta = route.meta;
                    var dyn_req = req;
                    dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                    break :blk route.render(dyn_req);
                }
            }
        }
        if (router.not_found) |nf| break :blk nf(req);
        break :blk mer.notFound();
    };

    // Use streaming layout if available and response is an HTML fragment.
    if (router.stream_layout) |stream_wrap| {
        if (response.content_type == .html and response.body.len > 0) {
            if (!std.mem.startsWith(u8, response.body, "<!")) {
                const parts = stream_wrap(req.allocator, req.path, meta);
                return .{
                    .head = parts.head,
                    .body = response.body,
                    .tail = parts.tail,
                    .response = response,
                    .is_streaming = true,
                };
            }
        }
    }

    // Fallback: use regular layout wrapping.
    if (router.layout) |wrap| {
        if (response.content_type == .html and response.body.len > 0) {
            if (!std.mem.startsWith(u8, response.body, "<!")) {
                response.body = wrap(req.allocator, req.path, response.body, meta);
            }
        }
    }

    return .{ .head = "", .body = response.body, .tail = "", .response = response, .is_streaming = false };
}

/// Like dispatch() but calls renderStream (if present) with a buffering writer,
/// so pages that only export renderStream work on Cloudflare Workers.
pub fn dispatchBuffered(router: Router, req: mer.Request) mer.Response {
    var meta: mer.Meta = .{};
    var params_buf: [8]mer.Param = undefined;

    // Find the route.
    const route: ?Route = blk: {
        if (router.exact_map.get(req.path)) |idx| {
            meta = router.routes[idx].meta;
            break :blk router.routes[idx];
        }
        for (router.dynamic_routes) |r| {
            if (matchRoute(r.path, req.path, &params_buf)) |n| {
                meta = r.meta;
                var dyn_req = req;
                dyn_req.params = req.allocator.dupe(mer.Param, params_buf[0..n]) catch &.{};
                break :blk r;
            }
        }
        if (req.path.len > 1 and req.path[req.path.len - 1] == '/') {
            const trimmed = req.path[0 .. req.path.len - 1];
            if (router.exact_map.get(trimmed)) |idx| {
                meta = router.routes[idx].meta;
                break :blk router.routes[idx];
            }
        }
        break :blk null;
    };

    // If the route has renderStream, buffer it into a full response.
    if (route) |r| {
        if (r.render_stream) |rs| {
            var ctx = BufCtx{ .alloc = req.allocator };
            var stream = mer.StreamWriter{
                .allocator = req.allocator,
                .ctx = &ctx,
                .writeFn = bufWriteFn,
                .flushFn = bufFlushFn,
            };
            rs(req, &stream);
            const body = ctx.list.toOwnedSlice(req.allocator) catch "";

            // Wrap with stream layout (head + body + tail).
            if (router.stream_layout) |wrap| {
                const parts = wrap(req.allocator, req.path, meta);
                const full = std.mem.concat(req.allocator, u8, &.{ parts.head, body, parts.tail }) catch body;
                return .{ .status = .ok, .content_type = .html, .body = full };
            }
            if (router.layout) |wrap| {
                return .{ .status = .ok, .content_type = .html, .body = wrap(req.allocator, req.path, body, meta) };
            }
            return .{ .status = .ok, .content_type = .html, .body = body };
        }
    }

    // No renderStream — fall back to regular dispatch.
    return dispatch(router, req);
}

const BufCtx = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,
};

fn bufWriteFn(ctx: *anyopaque, data: []const u8) void {
    const bc: *BufCtx = @ptrCast(@alignCast(ctx));
    bc.list.appendSlice(bc.alloc, data) catch {};
}

fn bufFlushFn(ctx: *anyopaque) void {
    _ = ctx;
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn dummyFragmentRender(_: mer.Request) mer.Response {
    return mer.html("<p>fragment</p>");
}

fn dummyLayoutWrap(alloc: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    return std.fmt.allocPrint(alloc, "<!DOCTYPE html><title>{s}</title><nav>{s}</nav>{s}", .{ meta.title, path, body }) catch body;
}

test "dispatchFragment: returns unwrapped body and meta" {
    const routes = [_]Route{
        .{ .path = "/about", .render = dummyFragmentRender, .meta = .{ .title = "About Us" } },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();
    router.layout = dummyLayoutWrap;

    const req = mer.Request.init(std.testing.allocator, .GET, "/about");
    const result = dispatchFragment(router, req);

    // Fragment body must NOT be wrapped by layout (no <!DOCTYPE> injected).
    try std.testing.expectEqualStrings("<p>fragment</p>", result.response.body);
    try std.testing.expectEqualStrings("About Us", result.meta.title);
}

test "dispatchFragment: dynamic route match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const routes = [_]Route{
        .{ .path = "/users/:id", .render = dummyFragmentRender, .meta = .{ .title = "User" } },
    };
    var router = Router.init(alloc, &routes);
    defer router.deinit();

    // Dynamic routes make dispatchFragment allocate (req.allocator.dupe for
    // params) — use an arena here, matching how real requests are served
    // (per-connection arena), so std.testing.allocator doesn't flag a leak.
    const req = mer.Request.init(alloc, .GET, "/users/42");
    const result = dispatchFragment(router, req);

    try std.testing.expectEqualStrings("<p>fragment</p>", result.response.body);
    try std.testing.expectEqualStrings("User", result.meta.title);
}

test "dispatchFragment: not found falls back to notFound response" {
    const routes = [_]Route{
        .{ .path = "/", .render = dummyFragmentRender },
    };
    var router = Router.init(std.testing.allocator, &routes);
    defer router.deinit();

    const req = mer.Request.init(std.testing.allocator, .GET, "/nope");
    const result = dispatchFragment(router, req);

    try std.testing.expectEqual(std.http.Status.not_found, result.response.status);
}

fn dummyStreamRender(_: mer.Request, stream: *mer.StreamWriter) void {
    stream.write("<p>streamed</p>");
    stream.flush();
}

test "dispatchFragment: prefers renderStream over the placeholder render()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const routes = [_]Route{
        .{
            .path = "/stream-demo",
            .render = dummyFragmentRender, // would return "<p>fragment</p>" if used
            .render_stream = dummyStreamRender,
            .meta = .{ .title = "Stream Demo" },
        },
    };
    var router = Router.init(alloc, &routes);
    defer router.deinit();

    // The buffered renderStream path allocates the joined body via
    // req.allocator — use an arena so std.testing.allocator doesn't flag it.
    const req = mer.Request.init(alloc, .GET, "/stream-demo");
    const result = dispatchFragment(router, req);

    try std.testing.expectEqualStrings("<p>streamed</p>", result.response.body);
    try std.testing.expectEqualStrings("Stream Demo", result.meta.title);
}
