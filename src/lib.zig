// src/lib.zig
const std = @import("std");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const compiler = @import("compiler.zig");
pub const markdown = @import("markdown.zig");
pub const emitter = @import("emitter.zig");

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("compiler.zig");
    _ = @import("markdown.zig");
    _ = @import("emitter.zig");
}
