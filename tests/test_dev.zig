const std = @import("std");
const mer = @import("mer");

test "hot reload replacement preserves footer and suffix with one body closer" {
    const prefix = "<!DOCTYPE html><html><body><main>Page</main><footer>Footer</footer>";
    const suffix = "\n</html><!-- suffix: preserved -->";
    const injected = try mer.dev.injectHotReload(std.testing.allocator, prefix ++ "</body>" ++ suffix);
    defer std.testing.allocator.free(injected);

    const script_marker = "<script id=\"__mer_hr__\">";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, injected, "</body>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, injected, script_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, injected, "</script>"));
    try std.testing.expect(std.mem.startsWith(u8, injected, prefix));
    try std.testing.expect(std.mem.endsWith(u8, injected, suffix));

    const footer_end = std.mem.indexOf(u8, injected, "</footer>").? + "</footer>".len;
    const script_start = std.mem.indexOf(u8, injected, script_marker).?;
    const script_end = std.mem.indexOf(u8, injected, "</script>").? + "</script>".len;
    const body_end = std.mem.indexOf(u8, injected, "</body>").?;
    const suffix_start = std.mem.indexOf(u8, injected, suffix).?;
    try std.testing.expect(footer_end <= script_start);
    try std.testing.expect(script_start < script_end);
    try std.testing.expect(script_end < body_end);
    try std.testing.expect(body_end < suffix_start);
}
